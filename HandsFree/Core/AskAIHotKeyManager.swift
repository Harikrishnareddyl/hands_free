import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk for the Ask-AI flow. Hold to record a question, release
    /// to transcribe + stream an LLM answer into the floating card.
    /// Default: Control+Option+A (parallel to `.dictate`'s ⌃⌥D).
    static let askAI = Self(
        "askAI",
        default: .init(.a, modifiers: [.control, .option])
    )
}

/// Mirror of `HotKeyManager` but bound to the `.askAI` shortcut. Kept as a
/// separate class so the transcription hotkey wiring stays untouched.
@MainActor
final class AskAIHotKeyManager {
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    func install() {
        Log.info("hotkey", "installing KeyboardShortcuts handler for .askAI")
        KeyboardShortcuts.onKeyDown(for: .askAI) { [weak self] in
            Log.info("hotkey", "askAI key down")
            self?.onPressed?()
        }
        KeyboardShortcuts.onKeyUp(for: .askAI) { [weak self] in
            Log.info("hotkey", "askAI key up")
            self?.onReleased?()
        }
    }
}
