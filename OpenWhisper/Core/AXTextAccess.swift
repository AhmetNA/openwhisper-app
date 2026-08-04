import AppKit
import ApplicationServices

/// The destination captured while recording is active.  AXUIElement is a Core Foundation
/// reference whose lifetime is managed by the system; it is intentionally carried through
/// the asynchronous delivery path as an unchecked Sendable value.
struct PasteContext: @unchecked Sendable {
    let targetPID: pid_t?
    let bundleIdentifier: String?
    let applicationName: String?
    let focusedElement: AXUIElement?
    let valueAtCapture: String?
    let selectedRangeAtCapture: CFRange?
    let selectedTextAtCapture: String?

    /// Fast, non-blocking initial context that captures app identity without IPC AX calls.
    static func initial(targetApp: NSRunningApplication? = nil) -> PasteContext {
        let app = targetApp ?? NSWorkspace.shared.frontmostApplication
        return PasteContext(
            targetPID: app?.processIdentifier,
            bundleIdentifier: app?.bundleIdentifier,
            applicationName: app?.localizedName,
            focusedElement: nil,
            valueAtCapture: nil,
            selectedRangeAtCapture: nil,
            selectedTextAtCapture: nil
        )
    }

    /// Capture this before transcription starts, while the user's intended target is still
    /// frontmost.  AX calls can block against an unresponsive application; callers should use
    /// a background queue when capturing from an event-tap callback.
    static func capture(targetApp: NSRunningApplication? = nil) -> PasteContext {
        AXTextAccess.capturePasteContext(targetApp: targetApp)
    }
}

/// Shared Accessibility (AX) read helpers, extracted from AXProbe so both the diagnostic
/// probe (Option+Shift+D) and the real "learning correction" snapshot/reread machinery
/// (DictationSnapshot.swift) share one implementation instead of drifting apart.
///
/// IMPORTANT: like AXProbe, every function here does cross-process AX calls that can block
/// for a noticeable time against a slow/unresponsive target app. Callers MUST dispatch off
/// the CGEventTap callback thread (background queue) — never call these synchronously from
/// GlobalHotkey's tap callback, or a slow app risks macOS force-disabling the tap
/// (tapDisabledByTimeout), dropping Fn/Space/Option+Z events meanwhile.
enum AXTextAccess {

    struct TextState {
        let value: String?
        let selectedRange: CFRange?
        let valueError: AXError
        let selectedRangeError: AXError
    }

    /// Captures the target identity even when AX is unavailable.  A destination is retained
    /// only when the focused element can be identified as editable; this prevents delivery to
    /// an arbitrary focused control after the target application is activated later.
    static func capturePasteContext(targetApp: NSRunningApplication? = nil) -> PasteContext {
        let app = targetApp ?? NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier

        var element: AXUIElement?
        var value: String?
        var selectedRange: CFRange?
        var selectedText: String?

        if AXIsProcessTrusted(), let pid, let focused = focusedElement(matchingPID: pid),
           isSafeEditableElement(focused, matchingPID: pid) {
            element = focused
            let valueResult = readString(focused, kAXValueAttribute as CFString)
            value = valueResult.value
            let rangeResult = readSelectedRange(focused)
            selectedRange = rangeResult.range
            if let value, let range = selectedRange {
                selectedText = utf16Substring(value, range: range)
            }
        }

        return PasteContext(
            targetPID: pid,
            bundleIdentifier: app?.bundleIdentifier,
            applicationName: app?.localizedName,
            focusedElement: element,
            valueAtCapture: value,
            selectedRangeAtCapture: selectedRange,
            selectedTextAtCapture: selectedText
        )
    }

