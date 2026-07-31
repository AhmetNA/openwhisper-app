import AppKit
import ApplicationServices

/// TEMPORARY diagnostic tool — measures whether the Accessibility (AX) API can read the
/// contents of the text field currently under the caret in the frontmost app. This is
/// purely a measurement: it does NOT store, diff, or persist anything. The result informs
/// whether a future "learn from manual corrections" feature can rely on AX-read text, or
/// needs a different approach (e.g. tracking only what OpenWhisper itself injected).
///
/// Remove this file (and its hotkey wiring in GlobalHotkey/AppState) once the measurement
/// has been taken — it is not meant to ship long-term.
enum AXProbe {

    /// Run the probe against whatever is focused right now and log the results via owLog.
    /// Never touches the pasteboard.
    static func run() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        let appName = frontmost?.localizedName ?? "?"
        let bundleID = frontmost?.bundleIdentifier ?? "?"
        owLog("[AXProbe] --- probe start: \(appName) (\(bundleID)) ---")

        guard let element = AXTextAccess.focusedElement() else {
            owLog("[AXProbe] SUMMARY \(appName) (\(bundleID)) role=? value=OKUNAMADI(no focused element)")
            return
        }

        // Role / subrole
        let role = readString(element, kAXRoleAttribute as CFString)
        let subrole = readString(element, kAXSubroleAttribute as CFString)
        owLog("[AXProbe] role=\(role.value ?? "OKUNAMADI(\(describe(role.error)))") subrole=\(subrole.value ?? "OKUNAMADI(\(describe(subrole.error)))")")

        // Value (the full field contents)
        var valueRef: AnyObject?
        let valueErr = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        var valueSummary: String
        if valueErr == .success, let str = valueRef as? String {
            let preview = String(str.prefix(80))
            valueSummary = "OKUNDU(\(str.count) char) preview=\"\(preview)\""
            owLog("[AXProbe] kAXValueAttribute: \(describe(valueErr)) — \(valueSummary)")
        } else if valueErr == .success {
            valueSummary = "OKUNDU(ama String değil: \(type(of: valueRef)))"
            owLog("[AXProbe] kAXValueAttribute: \(describe(valueErr)) — \(valueSummary)")
        } else {
            valueSummary = "OKUNAMADI(\(describe(valueErr)))"
            owLog("[AXProbe] kAXValueAttribute: \(describe(valueErr))")
        }

        // Selected text
        var selectedTextRef: AnyObject?
        let selectedTextErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedTextRef)
        var selectedSummary: String
        if selectedTextErr == .success, let str = selectedTextRef as? String {
            selectedSummary = "OKUNDU(\(str.count) char)"
        } else {
            selectedSummary = "OKUNAMADI(\(describe(selectedTextErr)))"
        }
        owLog("[AXProbe] kAXSelectedTextAttribute: \(describe(selectedTextErr)) — \(selectedSummary)")

        // Selected text range
        var selectedRangeRef: AnyObject?
        let selectedRangeErr = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRangeRef)
        owLog("[AXProbe] kAXSelectedTextRangeAttribute: \(describe(selectedRangeErr))")

        // Number of characters
        var numCharsRef: AnyObject?
        let numCharsErr = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &numCharsRef)
        var numCharsSummary: String
        if numCharsErr == .success, let n = numCharsRef as? Int {
            numCharsSummary = "OKUNDU(\(n))"
        } else if numCharsErr == .success {
            numCharsSummary = "OKUNDU(tip: \(type(of: numCharsRef)))"
        } else {
            numCharsSummary = "OKUNAMADI(\(describe(numCharsErr)))"
        }
        owLog("[AXProbe] kAXNumberOfCharactersAttribute: \(describe(numCharsErr)) — \(numCharsSummary)")

        // Settable?
        var settable: DarwinBoolean = false
        let settableErr = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        let settableSummary = settableErr == .success ? (settable.boolValue ? "EVET" : "HAYIR") : "BILINMIYOR(\(describe(settableErr)))"
        owLog("[AXProbe] AXUIElementIsAttributeSettable(kAXValueAttribute): \(describe(settableErr)) — settable=\(settableSummary)")

        // One-line summary
        let roleStr = role.value ?? "?"
        let summary = "[AXProbe] SUMMARY \(appName) (\(bundleID)) role=\(roleStr) value=\(valueSummary) selected=\(selectedSummary) settable=\(settableSummary)"
        owLog(summary)
        owLog("[AXProbe] --- probe end ---")
    }

    private static func readString(_ element: AXUIElement, _ attribute: CFString) -> (value: String?, error: AXError) {
        AXTextAccess.readString(element, attribute)
    }

    private static func describe(_ error: AXError) -> String {
        AXTextAccess.describe(error)
    }
}
