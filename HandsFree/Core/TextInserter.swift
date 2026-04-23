import AppKit

/// Routes transcribed text to the right destination:
/// - If a text field is focused → put on pasteboard + synthesize ⌘V
/// - Otherwise → pasteboard only (user can paste anywhere)
enum TextInserter {
    enum Result {
        case pasted
        case clipboardOnly
    }

    @MainActor
    static func deliver(_ text: String) -> Result {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        let editable = FocusInspector.focusedElementIsEditable()
        Log.info("insert", "focused editable=\(editable), chars=\(text.count)")

        guard editable else { return .clipboardOnly }
        sendCmdV()
        return .pasted
    }

    private static func sendCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09  // ANSI 'V'

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
