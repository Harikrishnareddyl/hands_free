import AppKit
import Combine
import SwiftUI
import MarkdownUI

/// Floating, always-on-top card that shows a streamed LLM answer to a spoken
/// question. Non-activating (doesn't steal focus from the app you were in),
/// interactive (click to scroll / copy / close), and positioned at the
/// top-right of the screen with the mouse.
@MainActor
final class AnswerCardPanel {
    private var panel: AutoHidePanel?
    private var hosting: NSHostingView<AnswerCardView>?
    private let viewModel = AnswerCardViewModel()
    private let speech = SpeechManager()

    private var autoHideTask: Task<Void, Never>?
    private var speechCancellable: AnyCancellable?

    init() {
        // Re-arm the auto-hide timer whenever speech ends, so the card
        // doesn't vanish mid-sentence — only once the voice has finished.
        // The sink jumps onto the MainActor because this type's methods
        // (and the panel's @Published observer above) are all MainActor-
        // bound. We defer through a Task so scheduleAutoHideIfEligible
        // runs AFTER @Published's willSet has finished — otherwise any
        // check it makes against `speech.isSpeaking` would still see the
        // pre-willSet value.
        speechCancellable = speech.$isSpeaking
            .dropFirst()
            .sink { [weak self] speaking in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if speaking {
                        self.cancelAutoHide()
                    } else {
                        self.scheduleAutoHideIfEligible()
                    }
                }
            }
    }

    // MARK: - Public API driven by AppDelegate

    func presentListening() {
        speech.stop()
        cancelAutoHide()
        viewModel.reset()
        viewModel.state = .transcribing
        show()
    }

    func setTranscribing() {
        viewModel.state = .transcribing
    }

    func setThinking(transcript: String) {
        viewModel.transcript = transcript
        viewModel.state = .thinking
    }

    func appendDelta(_ delta: String) {
        if viewModel.state != .streaming {
            viewModel.state = .streaming
        }
        viewModel.answer += delta
    }

    func setDone() {
        if viewModel.answer.isEmpty {
            viewModel.state = .error
            viewModel.errorMessage = "Empty response from the model."
            scheduleAutoHideIfEligible()
        } else {
            viewModel.state = .done
            if Preferences.speakAnswersEnabled && !Preferences.speakAnswersMuted {
                // Built-in macOS voice reads the answer as soon as the model
                // finishes streaming. Auto-hide is scheduled by the speech-
                // isSpeaking observer once TTS ends, so the card doesn't
                // disappear mid-sentence.
                speech.speak(viewModel.answer)
            } else {
                // Speech disabled or muted — arm the auto-hide timer now.
                scheduleAutoHideIfEligible()
            }
        }
    }

    func setError(_ message: String, transcript: String? = nil) {
        if let transcript { viewModel.transcript = transcript }
        viewModel.errorMessage = message
        viewModel.state = .error
        scheduleAutoHideIfEligible()
    }

    func close() {
        cancelAutoHide()
        speech.stop()
        panel?.orderOut(nil)
    }

    // MARK: - Window lifecycle

    private func show() {
        let rootView = AnswerCardView(
            viewModel: viewModel,
            speech: speech,
            onClose: { [weak self] in self?.close() },
            onCopy: { [weak self] in self?.copyAnswerToPasteboard() },
            onToggleSpeech: { [weak self] in self?.toggleSpeech() },
            onCardSizeChange: { [weak self] size in self?.applyCardSize(size) }
        )

        if let hosting {
            hosting.rootView = rootView
        } else {
            let newHosting = NSHostingView(rootView: rootView)
            newHosting.frame = NSRect(x: 0, y: 0, width: AnswerCardMetrics.width, height: AnswerCardMetrics.initialHeight)
            newHosting.autoresizingMask = [.width, .height]
            hosting = newHosting
        }

        if panel == nil {
            panel = makePanel(hosting: hosting!)
        }
        position(panel!)
        panel?.orderFrontRegardless()
    }

    /// Resize the panel to match the SwiftUI card's measured size while
    /// keeping the top-right corner anchored (the card should grow
    /// downward, not away from the mouse-anchor corner).
    private func applyCardSize(_ size: CGSize) {
        guard let panel else { return }
        guard size.width > 0, size.height > 0 else { return }
        let current = panel.frame
        let newWidth = size.width.rounded()
        let newHeight = size.height.rounded()
        if abs(newWidth - current.width) < 0.5, abs(newHeight - current.height) < 0.5 {
            return
        }
        let newY = current.maxY - newHeight
        let newX = current.maxX - newWidth
        let newFrame = NSRect(x: newX, y: newY, width: newWidth, height: newHeight)
        panel.setFrame(newFrame, display: true, animate: false)
    }

    private func copyAnswerToPasteboard() {
        guard !viewModel.answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.answer, forType: .string)
    }

    private func toggleSpeech() {
        if speech.isSpeaking {
            // Stopping mid-speech is an intentional mute — persist it so the
            // next answer doesn't auto-play either.
            speech.stop()
            Preferences.speakAnswersMuted = true
        } else {
            // User wants to hear it. Clear the mute and start reading.
            Preferences.speakAnswersMuted = false
            guard !viewModel.answer.isEmpty else { return }
            speech.speak(viewModel.answer)
        }
    }

    // MARK: - Auto-hide

    /// Arm the auto-hide timer if we're in a terminal state. Callers are
    /// responsible for not calling this while TTS is actively speaking —
    /// we can't check `speech.isSpeaking` here because the `@Published`
    /// observer fires during `willSet`, before the property actually flips.
    private func scheduleAutoHideIfEligible() {
        guard Preferences.answerAutoHideEnabled else { return }
        guard panel?.isVisible == true else { return }
        switch viewModel.state {
        case .done, .error:
            break
        case .transcribing, .thinking, .streaming:
            return
        }
        cancelAutoHide()
        let delay = Preferences.answerAutoHideSeconds
        Log.info("panel", "auto-hide armed: \(Int(delay))s")
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                Log.info("panel", "auto-hide fired, dismissing card")
                self?.close()
            }
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    /// Called from AutoHidePanel whenever the user clicks, drags, scrolls,
    /// or types inside the card. Resets the timer so reading / interacting
    /// keeps the panel alive for another full window.
    private func handleUserActivity() {
        // Only reschedule if the timer is currently armed — mid-stream
        // activity shouldn't start a premature countdown.
        guard autoHideTask != nil else { return }
        scheduleAutoHideIfEligible()
    }

    private func makePanel(hosting: NSView) -> AutoHidePanel {
        let panel = AutoHidePanel(
            contentRect: NSRect(x: 0, y: 0, width: AnswerCardMetrics.width, height: AnswerCardMetrics.initialHeight),
            styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.worksWhenModal = true
        panel.minSize = NSSize(width: AnswerCardMetrics.width, height: 80)
        panel.contentView = hosting
        panel.onUserActivity = { [weak self] in self?.handleUserActivity() }
        return panel
    }

    /// Anchor to the top-right of whichever screen currently contains the
    /// mouse cursor, so the card appears near whatever the user is looking at.
    private func position(_ panel: NSPanel) {
        let screen = screenUnderMouse() ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let margin: CGFloat = 16
        let x = frame.maxX - size.width - margin
        let y = frame.maxY - size.height - margin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
    }
}

