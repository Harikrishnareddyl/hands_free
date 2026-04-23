import AppKit
import ApplicationServices

/// Reads the currently-focused UI element via the Accessibility API to decide
/// whether we can paste directly into it or should fall back to the clipboard.
enum FocusInspector {
    /// Returns whether the Accessibility permission has been granted.
    /// Pass `prompt: true` to show the system prompt and deep-link to Settings.
    static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// Opens System Settings → Privacy & Security → Accessibility.
    static func openAccessibilityPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True if a text-editable element is currently focused system-wide.
    static func focusedElementIsEditable() -> Bool {
        guard isAccessibilityTrusted() else { return false }

        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let raw = focused else { return false }
        let element = raw as! AXUIElement

        // Accept known editable roles directly.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String {
            let editable: Set<String> = [
                "AXTextField",
                "AXTextArea",
                "AXSearchField",
                "AXComboBox",
            ]
            if editable.contains(role) { return true }
        }

        // Web inputs often report AXGroup/AXStaticText roles but still have a settable value.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }
}
