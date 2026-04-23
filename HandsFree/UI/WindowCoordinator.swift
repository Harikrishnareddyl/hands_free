import AppKit
import SwiftUI

@MainActor
final class WindowCoordinator {
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func showSettings() {
        if let w = settingsWindow {
            activate(w)
            return
        }
        let w = makeWindow(
            title: "Hands-Free Settings",
            size: NSSize(width: 480, height: 560),
            style: [.titled, .closable, .miniaturizable, .resizable],
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
            style: [.titled, .closable, .miniaturizable, .resizable],
            content: HistoryView()
        )
        historyWindow = w
        activate(w)
    }

    /// Onboarding: modal-ish gate for missing required permissions.
    /// Only Quit and Continue buttons inside — no window close button,
    /// so the user can't sneak past the gate.
    func showOnboarding(view: OnboardingView) {
        if let w = onboardingWindow {
            activate(w)
            return
        }
        let w = makeWindow(
            title: "HandsFree — Setup",
            size: NSSize(width: 560, height: 460),
            style: [.titled],   // no .closable → no red close button
            content: view
        )
        w.isMovable = true
        onboardingWindow = w
        activate(w)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: - Helpers

    private func activate(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow<V: View>(
        title: String,
        size: NSSize,
        style: NSWindow.StyleMask,
        content: V
    ) -> NSWindow {
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = style
        window.setContentSize(size)
        window.center()
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = nil   // don't auto-focus the first text field
        return window
    }
}
