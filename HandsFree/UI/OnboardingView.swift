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
        // Always call requestAccess first. For .notDetermined this shows the
        // native prompt. For .denied it completes instantly with `false`, but
        // — crucially — macOS then registers the app in System Settings →
        // Privacy → Microphone so the user has a row to toggle. Without this
        // call, a previously-denied state leaves Settings empty of the app.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor in
                refresh()
                if !granted {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func openAccessibilitySettings() {
        // AXIsProcessTrustedWithOptions shows the system alert the first time.
        // Also open the exact settings pane as a fallback.
        _ = FocusInspector.isAccessibilityTrusted(prompt: true)
        FocusInspector.openAccessibilityPreferences()
    }
}