    /// The currently focused AX element system-wide, if any (walks systemWide ->
    /// focused application -> focused UI element, same path as AXProbe).
    /// When `matchingPID` is supplied, the focused element must belong to that
    /// application. Electron/WebKit apps can replace their text element after an edit;
    /// callers can use this to reacquire the replacement without accidentally reading a
    /// different frontmost app.
    static func focusedElement(matchingPID: pid_t? = nil) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedAppRef: AnyObject?
        let focusedAppErr = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef
        )
        guard focusedAppErr == .success, let focusedAppRef,
              CFGetTypeID(focusedAppRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedApp = focusedAppRef as! AXUIElement

        var focusedElementRef: AnyObject?
        let focusedElementErr = AXUIElementCopyAttributeValue(
            focusedApp, kAXFocusedUIElementAttribute as CFString, &focusedElementRef
        )
        guard focusedElementErr == .success, let focusedElementRef,
              CFGetTypeID(focusedElementRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let focusedElement = focusedElementRef as! AXUIElement
        if let matchingPID {
            var focusedPID: pid_t = 0
            guard AXUIElementGetPid(focusedElement, &focusedPID) == .success,
                  focusedPID == matchingPID else {
                return nil
            }
        }
        return focusedElement
    }

    /// Returns the currently focused element only when it is a safe text destination for a
    /// simulated paste.  Terminal and other AX-unreadable editors commonly still expose an
    /// editable text role, so readability of kAXValueAttribute is deliberately not required.
    static func focusedEditableElement(matchingPID: pid_t) -> AXUIElement? {
        guard let element = focusedElement(matchingPID: matchingPID),
              isSafeEditableElement(element, matchingPID: matchingPID) else {
            return nil
        }
        return element
    }

    static func isSafeEditableElement(_ element: AXUIElement, matchingPID: pid_t? = nil) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid > 0,
              matchingPID == nil || matchingPID == pid else {
            return false
        }

        let roleResult = readString(element, kAXRoleAttribute as CFString)
        if let role = roleResult.value {
            let editableRoles: Set<String> = [
                "AXTextField",
                "AXTextArea",
                "AXComboBox",
                "AXSearchField",
                "AXWebArea"
            ]
            if editableRoles.contains(role) {
                return true
            }
        }

        // The pinned macOS/Xcode SDK has no generic editable attribute.  For an unknown role,
        // require both text value and selected-text attributes to be settable.  Requiring both
        // keeps arbitrary value-bearing controls (sliders, checkboxes, and similar elements) out
        // of the paste destination set; AX-unreadable terminals remain covered by the explicit
        // text-role allowlist above.
        var valueSettable = DarwinBoolean(false)
        let valueSettableError = AXUIElementIsAttributeSettable(
            element, kAXValueAttribute as CFString, &valueSettable
        )
        guard valueSettableError == .success, valueSettable.boolValue else {
            return false
        }

        var selectedTextSettable = DarwinBoolean(false)
        let selectedTextSettableError = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &selectedTextSettable
        )
        return selectedTextSettableError == .success && selectedTextSettable.boolValue
    }

    /// Refocuses a previously captured element without ever crossing into another process.
    /// The element-level attribute is preferred; some applications require the focused UI
    /// element to be assigned through the application AX object instead.
    static func focus(_ element: AXUIElement, matchingPID: pid_t) -> Bool {
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success, elementPID == matchingPID,
              isSafeEditableElement(element, matchingPID: matchingPID) else {
            return false
        }

        if AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        ) == .success {
            return true
        }

        let application = AXUIElementCreateApplication(matchingPID)
        return AXUIElementSetAttributeValue(
            application, kAXFocusedUIElementAttribute as CFString, element as CFTypeRef
        ) == .success
    }

    static func readTextState(_ element: AXUIElement) -> TextState {
        let valueResult = readString(element, kAXValueAttribute as CFString)
        let rangeResult = readSelectedRange(element)
        return TextState(
            value: valueResult.value,
            selectedRange: rangeResult.range,
            valueError: valueResult.error,
            selectedRangeError: rangeResult.error
        )
    }

    static func readString(_ element: AXUIElement, _ attribute: CFString) -> (value: String?, error: AXError) {
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute, &ref)
        if err == .success, let str = ref as? String {
            return (str, err)
        }
        return (nil, err)
    }

    /// Reads `kAXSelectedTextRangeAttribute` as a CFRange. AX ranges are expressed in
    /// UTF-16 code units, NOT Swift `String.count` (grapheme clusters) — callers must
    /// convert via `String.Index(utf16Offset:in:)` rather than mixing the two.
    static func readSelectedRange(_ element: AXUIElement) -> (range: CFRange?, error: AXError) {
        var rangeRef: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        guard err == .success, let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return (nil, err)
        }
        let axValue = rangeRef as! AXValue
        var cfRange = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else {
            return (nil, err)
        }
        return (cfRange, err)
    }

    static func readNumberOfCharacters(_ element: AXUIElement) -> (value: Int?, error: AXError) {
        var ref: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &ref)
        if err == .success, let n = ref as? Int {
            return (n, err)
        }
        return (nil, err)
    }

    private static func utf16Substring(_ value: String, range: CFRange) -> String? {
        guard range.location >= 0, range.length >= 0,
              range.location <= value.utf16.count,
              range.length <= value.utf16.count - range.location else {
            return nil
        }
        let start = String.Index(utf16Offset: range.location, in: value)
        let end = String.Index(utf16Offset: range.location + range.length, in: value)
        return String(value[start..<end])
    }

    static func describe(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "kAXErrorFailure"
        case .illegalArgument: return "kAXErrorIllegalArgument"
        case .invalidUIElement: return "kAXErrorInvalidUIElement"
        case .invalidUIElementObserver: return "kAXErrorInvalidUIElementObserver"
        case .cannotComplete: return "kAXErrorCannotComplete"
        case .attributeUnsupported: return "kAXErrorAttributeUnsupported"
        case .actionUnsupported: return "kAXErrorActionUnsupported"
        case .notificationUnsupported: return "kAXErrorNotificationUnsupported"
        case .notImplemented: return "kAXErrorNotImplemented"
        case .notificationAlreadyRegistered: return "kAXErrorNotificationAlreadyRegistered"
        case .notificationNotRegistered: return "kAXErrorNotificationNotRegistered"
        case .apiDisabled: return "kAXErrorAPIDisabled"
        case .noValue: return "kAXErrorNoValue"
        case .parameterizedAttributeUnsupported: return "kAXErrorParameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "kAXErrorNotEnoughPrecision"
        @unknown default: return "unknown(\(error.rawValue))"
        }
    }
}
