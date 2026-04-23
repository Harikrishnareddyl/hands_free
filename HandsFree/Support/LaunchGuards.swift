import AppKit
import Foundation

/// Prevents common footguns around running the app from the wrong place.
/// - Two copies running at once (one from a DMG mount, one from /Applications)
/// - Running directly from a DMG mount point (translocated or not)
enum LaunchGuards {
    /// If another instance of the same bundle ID is running, activate it and
    /// quit ourselves. Returns `true` if we told the app to terminate.
    @MainActor
    static func enforceSingleInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }

        guard let existing = others.first else { return false }
        Log.info("app", "duplicate instance detected (pid=\(existing.processIdentifier)) — bringing it forward and quitting self")
        existing.activate()
        NSApp.terminate(nil)
        return true
    }

    /// Returns true if we're running from a `/Volumes/...` mount (DMG/disk image)
    /// or from macOS's App Translocation quarantine path.
    static var runningFromDiskImageOrTranslocated: Bool {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Volumes/") { return true }
        if path.contains("/AppTranslocation/") { return true }
        return false
    }

    /// Shows a modal alert nudging the user to drag the app into /Applications.
    /// No-op if a real copy of the same app already exists there.
    @MainActor
    static func nudgeToApplicationsIfNeeded() {
        guard runningFromDiskImageOrTranslocated else { return }

        let alert = NSAlert()
        alert.messageText = "Move HandsFree to Applications"
        alert.informativeText = "For HandsFree to work reliably (keeping your macOS permissions, running at login, avoiding duplicates) please drag it out of the disk image into your Applications folder, then launch it from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Run anyway")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        } else {
            Log.info("app", "user chose to run from disk image anyway")
        }
    }
}
