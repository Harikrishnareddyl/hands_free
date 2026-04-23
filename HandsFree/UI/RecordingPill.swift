import AppKit
import SwiftUI

/// Floating borderless pill pinned to the bottom-center of the main screen.
/// Tiny + animation-only: no text, so the pill is small enough to feel like
/// a macOS HUD instead of a dialog. Click-through in PTT states; interactive
/// in `.handsFree` (X cancels, body/stop submits).
@MainActor
final class RecordingPill {
    enum PillState: Equatable {
        case hidden
        case recording
        case transcribing
        /// Latched recording after a double-tap. Pill is interactive.
        case handsFree
    }

    var onSubmit: (() -> Void)?
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

    /// Kept consistent across states so the pill doesn't jump around. Width
    /// grows only to accommodate the two extra buttons in hands-free.
    private static func size(for state: PillState) -> NSSize {
        let height: CGFloat = 24
        switch state {
        case .handsFree:                 return NSSize(width: 108, height: height)
        default:                          return NSSize(width: 68,  height: height)
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

    var body: some View {
        Group {
            switch state {
            case .hidden:       EmptyView()
            case .recording:    recordingBody
            case .transcribing: transcribingBody
            case .handsFree:    handsFreeBody
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

    // MARK: Recording (PTT) — voice-reactive bars with a red accent dot

    private var recordingBody: some View {
        HStack(spacing: 5) {
            RecordingDot()
            WaveformBars(barCount: 7, maxHeight: 12, tint: .primary.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }

    // MARK: Transcribing (PTT) — three bouncing dots ("thinking")

    private var transcribingBody: some View {
        BouncingDots(dotCount: 3, size: 4, tint: .primary.opacity(0.72))
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
    }

    // MARK: Hands-free — small X · reactive waveform · small stop

    private var handsFreeBody: some View {
        HStack(spacing: 6) {
            Button(action: onCancel) {
                ZStack {
                    Circle().fill(Color(red: 1.0, green: 0.78, blue: 0.20))
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.75))
                }
                .frame(width: 16, height: 16)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel")

            // Tapping the waveform also submits.
            Button(action: onSubmit) {
                WaveformBars(barCount: 7, maxHeight: 12, tint: .primary.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Submit")

            Button(action: onSubmit) {
                ZStack {
                    Circle().fill(Color.red)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white)
                        .frame(width: 5.5, height: 5.5)
                }
                .frame(width: 16, height: 16)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Submit")
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Reactive waveform

/// Vertical bars whose amplitude tracks `AudioLevelMonitor.shared.level`. A
/// phase-offset sine per bar keeps the motion organic even during silence.
private struct WaveformBars: View {
    @ObservedObject private var monitor = AudioLevelMonitor.shared

    let barCount: Int
    let maxHeight: CGFloat
    let tint: Color

    private let minH: CGFloat = 2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // Always keep a small base wiggle so the pill doesn't look frozen
            // during silence; scale most of the amplitude off the live level.
            let level = CGFloat(monitor.level)
            let amp = max(0.12, level)
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tint)
                        .frame(width: 2, height: barHeight(i: i, time: t, amp: amp))
                }
            }
        }
    }

    private func barHeight(i: Int, time: Double, amp: CGFloat) -> CGFloat {
        let phase = time * 9 + Double(i) * 0.75
        let wave = (sin(phase) + 1) / 2                 // 0..1
        return minH + CGFloat(wave) * amp * (maxHeight - minH)
    }
}

// MARK: - Small indicators

private struct RecordingDot: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = 0.6 + (sin(t * 3.8) + 1) / 2 * 0.4   // 0.6..1.0 opacity
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .opacity(pulse)
        }
    }
}

private struct BouncingDots: View {
    let dotCount: Int
    let size: CGFloat
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<dotCount, id: \.self) { i in
                    Circle()
                        .fill(tint)
                        .frame(width: size, height: size)
                        .scaleEffect(scale(i: i, time: t))
                }
            }
        }
    }

    private func scale(i: Int, time: Double) -> CGFloat {
        let phase = time * 3.2 + Double(i) * 0.55
        let wave = (sin(phase) + 1) / 2
        return 0.55 + CGFloat(wave) * 0.55
    }
}
