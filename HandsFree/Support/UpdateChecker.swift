import AppKit
import Foundation

/// Polls the GitHub Releases API once on launch (and on demand) and surfaces an
/// NSAlert if a newer version is available. Clicking "Install update" spawns
/// the install.sh one-liner detached from the app, then quits — the installer
/// kills the old process, overwrites the bundle, and launches the new one.
enum UpdateChecker {

    struct UpdateInfo {
        let latestTag: String        // e.g. "v0.1.2"
        let latestVersion: String    // e.g. "0.1.2"
        let currentVersion: String   // e.g. "0.1.0"
        let htmlURL: URL
        let body: String
    }

    private static let repo = "Harikrishnareddyl/hands-free"
    private static let installerURL = "https://raw.githubusercontent.com/\(repo)/main/install.sh"
    private static let dismissedKey = "updateDismissedVersion"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // MARK: - Checking

    /// Fetches the latest release and returns an UpdateInfo iff it's newer
    /// than the currently-running build. Any network/JSON error → nil.
    static func fetchLatest() async -> UpdateInfo? {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                Log.info("update", "release API returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }

            let decoded = try JSONDecoder().decode(ReleasePayload.self, from: data)
            let latestVersion = decoded.tag_name.hasPrefix("v")
                ? String(decoded.tag_name.dropFirst())
                : decoded.tag_name

            guard isVersion(latestVersion, newerThan: currentVersion) else {
                Log.info("update", "up to date: \(currentVersion) vs latest \(latestVersion)")
                return nil
            }

            return UpdateInfo(
                latestTag: decoded.tag_name,
                latestVersion: latestVersion,
                currentVersion: currentVersion,
                htmlURL: URL(string: decoded.html_url)!,
                body: decoded.body ?? ""
            )
        } catch {
            Log.error("update", "check failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Numeric SemVer comparison (major.minor.patch). Anything unparseable
    /// compares as 0. Extra components beyond patch are ignored.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Persisted "don't ask again for version X" state

    private static var lastDismissedVersion: String? {
        get { UserDefaults.standard.string(forKey: dismissedKey) }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    /// True if we should NOT auto-prompt for this specific version because
    /// the user already clicked "Later" on it.
    static func wasDismissed(_ info: UpdateInfo) -> Bool {
        lastDismissedVersion == info.latestVersion
    }

    static func recordDismissal(_ info: UpdateInfo) {
        lastDismissedVersion = info.latestVersion
    }

    // MARK: - Alert

    /// Presents an NSAlert for the given update. Returns on the main thread
    /// and drives the user's choice:
    /// - "Install update" → spawns detached installer + terminates self.
    /// - "Release notes"  → opens the release page in the browser (and re-asks).
    /// - "Later"          → records dismissal for this version and returns.
    @MainActor
    static func presentAlert(for info: UpdateInfo) {
        let alert = NSAlert()
        alert.messageText = "HandsFree \(info.latestVersion) is available"
        alert.informativeText = "You're on \(info.currentVersion). The installer will download and replace /Applications/HandsFree.app, then relaunch. Your settings and history are preserved."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install update")
        alert.addButton(withTitle: "Release notes")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Log.info("update", "user accepted update to \(info.latestVersion)")
            runInstallerAndQuit()
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(info.htmlURL)
            // Re-show alert after they've seen the notes.
            presentAlert(for: info)
        default:
            Log.info("update", "user postponed \(info.latestVersion)")
            recordDismissal(info)
        }
    }

    /// Starts the install.sh pipeline detached from the app, then terminates
    /// the current process. The installer will re-launch the new version.
    @MainActor
    static func runInstallerAndQuit() {
        let logPath = "/tmp/handsfree-update.log"
        // `setsid` detaches so the child survives our termination.
        // `disown` removes job-control link. Belt-and-braces.
        let cmd = """
        (sleep 1 && /usr/bin/curl -fsSL \(installerURL) | /bin/bash) \
            > \(logPath) 2>&1 < /dev/null &
        disown
        """
        Log.info("update", "spawning installer; log at \(logPath)")
        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", cmd]
        task.standardInput = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Log.error("update", "failed to spawn installer: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Couldn't launch the updater"
            alert.informativeText = "Run this in Terminal to update manually:\n\ncurl -fsSL \(installerURL) | bash"
            alert.runModal()
            return
        }
        // Give the child 300ms to fork+exec past our exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Decoding

    private struct ReleasePayload: Decodable {
        let tag_name: String
        let html_url: String
        let body: String?
    }
}
