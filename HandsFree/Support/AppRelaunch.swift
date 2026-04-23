import AppKit
import Foundation

/// Spawns a detached `open` that waits briefly and relaunches this app, then
/// terminates the current process. Used by the onboarding and the Debug menu
/// items to drop the running process's in-memory TCC caches after a
/// `tccutil reset` — without this, the current instance keeps seeing the
/// stale authorization status forever.
@MainActor
enum AppRelaunch {
    static func quitAndRestart() {
        let appPath = Bundle.main.bundlePath
        let cmd = "(sleep 1 && open \"\(appPath)\") >/tmp/handsfree-relaunch.log 2>&1 </dev/null & disown"

        let task = Process()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", cmd]
        task.standardInput = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            Log.error("app", "relaunch spawn failed: \(error.localizedDescription)")
        }

        // Give the child a moment to fork past our exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}