// MARK: - View model

@MainActor
final class AnswerCardViewModel: ObservableObject {
    enum State {
        case transcribing
        case thinking
        case streaming
        case done
        case error
    }

    @Published var state: State = .transcribing
    @Published var transcript: String = ""
    @Published var answer: String = ""
    @Published var errorMessage: String = ""

    func reset() {
        state = .transcribing
        transcript = ""
        answer = ""
        errorMessage = ""
    }
}

// MARK: - SwiftUI content

enum AnswerCardMetrics {
    /// Fixed card width. The height grows with the content, but keeping
    /// width stable avoids reflow jitter as tokens stream in.
    static let width: CGFloat = 420
    /// What the panel opens at before SwiftUI has reported its natural
    /// size — roughly matches the compact "Listening…" state so there's
    /// no visible shrink on first render.
    static let initialHeight: CGFloat = 120
    /// Never render the answer scroll area shorter than this, even if the
    /// markdown is only a few words — otherwise the card looks cramped.
    static let minScrollHeight: CGFloat = 56
    /// Answer scroll area cap. Past this the card stops growing and the
    /// content scrolls internally.
    static let maxScrollHeight: CGFloat = 420
}

struct AnswerCardView: View {
    @ObservedObject var viewModel: AnswerCardViewModel
    @ObservedObject var speech: SpeechManager
    let onClose: () -> Void
    let onCopy: () -> Void
    let onToggleSpeech: () -> Void
    let onCardSizeChange: (CGSize) -> Void

