import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk: hold to record, release to transcribe.
    /// Default: Control+D. Collides with readline / emacs "delete forward" in
    /// text fields and EOF in terminals while held — users can rebind in
    /// Settings. Fn (🌐) remains the collision-free alternative.
    static let dictate = Self(
        "dictate",
        default: .init(.d, modifiers: [.control])
    )
}

/// Push-to-talk bridge over `sindresorhus/KeyboardShortcuts`.
/// Fires `onPressed` on key-down and `onReleased` on key-up.
@MainActor
final class HotKeyManager {
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    func install() {
        migrateDefaultIfNeeded()
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

    /// One-shot migration. KeyboardShortcuts persists the resolved default the
    /// first time it's registered, so changing the `default:` in `Name.dictate`
    /// doesn't retroactively apply to users who already ran the app. Reset
    /// once so the new default (⌃D) takes effect.
    private func migrateDefaultIfNeeded() {
        let key = "dictateShortcutDefaultMigrationV2"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        KeyboardShortcuts.reset(.dictate)
        defaults.set(true, forKey: key)
        Log.info("hotkey", "migrated .dictate to new default (⌃D)")
    }
}
