import SwiftUI
import AVFoundation
import AppKit

/// Modal onboarding shown on every launch that has missing required permissions.
/// The user can't continue until the three required rows are green; their only
/// other option is Quit. (The window has no close button — enforced by the
/// window coordinator with a reduced styleMask.)
struct OnboardingView: View {
    enum Status: Equatable { case unknown, granted, missing }

    /// Returns whether the Fn CGEventTap is currently installed.
    let checkInputMonitoring: () -> Bool
    let onTryInstallFn: () -> Void
    let onOpenAPIKeySetup: () -> Void
    let onContinue: () -> Void
    let onQuit: () -> Void

    @State private var micStatus: Status = .unknown
    @State private var axStatus: Status = .unknown
    @State private var imStatus: Status = .unknown     // Input Monitoring (optional)
    @State private var keyStatus: Status = .unknown
    @State private var pollTimer: Timer?
    @AppStorage("wakeWordEnabled") private var wakeWordEnabled: Bool = false

    private var requiredGranted: Bool {
        micStatus == .granted && axStatus == .granted && keyStatus == .granted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space20) {
            header

            VStack(alignment: .leading, spacing: 0) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    pill: ("REQUIRED", .warning),
                    description: "Capture your voice while dictating.",
                    status: micStatus,
                    actionLabel: micButtonLabel,
                    action: requestMic
                )
                RowSeparator()
                permissionRow(
                    icon: "hand.raised.fill",
                    title: "Accessibility",
                    pill: ("REQUIRED", .warning),
                    description: "Paste transcribed text into the focused app.",
                    status: axStatus,
                    actionLabel: "Open Settings",
                    action: openAccessibilitySettings
                )
                RowSeparator()
                permissionRow(
                    icon: "key.fill",
                    title: "Groq API key",
                    pill: ("REQUIRED", .warning),
                    description: "Needed to send your audio to Whisper for transcription.",
                    status: keyStatus,
                    actionLabel: "Set up key…",
                    action: onOpenAPIKeySetup
                )
                RowSeparator()
                permissionRow(
                    icon: "keyboard",
                    title: "Input Monitoring",
                    pill: ("OPTIONAL", .neutral),
                    description: "Enables the Fn (🌐) key as a hotkey. ⌃⌥D always works without this.",
                    status: imStatus,
                    actionLabel: "Open Settings",
                    action: onTryInstallFn
                )
                RowSeparator()
                wakeWordRow
            }
            .background(
                RoundedRectangle(cornerRadius: DS.radiusMedium, style: .continuous)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMedium, style: .continuous)
                    .strokeBorder(Color.primary.opacity(DS.cardStrokeOpacity), lineWidth: DS.hairline)
            )

            footer
        }
        .padding(DS.space24)
        .frame(width: 580)
        .onAppear {
            refresh()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear { pollTimer?.invalidate() }
    }

    // MARK: - Sub-views

    private var header: some View {
        HStack(alignment: .top, spacing: DS.space14) {
            BrandMark(size: 44, corner: 12, iconSize: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text("Finish setting up Hands-Free")
                    .font(.system(size: 20, weight: .semibold))
                    .tracking(-0.3)
                Text("Hands-Free can't run without these permissions. Grant them below, then click Continue.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if requiredGranted {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(DS.success)
                    Text("All required permissions granted")
                        .font(.system(size: 12, weight: .medium))
                }
            } else {
                Text("This window refreshes automatically — grants show up in a second or two.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { onQuit() }
            Button("Continue") { onContinue() }
                .keyboardShortcut(.defaultAction)
                .disabled(!requiredGranted)
                .controlSize(.regular)
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        pill: (String, StatusPill.Tone),
        description: String,
        status: Status,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: DS.space14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.brand)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    StatusPill(text: pill.0, tone: pill.1)
                }
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            switch status {
            case .unknown:
                ProgressView().controlSize(.small)
            case .granted:
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DS.success)
                        .font(.system(size: 16))
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.success)
                }
            case .missing:
                Button(actionLabel) { action() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, DS.space14)
        .padding(.vertical, DS.space12)
    }

    private var wakeWordRow: some View {
        HStack(spacing: DS.space14) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.brand)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Wake word")
                        .font(.system(size: 12, weight: .semibold))
                    StatusPill(text: "OPT-IN", tone: .info)
                }
                Text("Say \u{201C}\(WakeWordEngine.wakePhrase)\u{201D} to dictate without a hotkey. Listens on-device; audio only leaves your Mac after the phrase fires.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { wakeWordEnabled },
                set: { newValue in
                    wakeWordEnabled = newValue
                    Preferences.wakeWordEnabled = newValue
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.horizontal, DS.space14)
        .padding(.vertical, DS.space12)
    }

    // MARK: - Actions

    private func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micStatus = .granted
        default:          micStatus = .missing
        }
        axStatus = FocusInspector.isAccessibilityTrusted() ? .granted : .missing
        imStatus = checkInputMonitoring() ? .granted : .missing
        keyStatus = Secrets.groqAPIKey() != nil ? .granted : .missing
    }

    private var micButtonLabel: String {
        AVCaptureDevice.authorizationStatus(for: .audio) == .denied
            ? "Open Settings"
            : "Grant"
    }

    private func requestMic() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        // Fresh state — the normal API shows the prompt and registers the app.
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in refresh() }
            }
            return
        }

        // Status is already .denied / .restricted / .authorized.
        //
        // `AVCaptureDevice.authorizationStatus` caches inside the process for
        // its lifetime. If we just call `tccutil reset` and `requestAccess`
        // here, the running HandsFree keeps seeing .denied and no prompt ever
        // appears. The fix is to reset TCC, set a flag telling the next
        // launch to re-request automatically, and relaunch the app so
        // AVCaptureDevice starts from a clean in-process cache.
        Self.resetMicTCC()
        UserDefaults.standard.set(true, forKey: "autoRequestMicOnNextLaunch")
        UserDefaults.standard.synchronize()
        Log.info("onboarding", "quitting so AVCaptureDevice re-initializes; mic prompt will fire on relaunch")
        AppRelaunch.quitAndRestart()
    }

    /// Resets the Microphone TCC entry for this bundle, forcing the next
    /// requestAccess call to go through the fresh-prompt code path.
    /// `tccutil reset <service> <bundleID>` is bundle-scoped and doesn't
    /// require admin when the bundle belongs to the current user's apps.
    private static func resetMicTCC() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lakkireddylabs.HandsFree"
        let task = Process()
        task.launchPath = "/usr/bin/tccutil"
        task.arguments = ["reset", "Microphone", bundleID]
        do {
            try task.run()
            task.waitUntilExit()
            Log.info("onboarding", "tccutil reset Microphone \(bundleID) → exit=\(task.terminationStatus)")
        } catch {
            Log.error("onboarding", "tccutil reset failed: \(error.localizedDescription)")
        }
    }

    private func openAccessibilitySettings() {
        // AXIsProcessTrustedWithOptions shows the system alert the first time.
        // Also open the exact settings pane as a fallback.
        _ = FocusInspector.isAccessibilityTrusted(prompt: true)
        FocusInspector.openAccessibilityPreferences()
    }
}
