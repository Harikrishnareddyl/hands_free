import AppKit
import ApplicationServices

/// Push-to-talk on the Fn / 🌐 key. Carbon hotkeys can't register Fn alone,
/// so we watch system-wide `flagsChanged` events via a CGEventTap.
///
/// Requires **Input Monitoring** permission.
/// The user should also set System Settings → Keyboard → "Press 🌐 key to"
/// to "Do Nothing", otherwise macOS's own emoji picker / dictation will fire
/// alongside our handler.
@MainActor
final class FnHotKeyMonitor {
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isFnDown = false

    /// Returns `true` if the tap was installed. `false` usually means the
    /// user hasn't granted Input Monitoring yet.
    /// True once a tap has been successfully installed.
    var isInstalled: Bool { eventTap != nil }

    @discardableResult
    func install() -> Bool {
        if isInstalled { return true }

        Log.info("hotkey", "installing Fn event tap")
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo, type == .flagsChanged else {
                    return Unmanaged.passUnretained(event)
                }
                let monitor = Unmanaged<FnHotKeyMonitor>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                let fnPressed = event.flags.contains(.maskSecondaryFn)
                Task { @MainActor in
                    monitor.handle(fnPressed: fnPressed)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: info
        ) else {
            Log.error("hotkey", "CGEvent.tapCreate returned nil — Input Monitoring not granted?")
            return false
        }

        let rls = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = rls
        Log.info("hotkey", "Fn tap installed")
        return true
    }

    func uninstall() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isFnDown = false
    }

    /// Opens System Settings → Privacy & Security → Input Monitoring.
    static func openInputMonitoringPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private func handle(fnPressed: Bool) {
        if fnPressed && !isFnDown {
            isFnDown = true
            Log.info("hotkey", "Fn pressed")
            onPressed?()
        } else if !fnPressed && isFnDown {
            isFnDown = false
            Log.info("hotkey", "Fn released")
            onReleased?()
        }
    }
}
