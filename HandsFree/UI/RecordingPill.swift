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
        case .handsFree:                 return NSSize(width: 156, height: 34)
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

    /// Compact three-part layout: yellow X cancel · animated waveform · red stop.
    /// No text — the pill is small enough that the iconography carries it.
    /// The waveform area is also tappable so "click anywhere in the middle to
    /// submit" still works; only the X circle cancels.
    private var handsFreeBody: some View {
        HStack(spacing: 8) {
            // Cancel (yellow traffic-light-style button)
            Button(action: onCancel) {
                ZStack {
                    Circle().fill(Color(red: 1.0, green: 0.78, blue: 0.20))
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.72))
                }
                .frame(width: 20, height: 20)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel")

            // Animated waveform — also acts as "submit anywhere" hit area.
            Button(action: onSubmit) {
                WaveformBars()
                    .frame(maxWidth: .infinity, maxHeight: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Submit")

            // Stop button (submit) — red with white square
            Button(action: onSubmit) {
                ZStack {
                    Circle().fill(Color.red)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.white)
                        .frame(width: 7, height: 7)
                }
                .frame(width: 20, height: 20)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Submit")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Waveform

/// Lightweight audio-style visualization. Bars animate via a single sine sweep
/// with a phase offset per bar — gives the classic "listening" rhythm without
/// needing live audio-level taps. Driven by TimelineView so SwiftUI updates
/// smoothly at ~30 fps without manual state churn.
private struct WaveformBars: View {
    private let barCount = 10
    private let minH: CGFloat = 3
    private let maxH: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.88))
                        .frame(width: 2.5, height: barHeight(i: i, time: t))
                }
            }
        }
    }

    private func barHeight(i: Int, time: Double) -> CGFloat {
        let phase = time * 5.5 + Double(i) * 0.55
        let norm = (sin(phase) + 1) / 2        // 0..1
        return minH + (maxH - minH) * CGFloat(norm)
    }
}
