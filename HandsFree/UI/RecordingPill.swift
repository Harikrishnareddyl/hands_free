import AppKit
import SwiftUI

/// Floating borderless panel pinned to the bottom-center of the main screen.
/// Shows recording/transcribing state. In push-to-talk states the pill is
/// click-through so it never blocks the app below. In `.handsFree` it becomes
/// interactive: a Cancel button on the left, the rest of the pill submits.
@MainActor
final class RecordingPill {
    enum PillState: Equatable {
        case hidden
        case recording
        case transcribing
        /// Latched recording after a double-tap. Pill is interactive: tap the
        /// X to cancel, tap anywhere else to submit.
        case handsFree
    }

    /// Fired when the user clicks the main body (or the submit icon) while
    /// the pill is in `.handsFree`.
    var onSubmit: (() -> Void)?
    /// Fired when the user clicks the X cancel button in `.handsFree`.
    var onCancel: (() -> Void)?

    private var panel: NSPanel?
    private var hosting: NSHostingView<PillContent>?
    private var currentState: PillState = .hidden

    func setState(_ newState: PillState) {
        guard newState != currentState else { return }
        currentState = newState
        if newState == .hidden {
            hide()
        } else {
            show(state: newState)
        }
    }

    // MARK: - Window lifecycle

    private func show(state: PillState) {
        let size = Self.size(for: state)
        let view = PillContent(
            state: state,
            onSubmit: { [weak self] in self?.onSubmit?() },
            onCancel: { [weak self] in self?.onCancel?() }
        )

        if let hosting {
            hosting.rootView = view
            hosting.frame = NSRect(origin: .zero, size: size)
        } else {
            let newHosting = NSHostingView(rootView: view)
            newHosting.frame = NSRect(origin: .zero, size: size)
            newHosting.autoresizingMask = [.width, .height]
            hosting = newHosting
        }

        if panel == nil {
            panel = makePanel(hosting: hosting!, size: size)
        } else {
            var frame = panel!.frame
            frame.size = size
            panel!.setFrame(frame, display: true)
        }

        // Hands-free needs clicks; PTT states stay click-through.
        panel?.ignoresMouseEvents = (state != .handsFree)

        position(panel!)
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private static func size(for state: PillState) -> NSSize {
        switch state {
        case .handsFree:                 return NSSize(width: 200, height: 36)
        default:                          return NSSize(width: 130, height: 30)
        }
    }

    private func makePanel(hosting: NSView, size: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - SwiftUI content

struct PillContent: View {
    let state: RecordingPill.PillState
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @State private var pulse = false

    var body: some View {
        Group {
            switch state {
            case .handsFree:
                handsFreeBody
            default:
                defaultBody
            }
        }
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: PTT (recording / transcribing)

    private var defaultBody: some View {
        HStack(spacing: 6) {
            icon
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .recording, .handsFree:
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 1.0 : 0.35)
                .animation(
                    .easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                    value: pulse
                )
                .onAppear { pulse = true }
        case .transcribing:
            ProgressView()
                .controlSize(.mini)
                .progressViewStyle(.circular)
        case .hidden:
            EmptyView()
        }
    }

    private var label: String {
        switch state {
        case .recording:    return "Recording…"
        case .transcribing: return "Transcribing…"
        case .handsFree:    return "Recording"
        case .hidden:       return ""
        }
    }

    // MARK: Hands-free (latched, interactive)

    private var handsFreeBody: some View {
        HStack(spacing: 0) {
            // Cancel button (left)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel")

            // Submit area — the whole middle+right is clickable. Tap anywhere
            // here (or tap Fn again) to submit.
            Button(action: onSubmit) {
                HStack(spacing: 6) {
                    icon
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Submit")
        }
    }
}