    @AppStorage("speakAnswersEnabled") private var speakEnabled = true
    @AppStorage("speakAnswersMuted")   private var speakMuted = false

    @State private var transcriptExpanded = false
    @State private var markdownNaturalHeight: CGFloat = 0

    private var scrollAreaHeight: CGFloat {
        let desired = max(markdownNaturalHeight, AnswerCardMetrics.minScrollHeight)
        return min(desired, AnswerCardMetrics.maxScrollHeight)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)
            content
            if !viewModel.transcript.isEmpty {
                Divider().opacity(0.4)
                transcriptFooter
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .frame(width: AnswerCardMetrics.width)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: CardSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(CardSizeKey.self) { size in
            onCardSizeChange(size)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(statusLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if speakEnabled, viewModel.state == .done || viewModel.state == .streaming {
                Button(action: onToggleSpeech) {
                    Image(systemName: speech.isSpeaking
                          ? "speaker.wave.2.fill"
                          : (speakMuted ? "speaker.slash.fill" : "speaker.wave.2"))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(speech.isSpeaking
                      ? "Stop speaking"
                      : (speakMuted ? "Unmute — speak answer" : "Speak answer"))
                .foregroundStyle(speech.isSpeaking ? Color.accentColor : .secondary)
                .disabled(viewModel.answer.isEmpty)

                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Copy answer")
                .foregroundStyle(.secondary)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Close")
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.state {
        case .transcribing, .thinking:
            ProgressView().controlSize(.mini).progressViewStyle(.circular)
        case .streaming:
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
                .font(.system(size: 11))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .font(.system(size: 11))
        }
    }

    private var statusLabel: String {
        switch viewModel.state {
        case .transcribing: return "Transcribing…"
        case .thinking:     return "Thinking…"
        case .streaming:    return "Answering"
        case .done:         return "Answer"
        case .error:        return "Error"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .transcribing:
            placeholder("Listening to your question…")
        case .thinking:
            placeholder("Sending to the model…")
        case .streaming, .done:
            ScrollView {
                Markdown(viewModel.answer.isEmpty ? "…" : viewModel.answer)
                    .markdownTheme(.compactCard)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: MarkdownHeightKey.self, value: proxy.size.height)
                        }
                    )
            }
            .frame(height: scrollAreaHeight)
            .onPreferenceChange(MarkdownHeightKey.self) { height in
                markdownNaturalHeight = height
            }
        case .error:
            VStack(alignment: .leading, spacing: 6) {
                Text(viewModel.errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Transcript (collapsible)

    private var transcriptFooter: some View {
        DisclosureGroup(isExpanded: $transcriptExpanded) {
            Text(viewModel.transcript)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            Text("Your question")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Compact markdown theme

extension Theme {
    /// Tight, floating-card-friendly theme. The stock `.gitHub` theme is
    /// tuned for full-width documents — its H1 is ~2em, which swallows a
    /// 440-wide card. Headings here are only slightly bigger than body.
    static let compactCard = Theme()
        .text {
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(.secondary.opacity(0.18))
        }
        .strong { FontWeight(.semibold) }
        .link { ForegroundColor(.accentColor) }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(14)
                }
                .markdownMargin(top: 8, bottom: 3)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(13)
                }
                .markdownMargin(top: 6, bottom: 2)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.22))
                .markdownMargin(top: 0, bottom: 6)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .relativeLineSpacing(.em(0.18))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.9))
                    }
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .markdownMargin(top: 4, bottom: 6)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 2)
                }
                .markdownMargin(top: 4, bottom: 4)
        }
}

// MARK: - Size measurement

private struct CardSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct MarkdownHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Auto-hide panel

/// `NSPanel` subclass that pipes any real user interaction (click, drag,
/// scroll, key) back to an owner callback. The owner uses it to reset its
/// auto-hide timer — passive hovering doesn't count, deliberate actions do.
final class AutoHidePanel: NSPanel {
    var onUserActivity: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .scrollWheel, .keyDown, .magnify, .swipe:
            onUserActivity?()
        default:
            break
        }
        super.sendEvent(event)
    }
}
