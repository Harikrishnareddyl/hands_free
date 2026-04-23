import AppKit
import SwiftUI
import MarkdownUI

/// Floating, always-on-top card that shows a streamed LLM answer to a spoken
/// question. Non-activating (doesn't steal focus from the app you were in),
/// interactive (click to scroll / copy / close), and positioned at the
/// top-right of the screen with the mouse.
@MainActor
final class AnswerCardPanel {
    private var panel: NSPanel?
    private var hosting: NSHostingView<AnswerCardView>?
    private let viewModel = AnswerCardViewModel()

    // MARK: - Public API driven by AppDelegate

    func presentListening() {
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
        } else {
            viewModel.state = .done
        }
    }

    func setError(_ message: String, transcript: String? = nil) {
        if let transcript { viewModel.transcript = transcript }
        viewModel.errorMessage = message
        viewModel.state = .error
    }

    func close() {
        panel?.orderOut(nil)
    }

    // MARK: - Window lifecycle

    private func show() {
        let rootView = AnswerCardView(
            viewModel: viewModel,
            onClose: { [weak self] in self?.close() },
            onCopy: { [weak self] in self?.copyAnswerToPasteboard() }
        )

        if let hosting {
            hosting.rootView = rootView
        } else {
            let newHosting = NSHostingView(rootView: rootView)
            newHosting.frame = NSRect(x: 0, y: 0, width: 420, height: 260)
            hosting = newHosting
        }

        if panel == nil {
            panel = makePanel(hosting: hosting!)
        }
        position(panel!)
        panel?.orderFrontRegardless()
    }

    private func copyAnswerToPasteboard() {
        guard !viewModel.answer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(viewModel.answer, forType: .string)
    }

    private func makePanel(hosting: NSView) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
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
        panel.minSize = NSSize(width: 340, height: 160)
        panel.contentView = hosting
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

struct AnswerCardView: View {
    @ObservedObject var viewModel: AnswerCardViewModel
    let onClose: () -> Void
    let onCopy: () -> Void

    @State private var transcriptExpanded = false

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
        .frame(minWidth: 340, idealWidth: 420, minHeight: 160, idealHeight: 260)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(statusLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if viewModel.state == .done || viewModel.state == .streaming {
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
                    .markdownTextStyle(\.code) {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.92))
                        BackgroundColor(Color.secondary.opacity(0.15))
                    }
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .frame(maxHeight: 500)
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
