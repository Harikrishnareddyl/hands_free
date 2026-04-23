import AppKit
import SwiftUI

@MainActor
final class WindowCoordinator {
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func showSettings() {
        if let w = settingsWindow {
            activate(w)
            return
        }
        let w = makeWindow(
            title: "Hands-Free Settings",
            size: NSSize(width: 480, height: 560),
            content: SettingsView()
        )
        settingsWindow = w
        activate(w)
    }

    func showHistory() {
        if let w = historyWindow {
            activate(w)
            return
        }
        let w = makeWindow(
            title: "Hands-Free History",
            size: NSSize(width: 720, height: 480),
            content: HistoryView()
        )
        historyWindow = w
        activate(w)
    }

    private func activate(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<V: View>(title: String, size: NSSize, content: V) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.center()
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = nil       // don't auto-focus the first text field
        return window
    }
}
