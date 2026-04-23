import AppKit
import AVFoundation
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var stateMenuItem: NSMenuItem?

    private let hotKey = HotKeyManager()
    private let fnKey = FnHotKeyMonitor()
    private let askAIKey = AskAIHotKeyManager()
    private let recorder = AudioRecorder()
    private let windows = WindowCoordinator()
    private let pill = RecordingPill()
    private let answerCard = AnswerCardPanel()

    private var isRecording = false
    private var contextBundleID: String?

    /// Tracks which feature owns the current recording so the Fn/⌃⌥D and the
    /// Ask-AI hotkeys can't step on each other. Set/cleared by the
    /// `beginDictate…` / `beginAskAI…` wrappers around the existing pipeline.
    private enum RecordingMode { case none, dictate, askAI }
    private var recordingMode: RecordingMode = .none

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

        fnKey.onPressed = { [weak self] in self?.beginDictateRecording() }
        fnKey.onReleased = { [weak self] in self?.endDictateRecording() }
        _ = fnKey.install()   // silent attempt; onboarding handles the UX if it fails

        askAIKey.onPressed = { [weak self] in self?.beginAskAIRecording() }
        askAIKey.onReleased = { [weak self] in self?.endAskAIRecording() }
        askAIKey.install()

        showOnboardingIfNeeded()
        honorPendingMicRequest()
        startPermissionWatcher()
        checkForUpdatesInBackground()
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
        let state = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        stateMenuItem = state

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hold Fn (🌐) or ⌃⌥D to dictate",
            action: nil,
            keyEquivalent: ""
        ).isEnabled = false
        menu.addItem(
            withTitle: "Hold ⌃⌥A to ask AI",
            action: nil,
            keyEquivalent: ""
        ).isEnabled = false

        menu.addItem(.separator())

        let historyItem = NSMenuItem(
            title: "History…",
            action: #selector(openHistory),
            keyEquivalent: "y"
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
            title: "Setup / Permissions…",
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
        stateMenuItem?.title = text
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
        recordingMode = .dictate
        startRecording()
    }

    private func endDictateRecording() {
        guard recordingMode == .dictate else { return }
        recordingMode = .none
        stopAndTranscribe()
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
        } catch {
            Log.error("app", "startRecording failed: \(error.localizedDescription)")
            pill.setState(.hidden)
            showError("Record failed: \(error.localizedDescription)")
        }
    }

    private func stopAndTranscribe() {
        guard isRecording else { return }
        isRecording = false

        guard let (url, duration) = recorder.stop() else {
            setState("Idle", symbol: "mic.fill")
            pill.setState(.hidden)
            return
        }

        let minDuration = Preferences.minDurationSeconds
        guard duration >= minDuration else {
            Log.info("app", "clip too short (\(String(format: "%.2f", duration))s < \(minDuration)s), discarding")
            try? FileManager.default.removeItem(at: url)
            setState("Idle", symbol: "mic.fill")
            pill.setState(.hidden)
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
            }
        } catch {
            Log.error("app", "transcribe pipeline failed: \(error.localizedDescription)")
            await MainActor.run {
                SoundEffects.stopHum()
                self.setState("Idle", symbol: "mic.fill")
                self.pill.setState(.hidden)
                self.showError(error.localizedDescription)
            }
        }
    }

    // MARK: - Ask AI pipeline (parallel to dictate; shares AudioRecorder)

    private func beginAskAIRecording() {
        guard recordingMode == .none else { return }
        guard !isRecording else { return }

        do {
            try recorder.start()
            isRecording = true
            recordingMode = .askAI
            setState("Recording (Ask AI)…", symbol: "waveform")
            pill.setState(.recording)
            if Preferences.audioCueMode != .off { SoundEffects.playStart() }
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
            return
        }
        isRecording = false
        recordingMode = .none

        guard let (url, duration) = recorder.stop() else {
            setState("Idle", symbol: "mic.fill")
            pill.setState(.hidden)
            return
        }

        let minDuration = Preferences.minDurationSeconds
        guard duration >= minDuration else {
            Log.info("app", "askAI clip too short (\(String(format: "%.2f", duration))s), discarding")
            try? FileManager.default.removeItem(at: url)
            setState("Idle", symbol: "mic.fill")
            pill.setState(.hidden)
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
            }
        } catch {
            Log.error("app", "askAI pipeline failed: \(error.localizedDescription)")
            await MainActor.run {
                SoundEffects.stopHum()
                self.setState("Idle", symbol: "mic.fill")
                self.pill.setState(.hidden)
                self.answerCard.setError(error.localizedDescription)
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
        Triggers:          Fn (🌐) + ⌃⌥D dictate, ⌃⌥A ask AI (push-to-talk)
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
