import AppKit
import AVFoundation
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    private let hotKey = HotKeyManager()
    private let fnKey = FnHotKeyMonitor()
    private let askAIKey = AskAIHotKeyManager()
    private let recorder = AudioRecorder()
    private let wakeWord = WakeWordEngine()
    private let windows = WindowCoordinator()
    private let pill = RecordingPill()
    private let answerCard = AnswerCardPanel()

    private var isRecording = false
    private var contextBundleID: String?

    /// `true` while a wake-word-initiated hands-free session is running. Used
    /// to gate the VAD auto-submit so manually latched hands-free sessions
    /// still require an explicit tap / submit.
    private var wakeSessionActive = false
    /// Unified 10 Hz timer that runs for every recording session. Handles:
    ///   1. Max-duration cap (all modes)
    ///   2. Last-5-seconds countdown UI + tick sound (all modes)
    ///   3. VAD silence-based auto-submit (wake sessions only)
    /// Nil when no recording is in flight.
    private var sessionTimer: Timer?
    private var sessionStartedAt: Date?
    private var lastCountdownSecondTicked: Int?
    private var vadHeardSpeech = false
    private var vadSilentSince: Date?

    /// Tracks which feature owns the current recording so the Fn/⌃D and the
    /// Ask-AI hotkeys can't step on each other. Set/cleared by the
    /// `beginDictate…` / `beginAskAI…` wrappers around the existing pipeline.
    /// `.dictateHandsFree` is a latched variant entered by double-tapping Fn:
    /// the recorder keeps running until the user clicks Submit/Cancel on the
    /// pill or single-taps Fn again.
    private enum RecordingMode { case none, dictate, askAI, dictateHandsFree }
    private var recordingMode: RecordingMode = .none

    // MARK: - Fn double-tap gesture state

    private enum FnGestureState {
        case idle            // no Fn interaction in flight
        case pressActive     // press received, recorder running silently, waiting to commit
        case pttActive       // committed to PTT (pill + sound shown)
        case releasePending  // tap released, waiting for possible double-tap
        case handsFree       // double-tap confirmed; pill is interactive, recording continues
    }
    private var fnState: FnGestureState = .idle
    private var fnHoldPromoteTask: Task<Void, Never>?
    private var fnReleasePendingTask: Task<Void, Never>?
    private var ignoreNextFnUp = false

    /// A press shorter than this is a tap, not a hold. Until this elapses we
    /// record silently (no pill, no sound) so a stray single tap is invisible.
    /// 0.15s feels snappy for "hold to speak" and still filters accidental bumps.
    private let tapMaxPressDuration: TimeInterval = 0.15
    /// Window (from first release to second press) within which a second tap
    /// is treated as the second half of a double-tap.
    private let tapMaxInterGap: TimeInterval = 0.30

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("app", "launched, pid=\(ProcessInfo.processInfo.processIdentifier), bundle=\(Bundle.main.bundlePath)")

        // Guardrails before doing any real work.
        if LaunchGuards.enforceSingleInstance() { return }
        LaunchGuards.nudgeToApplicationsIfNeeded()

        _ = HistoryStore.shared                 // warm up DB
        // NOTE: deliberately NOT calling recorder.prepareEngine() at launch.
        // Querying the input node before the user explicitly invokes
        // dictation looks to TCC like an un-requested mic access attempt —
        // on hardened-runtime builds without proper entitlements this can
        // silently poison the bundle's mic state. First record lazily.
        setupStatusItem()
        requestNotificationAccess()
        logPermissionSnapshot()

        hotKey.onPressed = { [weak self] in self?.beginDictateRecording() }
        hotKey.onReleased = { [weak self] in self?.endDictateRecording() }
        hotKey.install()

        fnKey.onPressed = { [weak self] in self?.handleFnDown() }
        fnKey.onReleased = { [weak self] in self?.handleFnUp() }
        _ = fnKey.install()   // silent attempt; onboarding handles the UX if it fails

        askAIKey.onPressed = { [weak self] in self?.beginAskAIRecording() }
        askAIKey.onReleased = { [weak self] in self?.endAskAIRecording() }
        askAIKey.install()

        pill.onSubmit = { [weak self] in self?.submitHandsFree() }
        pill.onCancel = { [weak self] in self?.cancelHandsFree() }

        wakeWord.onDetected = { [weak self] in self?.handleWakeWordDetected() }

        showOnboardingIfNeeded()
        honorPendingMicRequest()
        startPermissionWatcher()
        checkForUpdatesInBackground()
        refreshWakeWordEngine()
        NotificationCenter.default.addObserver(
            forName: .wakeWordPreferenceChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshWakeWordEngine() }
        }
    }

    // MARK: - Wake word

    /// Start or stop the wake-word listener based on current preferences and
    /// permissions. Called on launch, whenever the setting toggles, and after
    /// each recording clip ends (to resume listening).
    private func refreshWakeWordEngine() {
        let wantListening = Preferences.wakeWordEnabled
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && !isRecording
            && recordingMode == .none

        if wantListening && !wakeWord.isRunning {
            do {
                try wakeWord.start()
            } catch {
                Log.error("app", "wake word start failed: \(error.localizedDescription)")
            }
        } else if !wantListening && wakeWord.isRunning {
            wakeWord.stop()
        }
    }

    private func handleWakeWordDetected() {
        guard Preferences.wakeWordEnabled else { return }
        guard recordingMode == .none, !isRecording else {
            Log.info("app", "wake detected but already recording; ignored")
            return
        }
        Log.info("app", "wake word → starting hands-free session")
        // Release the mic before the recorder grabs it.
        wakeWord.stop()
        startRecorderSilent()
        wakeSessionActive = true
        fnState = .handsFree
        commitHandsFreeUI()   // starts the session timer (VAD + cap)
    }

    // MARK: - Session timer (duration cap + countdown + VAD)

    /// Start warning the user this many seconds before the hard cap.
    private let countdownLeadSeconds: Int = 5
    /// VAD silence-after-speech threshold — how long the mic must stay quiet
    /// once the user has started talking before we auto-submit. Only runs for
    /// wake-triggered sessions; manual hands-free waits for an explicit tap.
    private let vadSilenceThreshold: TimeInterval = 1.5
    /// Level below which we consider the mic silent. Shaped 0…1 level is
    /// ~0.02 in a quiet room; speech sits around 0.15+.
    private let vadSilentLevel: Float = 0.06
    /// Level above which we decide the user has started speaking.
    private let vadSpeechLevel: Float = 0.12

    private func startSessionTimer() {
        sessionTimer?.invalidate()
        sessionStartedAt = Date()
        lastCountdownSecondTicked = nil
        vadHeardSpeech = false
        vadSilentSince = nil
        SessionCountdown.shared.clear()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSession() }
        }
    }

    private func stopSessionTimer() {
        sessionTimer?.invalidate()
        sessionTimer = nil
        sessionStartedAt = nil
        lastCountdownSecondTicked = nil
        vadHeardSpeech = false
        vadSilentSince = nil
        SessionCountdown.shared.clear()
    }

    private func tickSession() {
        guard let start = sessionStartedAt else {
            stopSessionTimer()
            return
        }
        guard isRecording, recordingMode != .none else {
            // Recorder or mode was cleared out from under us — nothing to do.
            stopSessionTimer()
            return
        }

        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        let cap = Preferences.maxDurationSeconds
        let remaining = cap - elapsed

        // Countdown UI + subtle per-second ticks inside the final stretch.
        if remaining <= Double(countdownLeadSeconds) && remaining > 0 {
            let shown = Int(ceil(remaining))
            SessionCountdown.shared.set(shown)
            if lastCountdownSecondTicked != shown {
                lastCountdownSecondTicked = shown
                if Preferences.audioCueMode != .off {
                    SoundEffects.playCountdownTick()
                }
            }
        } else {
            SessionCountdown.shared.clear()
        }

        // Hard cap — auto-terminate the active mode.
        if elapsed >= cap {
            Log.info("app", "session: hit max duration \(String(format: "%.1f", cap))s, auto-terminating mode=\(recordingMode)")
            autoTerminateForMaxDuration()
            return
        }

        // VAD auto-submit is wake-only.
        guard wakeSessionActive, recordingMode == .dictateHandsFree else { return }
        let level = AudioLevelMonitor.shared.level
        if level >= vadSpeechLevel {
            vadHeardSpeech = true
            vadSilentSince = nil
        } else if vadHeardSpeech && level < vadSilentLevel {
            if vadSilentSince == nil { vadSilentSince = now }
            if let since = vadSilentSince,
               now.timeIntervalSince(since) >= vadSilenceThreshold {
                Log.info("app", "VAD: silence after speech, auto-submit")
                submitHandsFree()
            }
        } else {
            vadSilentSince = nil
        }
    }

    /// Called when the max-duration cap expires. Dispatches to whichever
    /// end-of-session path matches the current mode — same as if the user
    /// had released the hotkey / hit submit themselves.
    private func autoTerminateForMaxDuration() {
        // Clear the Fn state defensively — a PTT auto-stop while the user is
        // still holding the key would otherwise leave fnState stuck.
        if fnState != .idle { fnState = .idle }

        switch recordingMode {
        case .dictate, .dictateHandsFree:
            endDictateRecording()
        case .askAI:
            endAskAIRecording()
        case .none:
            stopSessionTimer()
        }
    }

    // MARK: - Runtime permission watcher

    private var permissionTimer: Timer?

    /// Polls required permissions every 10 s. If any of them drops from
    /// granted → not granted while the app is running (e.g. the user revoked
    /// Microphone in System Settings), re-open the onboarding so they know
    /// what broke instead of silently failing next dictation.
    private func startPermissionWatcher() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRuntimePermissions() }
        }
    }

    private func checkRuntimePermissions() {
        guard !requiredPermissionsGranted else { return }
        guard !windows.isOnboardingVisible else { return }
        Log.info("app", "watcher: required permission missing mid-run, reopening onboarding")
        presentOnboarding()
    }

    /// If the onboarding set the auto-request flag before relaunching us,
    /// fire a fresh `AVCaptureDevice.requestAccess` now — status is finally
    /// `.notDetermined` in this brand-new process (the in-process cache from
    /// the pre-relaunch instance is gone), so the system prompt shows.
    private func honorPendingMicRequest() {
        let key = "autoRequestMicOnNextLaunch"
        guard UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.info("app", "honoring pending mic request, status raw=\(status.rawValue)")
        if status == .notDetermined {
            // Small delay so the onboarding window is visible before the prompt pops.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Log.info("app", "auto-request mic result: granted=\(granted)")
                }
            }
        } else {
            Log.info("app", "auto-request skipped, status was \(status.rawValue)")
        }
    }

    // MARK: - Update check

    private func checkForUpdatesInBackground() {
        Task { @MainActor in
            guard let info = await UpdateChecker.fetchLatest() else { return }
            guard !UpdateChecker.wasDismissed(info) else {
                Log.info("update", "\(info.latestVersion) was dismissed earlier; skipping auto-prompt")
                return
            }
            UpdateChecker.presentAlert(for: info)
        }
    }

    // MARK: - Onboarding gate

    private var requiredPermissionsGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && FocusInspector.isAccessibilityTrusted()
            && Secrets.groqAPIKey() != nil
    }

    private func showOnboardingIfNeeded() {
        guard !requiredPermissionsGranted else {
            Log.info("app", "all required permissions granted; skipping onboarding")
            return
        }
        Log.info("app", "required permissions missing; showing onboarding")
        presentOnboarding()
    }

    private func presentOnboarding() {
        let view = OnboardingView(
            checkInputMonitoring: { [weak self] in self?.fnKey.isInstalled ?? false },
            onTryInstallFn: { [weak self] in self?.grantInputMonitoring() },
            onOpenAPIKeySetup: { [weak self] in self?.windows.showSettings() },
            onContinue: { [weak self] in
                guard let self else { return }
                if self.requiredPermissionsGranted {
                    self.windows.closeOnboarding()
                } else {
                    Log.error("app", "onContinue called but permissions still missing — ignoring")
                }
            },
            onQuit: {
                Log.info("app", "user quit from onboarding")
                NSApp.terminate(nil)
            }
        )
        windows.showOnboarding(view: view)
    }

    private func grantInputMonitoring() {
        // Try to install first (succeeds silently if already granted).
        if fnKey.install() { return }
        FnHotKeyMonitor.openInputMonitoringPreferences()
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: "Hands-Free"
        )

        let menu = NSMenu()

        // One subtle hint line — enough to remind users of the shortcuts
        // without turning the menu into a manual. Tray icon conveys state.
        let hint = NSMenuItem(
            title: "Hold Fn or ⌃D to dictate · ⌃A to ask AI",
            action: nil,
            keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let historyItem = NSMenuItem(
            title: "History…",
            action: #selector(openHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        menu.addItem(historyItem)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let setupItem = NSMenuItem(
            title: "Permissions…",
            action: #selector(openOnboarding),
            keyEquivalent: ""
        )
        setupItem.target = self
        menu.addItem(setupItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesManual),
            keyEquivalent: ""
        )
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        // Debug submenu keeps the diagnostics tools accessible without cluttering the main menu.
        let debugItem = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        let debugMenu = NSMenu(title: "Debug")

        let testItem = NSMenuItem(
            title: "Test: record 3s now",
            action: #selector(runThreeSecondTest),
            keyEquivalent: ""
        )
        testItem.target = self
        debugMenu.addItem(testItem)

        let diagItem = NSMenuItem(
            title: "Copy Diagnostics",
            action: #selector(copyDiagnostics),
            keyEquivalent: ""
        )
        diagItem.target = self
        debugMenu.addItem(diagItem)

        debugMenu.addItem(.separator())

        let resetItem = NSMenuItem(
            title: "Reset Accessibility Permission",
            action: #selector(resetAccessibility),
            keyEquivalent: ""
        )
        resetItem.target = self
        debugMenu.addItem(resetItem)

        let retryFnItem = NSMenuItem(
            title: "Retry Fn key setup",
            action: #selector(retryFnInstall),
            keyEquivalent: ""
        )
        retryFnItem.target = self
        debugMenu.addItem(retryFnItem)

        debugItem.submenu = debugMenu
        menu.addItem(debugItem)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Hands-Free",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.menu = menu
        statusItem = item
    }

    private func setState(_ text: String, symbol: String) {
        // `text` is still accepted so callers can stay concise; we only show
        // it in logs now. The tray icon conveys state to the user; the pill
        // covers the detailed "Recording…" / "Transcribing…" affordance.
        _ = text
        statusItem?.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: "Hands-Free"
        )
    }

    // MARK: - Permissions

    private func requestMicAccess() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Log.info("app", "mic permission: \(granted)")
        }
    }

    private func requestNotificationAccess() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Log.info("app", "notifications permission: \(granted)")
        }
    }

    private func requestAccessibilityIfNeeded() {
        _ = FocusInspector.isAccessibilityTrusted(prompt: true)
    }

    private func logPermissionSnapshot() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let ax = FocusInspector.isAccessibilityTrusted()
        let key = Secrets.groqAPIKey() != nil
        Log.info("app", "snapshot: mic=\(mic.rawValue), ax=\(ax), groqKey=\(key)")
    }

    // MARK: - Hotkey wrappers (mode-gated so the two flows don't collide)

    private func beginDictateRecording() {
        guard recordingMode == .none else { return }
        wakeWord.stop()
        recordingMode = .dictate
        startRecording()
    }

    private func endDictateRecording() {
        guard recordingMode == .dictate || recordingMode == .dictateHandsFree else { return }
        recordingMode = .none
        stopAndTranscribe()
    }

    // MARK: - Fn double-tap / hands-free gesture

    /// On press we start capturing silently so no audio is lost *if* the user
    /// ends up holding or double-tapping. We do NOT touch the pill or play any
    /// sound until the gesture commits — that way a stray single tap is fully
    /// invisible (no brief pill flash, no chime).
    private func handleFnDown() {
        switch fnState {
        case .idle:
            fnState = .pressActive
            startRecorderSilent()
            // If still held past the tap threshold, promote to visible PTT.
            fnHoldPromoteTask = Task { [weak self] in
                let threshold = self?.tapMaxPressDuration ?? 0.15
                try? await Task.sleep(nanoseconds: UInt64(threshold * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.fnState == .pressActive else { return }
                    self.fnState = .pttActive
                    self.commitVisiblePTT()
                }
            }

        case .releasePending:
            // Second press inside the inter-tap gap → confirmed double-tap.
            // The first press's silent recording was discarded on release; we
            // start a fresh one for the hands-free session.
            fnReleasePendingTask?.cancel()
            fnReleasePendingTask = nil
            startRecorderSilent()
            fnState = .handsFree
            ignoreNextFnUp = true    // the release from *this* press isn't a submit
            commitHandsFreeUI()
            Log.info("app", "Fn double-tap → hands-free latched")

        case .pressActive, .pttActive, .handsFree:
            break   // duplicate or mid-gesture — ignore
        }
    }

    private func handleFnUp() {
        switch fnState {
        case .idle:
            break

        case .pressActive:
            // Released before the hold threshold — this was a tap. Drop the
            // silent recording and watch for a second tap.
            fnHoldPromoteTask?.cancel()
            fnHoldPromoteTask = nil
            discardRecorderSilent()
            fnState = .releasePending
            fnReleasePendingTask = Task { [weak self] in
                let gap = self?.tapMaxInterGap ?? 0.30
                try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.fnState == .releasePending else { return }
                    // No second tap. Stay fully silent — single taps do nothing.
                    self.fnState = .idle
                    self.fnReleasePendingTask = nil
                }
            }

        case .pttActive:
            // Released from a committed hold → normal PTT transcribe path.
            fnState = .idle
            endDictateRecording()

        case .releasePending:
            break   // extra release without a press; ignore

        case .handsFree:
            if ignoreNextFnUp {
                ignoreNextFnUp = false
                return
            }
            submitHandsFree()
        }
    }

    // MARK: Silent-start helpers (Fn-only split of `startRecording`)

    /// Start the audio engine without touching pill/sound/state. Used to
    /// speculatively capture audio while we decide whether a Fn press is a
    /// tap or a hold.
    private func startRecorderSilent() {
        guard !isRecording else { return }
        wakeWord.stop()
        contextBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do {
            try recorder.start()
            isRecording = true
        } catch {
            Log.error("app", "silent start failed: \(error.localizedDescription)")
            isRecording = false
        }
    }

    /// Called once a Fn press clears the tap threshold — now we want the
    /// normal PTT affordances.
    private func commitVisiblePTT() {
        recordingMode = .dictate
        setState("Recording…", symbol: "waveform")
        pill.setState(.recording)
        if Preferences.audioCueMode != .off { SoundEffects.playStart() }
        startSessionTimer()
    }

    /// Called on double-tap confirmation — interactive pill + start cue.
    private func commitHandsFreeUI() {
        recordingMode = .dictateHandsFree
        setState("Recording (hands-free)…", symbol: "waveform")
        pill.setState(.handsFree)
        if Preferences.audioCueMode != .off { SoundEffects.playStart() }
        startSessionTimer()
    }

    /// Stop the silent recorder and delete the unfinished file. Does NOT
    /// touch pill or sound (they were never engaged).
    private func discardRecorderSilent() {
        guard isRecording else { return }
        isRecording = false
        stopSessionTimer()
        if let (url, _) = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        refreshWakeWordEngine()
    }

    /// User confirmed — stop recording and run the normal transcribe pipeline.
    private func submitHandsFree() {
        guard recordingMode == .dictateHandsFree else { return }
        Log.info("app", "hands-free: submit")
        fnState = .idle
        ignoreNextFnUp = false
        fnReleasePendingTask?.cancel()
        fnReleasePendingTask = nil
        stopSessionTimer()
        wakeSessionActive = false
        recordingMode = .none
        stopAndTranscribe()
    }

    /// User hit the X button — stop the recorder and throw away the clip.
    private func cancelHandsFree() {
        guard recordingMode == .dictateHandsFree else { return }
        Log.info("app", "hands-free: cancel")
        fnState = .idle
        ignoreNextFnUp = false
        fnReleasePendingTask?.cancel()
        fnReleasePendingTask = nil
        stopSessionTimer()
        wakeSessionActive = false
        recordingMode = .none
        discardRecording()
        refreshWakeWordEngine()
    }

    /// Stop the recorder without transcribing. Used by hands-free cancel.
    private func discardRecording() {
        guard isRecording else { return }
        isRecording = false
        stopSessionTimer()
        if let (url, _) = recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        SoundEffects.stopHum()
        setState("Idle", symbol: "mic.fill")
        pill.setState(.hidden)
    }

    // MARK: - Recording pipeline

    private func startRecording() {
        guard !isRecording else { return }
        contextBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do {
            try recorder.start()
            isRecording = true
            setState("Recording…", symbol: "waveform")
            pill.setState(.recording)
            if Preferences.audioCueMode != .off { SoundEffects.playStart() }
            startSessionTimer()
        } catch {
            Log.error("app", "startRecording failed: \(error.localizedDescription)")
            pill.setState(.hidden)
            showError("Record failed: \(error.localizedDescription)")
        }
    }

    private func stopAndTranscribe() {
        guard isRecording else { return }
        isRecording = false
        stopSessionTimer()

        guard let (url, duration) = recorder.stop() else {
            setState("Idle", symbol: "mic.fill")
            pill.setState(.hidden)
            refreshWakeWordEngine()
            return
        }

        let minDuration = Preferences.minDurationSeconds
        guard duration >= minDuration else {
            Log.info("app", "clip too short (\(String(format: "%.2f", duration))s < \(minDuration)s), discarding")
            try? FileManager.default.removeItem(at: url)
            setState("Idle", symbol: "mic.fill")
            pill.setState(.hidden)
            refreshWakeWordEngine()
            return
        }

        setState("Transcribing…", symbol: "hourglass")
        pill.setState(.transcribing)
        if Preferences.audioCueMode == .all { SoundEffects.startHum() }

        let capturedContext = contextBundleID
        Task { [weak self] in
            await self?.transcribe(url: url, duration: duration, contextApp: capturedContext)
        }
    }

    private func transcribe(url: URL, duration: TimeInterval, contextApp: String?) async {
        defer {
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor in SoundEffects.stopHum() }
        }

        do {
            guard let apiKey = Secrets.groqAPIKey() else {
                throw GroqClient.GroqError.missingAPIKey
            }
            let client = GroqClient(apiKey: apiKey)

            let transcriptionModel = Preferences.transcriptionModel
            let language: String? = Preferences.language.isEmpty ? nil : Preferences.language
            let vocabPrompt: String? = {
                let v = Preferences.transcriptionVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }()

            let raw = try await client.transcribe(
                audioURL: url,
                model: transcriptionModel,
                language: language,
                prompt: vocabPrompt
            )
            let finalText = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            let entry = HistoryStore.Entry(
                id: nil,
                createdAt: Date(),
                raw: finalText,
                cleaned: finalText,
                appBundleID: contextApp,
                durationSeconds: duration,
                model: transcriptionModel
            )
            HistoryStore.shared.insert(entry)

            await MainActor.run {
                SoundEffects.stopHum()
                self.setState("Idle", symbol: "mic.fill")
                self.pill.setState(.hidden)
                if Preferences.audioCueMode != .off { SoundEffects.playEnd() }
                self.deliver(finalText)
                self.refreshWakeWordEngine()
            }
        } catch {
            Log.error("app", "transcribe pipeline failed: \(error.localizedDescription)")
            await MainActor.run {
                SoundEffects.stopHum()
                self.setState("Idle", symbol: "mic.fill")
                self.pill.setState(.hidden)
                self.showError(error.localizedDescription)
                self.refreshWakeWordEngine()
            }
        }
    }

    // MARK: - Ask AI pipeline (parallel to dictate; shares AudioRecorder)

    private func beginAskAIRecording() {
        guard recordingMode == .none else { return }
        guard !isRecording else { return }

        wakeWord.stop()
        do {
            try recorder.start()
            isRecording = true
            recordingMode = .askAI
            setState("Recording (Ask AI)…", symbol: "waveform")
            pill.setState(.recording)
            if Preferences.audioCueMode != .off { SoundEffects.playStart() }
            startSessionTimer()
        } catch {
            Log.error("app", "askAI startRecording failed: \(error.localizedDescription)")
            pill.setState(.hidden)
            showError("Record failed: \(error.localizedDescription)")
        }
    }

    private func endAskAIRecording() {
        guard recordingMode == .askAI else { return }
        guard isRecording else {
            recordingMode = .none
            stopSessionTimer()
            return
        }
        isRecording = false
        recordingMode = .none
        stopSessionTimer()

        guard let (url, duration) = recorder.stop() else {
            setState("Idle", symbol: "mic.fill")
            pill.setState(.hidden)
            refreshWakeWordEngine()
            return
        }

        let minDuration = Preferences.minDurationSeconds
        guard duration >= minDuration else {
            Log.info("app", "askAI clip too short (\(String(format: "%.2f", duration))s), discarding")
            try? FileManager.default.removeItem(at: url)
            setState("Idle", symbol: "mic.fill")
            pill.setState(.hidden)
            refreshWakeWordEngine()
            return
        }

        setState("Transcribing (Ask AI)…", symbol: "hourglass")
        pill.setState(.transcribing)
        if Preferences.audioCueMode == .all { SoundEffects.startHum() }

        Task { [weak self] in
            await self?.runAskAI(url: url)
        }
    }

    private func runAskAI(url: URL) async {
        defer {
            try? FileManager.default.removeItem(at: url)
            Task { @MainActor in SoundEffects.stopHum() }
        }

        do {
            guard let apiKey = Secrets.groqAPIKey() else {
                throw GroqClient.GroqError.missingAPIKey
            }
            let client = GroqClient(apiKey: apiKey)

            let transcriptionModel = Preferences.transcriptionModel
            let language: String? = Preferences.language.isEmpty ? nil : Preferences.language
            let vocabPrompt: String? = {
                let v = Preferences.transcriptionVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }()

            let rawTranscript = try await client.transcribe(
                audioURL: url,
                model: transcriptionModel,
                language: language,
                prompt: vocabPrompt
            )
            let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !transcript.isEmpty else {
                await MainActor.run {
                    SoundEffects.stopHum()
                    self.setState("Idle", symbol: "mic.fill")
                    self.pill.setState(.hidden)
                    self.showNotification(title: "Hands-Free", body: "No speech detected.")
                    self.refreshWakeWordEngine()
                }
                return
            }

            // Hand off to the floating card: transcription done → thinking.
            await MainActor.run {
                self.setState("Thinking…", symbol: "sparkles")
                self.pill.setState(.hidden)
                self.answerCard.presentListening()
                self.answerCard.setThinking(transcript: transcript)
            }

            let systemPrompt = Preferences.askAISystemPrompt
            let model = Preferences.askAIModel
            let messages: [GroqClient.ChatMessage] = [
                .init(role: "system", content: systemPrompt),
                .init(role: "user",   content: transcript)
            ]

            _ = try await client.chatStream(messages: messages, model: model) { delta in
                Task { @MainActor in
                    self.answerCard.appendDelta(delta)
                }
            }

            await MainActor.run {
                SoundEffects.stopHum()
                self.setState("Idle", symbol: "mic.fill")
                if Preferences.audioCueMode != .off { SoundEffects.playEnd() }
                self.answerCard.setDone()
                self.refreshWakeWordEngine()
            }
        } catch {
            Log.error("app", "askAI pipeline failed: \(error.localizedDescription)")
            await MainActor.run {
                SoundEffects.stopHum()
                self.setState("Idle", symbol: "mic.fill")
                self.pill.setState(.hidden)
                self.answerCard.setError(error.localizedDescription)
                self.refreshWakeWordEngine()
            }
        }
    }

    // MARK: - Delivery

    private func deliver(_ text: String) {
        guard !text.isEmpty else {
            showNotification(title: "Hands-Free", body: "No speech detected.")
            return
        }

        let preview = text.count > 160 ? String(text.prefix(160)) + "…" : text
        switch TextInserter.deliver(text) {
        case .pasted:
            showNotification(title: "Pasted", body: preview)
        case .clipboardOnly:
            showNotification(title: "Copied to clipboard", body: preview)
        }
    }

    // MARK: - Menu actions

    @objc private func openSettings() {
        windows.showSettings()
    }

    @objc private func openHistory() {
        windows.showHistory()
    }

    @objc private func openOnboarding() {
        presentOnboarding()
    }

    @objc private func checkForUpdatesManual() {
        Task { @MainActor in
            guard let info = await UpdateChecker.fetchLatest() else {
                let alert = NSAlert()
                alert.messageText = "You're up to date"
                alert.informativeText = "HandsFree \(UpdateChecker.currentVersion) is the latest release."
                alert.runModal()
                return
            }
            UpdateChecker.presentAlert(for: info)
        }
    }

    @objc private func runThreeSecondTest() {
        guard !isRecording else {
            Log.info("app", "test ignored: already recording")
            return
        }
        Log.info("app", "3-second test starting")
        contextBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do {
            try recorder.start()
            isRecording = true
            setState("Recording 3s test…", symbol: "waveform")
        } catch {
            Log.error("app", "test: start failed: \(error.localizedDescription)")
            showError("Test failed to start recording: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.stopAndTranscribe()
        }
    }

    @objc private func retryFnInstall() {
        Log.info("app", "retrying Fn tap install")
        if fnKey.install() {
            showNotification(title: "Fn key ready", body: "Hold Fn (🌐) to dictate.")
        } else {
            FnHotKeyMonitor.openInputMonitoringPreferences()
            showNotification(
                title: "Still blocked",
                body: "Toggle HandsFree on in Input Monitoring, then try again."
            )
        }
    }

    @objc private func resetAccessibility() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lakkireddylabs.HandsFree"
        Log.info("app", "resetting Accessibility TCC for \(bundleID)")
        let task = Process()
        task.launchPath = "/usr/bin/tccutil"
        task.arguments = ["reset", "Accessibility", bundleID]
        do {
            try task.run()
            task.waitUntilExit()
            Log.info("app", "tccutil reset Accessibility exit=\(task.terminationStatus)")
        } catch {
            Log.error("app", "tccutil failed: \(error.localizedDescription)")
            showError("tccutil failed: \(error.localizedDescription)")
            return
        }
        // The running process's Accessibility cache is stale the moment tccutil
        // reset writes. Only a fresh process will see the updated state, so
        // relaunch — the onboarding will re-open on next launch if anything's
        // still missing.
        AppRelaunch.quitAndRestart()
    }

    @objc private func copyDiagnostics() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        let micStr: String = {
            switch mic {
            case .notDetermined: return "not-determined"
            case .restricted:    return "restricted"
            case .denied:        return "denied"
            case .authorized:    return "granted"
            @unknown default:    return "unknown(\(mic.rawValue))"
            }
        }()
        let ax = FocusInspector.isAccessibilityTrusted() ? "granted" : "not granted (or stale)"
        let keyPresent = Secrets.groqAPIKey() != nil
        let execPath = Bundle.main.executablePath ?? "?"
        let inputMon = fnKey.isInstalled ? "granted (Fn tap active)" : "NOT granted or tap failed"

        let report = """
        Hands-Free diagnostics
        ----------------------
        Microphone:        \(micStr)
        Accessibility:     \(ax)
        Input Monitoring:  \(inputMon)
        Groq API key:      \(keyPresent ? "found" : "MISSING — open Settings to add one")
        Transcription:     \(Preferences.transcriptionModel)
        Ask AI model:      \(Preferences.askAIModel)
        Min clip:          \(String(format: "%.1f", Preferences.minDurationSeconds))s
        Vocabulary:        \(Preferences.transcriptionVocabulary.isEmpty ? "(none)" : "\(Preferences.transcriptionVocabulary.count) chars")
        History entries:   \(HistoryStore.shared.count())
        Triggers:          Fn (🌐) + ⌃D dictate, ⌃A ask AI (push-to-talk)
        Bundle ID:         \(Bundle.main.bundleIdentifier ?? "?")
        Exec path:         \(execPath)
        PID:               \(ProcessInfo.processInfo.processIdentifier)
        """

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        Log.info("app", "diagnostics copied:\n\(report)")
        showNotification(title: "Diagnostics copied", body: "Paste anywhere to view.")
    }

    // MARK: - UX helpers

    private func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func showError(_ message: String) {
        showNotification(title: "Hands-Free error", body: message)
    }
}
