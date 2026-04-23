import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk for the Ask-AI flow. Hold to record a question, release
    /// to transcribe + stream an LLM answer into the floating card.
    /// Default: Control+A. Collides with readline / emacs-style "go to start
    /// of line" in text fields while held — users can rebind in Settings.
    static let askAI = Self(
        "askAI",
        default: .init(.a, modifiers: [.control])
    )
}

/// Mirror of `HotKeyManager` but bound to the `.askAI` shortcut. Kept as a
/// separate class so the transcription hotkey wiring stays untouched.
@MainActor
final class AskAIHotKeyManager {
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    func install() {
        migrateDefaultIfNeeded()
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

    /// One-shot migration. KeyboardShortcuts persists the resolved default to
    /// UserDefaults the first time it's registered, so changing the `default:`
    /// in `Name.askAI` doesn't retroactively apply to users who already ran
    /// the app. Reset once so the new default (⌃A) takes effect.
    private func migrateDefaultIfNeeded() {
        let key = "askAIShortcutDefaultMigrationV2"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        KeyboardShortcuts.reset(.askAI)
        defaults.set(true, forKey: key)
        Log.info("hotkey", "migrated .askAI to new default (⌃A)")
    }
}
