import AppKit
import SwiftUI

/// Floating borderless panel pinned to the bottom-center of the main screen.
/// Shows recording/transcribing state with a material background. Click-through
/// (ignores mouse events) so it never blocks the app below.
@MainActor
final class RecordingPill {
    enum PillState: Equatable {
        case hidden
        case recording
        case transcribing
    }

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
        let view = PillContent(state: state)
        if let hosting {
            hosting.rootView = view
        } else {
            let newHosting = NSHostingView(rootView: view)
            newHosting.frame = NSRect(x: 0, y: 0, width: 130, height: 30)
            hosting = newHosting
        }

        if panel == nil {
            panel = makePanel(hosting: hosting!)
        }
        position(panel!)
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(hosting: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 130, height: 30),
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
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.regularMaterial)
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .recording:
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
        case .hidden:       return ""
        }
    }
}
