import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk: hold to record, release to transcribe.
    /// Default: Control+Option+D (easy to hold, unlikely to collide).
    static let dictate = Self(
        "dictate",
        default: .init(.d, modifiers: [.control, .option])
    )
}

/// Push-to-talk bridge over `sindresorhus/KeyboardShortcuts`.
/// Fires `onPressed` on key-down and `onReleased` on key-up.
@MainActor
final class HotKeyManager {
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    func install() {
        Log.info("hotkey", "installing KeyboardShortcuts handler for .dictate")
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in
            Log.info("hotkey", "dictate key down")
            self?.onPressed?()
        }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in
            Log.info("hotkey", "dictate key up")
            self?.onReleased?()
        }
    }
}
