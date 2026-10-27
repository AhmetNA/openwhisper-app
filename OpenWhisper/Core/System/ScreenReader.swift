import AppKit
import ApplicationServices

/// Reads the front window of an app over Accessibility: its visible text, for "bunu özetle"
/// outside Safari.
enum ScreenReader {
    /// Electron apps show their web content only with this set (see ClaudeSessionNavigator).
    private static let electronBundleIDs: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.codex"]

    /// Electron apps (Claude, Codex, Slack, VS Code, Discord…) build their accessibility tree
    /// only once asked through `AXManualAccessibility`; recognized by the framework they ship.
    static func isElectron(_ app: NSRunningApplication) -> Bool {
        if electronBundleIDs.contains(app.bundleIdentifier ?? "") { return true }
        guard let url = app.bundleURL else { return false }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    static func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if isElectron(app) {
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let window = element(root, kAXFocusedWindowAttribute) ?? element(root, kAXMainWindowAttribute) else { return nil }
        // A hung app must not stall the walk below its window either.
        AXUIElementSetMessagingTimeout(window, 0.5)
        return window
    }

    /// The window's title and the text it shows, in reading order, up to `limit` characters.
    static func windowText(of app: NSRunningApplication, limit: Int = 6000) -> (title: String, text: String)? {
        guard let window = focusedWindow(of: app) else { return nil }
        var parts: [String] = []
        var length = 0
        var visited = 0
        func walk(_ node: AXUIElement, depth: Int) {
            guard length < limit, visited < 4000, depth < 40 else { return }
            visited += 1
            let role = string(node, kAXRoleAttribute) ?? ""
            if ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading"].contains(role),
               let text = string(node, kAXValueAttribute) ?? string(node, kAXTitleAttribute) {
                let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !flat.isEmpty, parts.last != flat {
                    parts.append(flat)
                    length += flat.count + 1
                }
            }
            for child in children(node) { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        let text = String(parts.joined(separator: "\n").prefix(limit))
        return (string(window, kAXTitleAttribute) ?? app.localizedName ?? "Pencere", text)
    }

    // MARK: - AX helpers

    static func children(_ node: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
