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

    private var requiredGranted: Bool {
        micStatus == .granted && axStatus == .granted && keyStatus == .granted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            permissionRow(
                icon: "mic.fill",
                title: "Microphone",
                required: true,
                description: "Capture your voice while dictating.",
                status: micStatus,
                actionLabel: micButtonLabel,
                action: requestMic
            )

            permissionRow(
                icon: "hand.raised.fill",
                title: "Accessibility",
                required: true,
                description: "Paste transcribed text into the focused app.",
                status: axStatus,
                actionLabel: "Open Settings",
                action: openAccessibilitySettings
            )

            permissionRow(
                icon: "key.fill",
                title: "Groq API key",
                required: true,
                description: "Needed to send your audio to Whisper for transcription.",
                status: keyStatus,
                actionLabel: "Set up key…",
                action: onOpenAPIKeySetup
            )

            permissionRow(
                icon: "keyboard",
                title: "Input Monitoring (optional)",
                required: false,
                description: "Enables the Fn (🌐) key as a hotkey. ⌃⌥D always works without this.",
                status: imStatus,
                actionLabel: "Open Settings",
                action: onTryInstallFn
            )

            Divider()
            footer
        }
        .padding(24)
        .frame(width: 560)
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
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color(red: 0.42, green: 0.20, blue: 0.95))
            VStack(alignment: .leading, spacing: 3) {
                Text("Finish setting up HandsFree")
                    .font(.title2.weight(.semibold))
                Text("HandsFree can't run without these permissions. Grant them below, then click Continue.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack {
            if requiredGranted {
                Label("All required permissions granted", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Text("This window refreshes automatically — grants show up in a second or two.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { onQuit() }
            Button("Continue") { onContinue() }
                .keyboardShortcut(.defaultAction)
                .disabled(!requiredGranted)
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        required: Bool,
        description: String,
        status: Status,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color(red: 0.42, green: 0.20, blue: 0.95))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if required {
                        Text("REQUIRED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundStyle(.orange)
                            .cornerRadius(3)
                    }
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            switch status {
            case .unknown:
                ProgressView().controlSize(.small)
            case .granted:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 20))
            case .missing:
                Button(actionLabel) { action() }
            }
        }
        .padding(.vertical, 4)
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
        Self.relaunchSelf()
    }

    /// Spawns a detached `open` that waits 1s then relaunches us, then quits.
    private static func relaunchSelf() {
        let appPath = Bundle.main.bundlePath
        let cmd = "(sleep 1 && open \"\(appPath)\") >/tmp/handsfree-relaunch.log 2>&1 </dev/null & disown"
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", cmd]
        task.standardInput = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Log.error("onboarding", "relaunch spawn failed: \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
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
