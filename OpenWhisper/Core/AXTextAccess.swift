import AppKit
import ApplicationServices

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
