import AppKit
import ApplicationServices

/// Opens a new Codex chat (optionally in a project folder) or an existing one through the
/// app's own codex:// links, then focuses the composer so the paste path can write there.
@MainActor
enum CodexSessionNavigator {
    private static let lastThreadKey = "agent.codex.lastThread"

    /// The chat just summarized, so "son sohbete yaz …" and the message after the recap go there.
    static var lastThread: (id: String, title: String)? {
        guard let pair = UserDefaults.standard.stringArray(forKey: lastThreadKey), pair.count == 2 else { return nil }
        return (pair[0], pair[1])
    }

    static func rememberThread(id: String, title: String) {
        UserDefaults.standard.set([id, title], forKey: lastThreadKey)
    }

    /// After a send: the chat on screen becomes "son sohbet". A brand-new chat has no id yet,
    /// so the old one is forgotten rather than kept as "son".
    static func rememberThread(shownIn app: NSRunningApplication) {
        if let shown = RecordedConversation.capture(app: app), shown.agent == .codex, shown.draft == nil {
            rememberThread(id: shown.sessionID, title: shown.title)
        } else {
            UserDefaults.standard.removeObject(forKey: lastThreadKey)
        }
    }

    /// `codex://threads/new`, with `?path=` to start it in that project.
    static func openNewThread(_ app: NSRunningApplication, folder: String?) async -> Bool {
        var components = URLComponents(string: "codex://threads/new")!
        if let folder { components.queryItems = [URLQueryItem(name: "path", value: folder)] }
        guard let url = components.url, await AgentAppActivator.openLink(url) else { return false }
        // The composer placeholder sits in its value, so an empty field cannot be told apart;
        // give the new chat a moment to replace the old one.
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard await focusComposer(app, timeout: 2.5) else { return false }
        owLog("[Agent] Codex: opened a new chat\(folder.map { " in \($0)" } ?? "")")
        return true
    }

    /// `codex://threads/<id>`; true once the window shows that chat. An unnamed chat's title
    /// is its first message, which the window may shorten, so a changed title also counts.
    static func openThread(_ app: NSRunningApplication, id: String, title: String) async -> Bool {
        let before = windowTitle(app)
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "codex://threads/\(encoded)"),
              await AgentAppActivator.openLink(url) else { return false }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let current = windowTitle(app)
            if current == title || (current != nil && current != before) {
                guard await focusComposer(app, timeout: 1.5) else { return false }
                owLog("[Agent] Codex: opened chat \"\(title)\"")
                return true
            }
        }
        owLog("[Agent] Codex: chat \"\(title)\" did not open in time")
        return false
    }

    static func focusComposer(_ app: NSRunningApplication, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            guard !app.isTerminated, !Task.isCancelled,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
            let root = appElement(app)
            let window = attribute(root, kAXFocusedWindowAttribute).map { $0 as! AXUIElement } ?? root
            // Deep links already focus the composer. Its editable AX element need not
            // be an AXTextArea or appear in the window's enumerated children. Use the
            // same focused-element lookup as the working ordinary dictation path.
            let focused = AXTextAccess.focusedEditableElement(matchingPID: app.processIdentifier)
            let composer = focused ?? find(in: window, maxDepth: 40, where: {
                attribute($0, kAXRoleAttribute) as? String == kAXTextAreaRole
                    && AXTextAccess.isSafeEditableElement($0, matchingPID: app.processIdentifier)
            })
            if let composer {
                if focused != nil || AXTextAccess.focus(composer, matchingPID: app.processIdentifier) {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if !Task.isCancelled,
                       NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                       let current = AXTextAccess.focusedEditableElement(matchingPID: app.processIdentifier),
                       CFEqual(current, composer) {
                        owLog("[Agent] Codex: editable composer focus verified")
                        return true
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        } while Date() < deadline
        owLog("[Agent] Codex: no composer found")
        return false
    }

    private static func windowTitle(_ app: NSRunningApplication) -> String? {
        guard let window = attribute(appElement(app), kAXFocusedWindowAttribute) else { return nil }
        return attribute(window as! AXUIElement, kAXTitleAttribute) as? String
    }

    private static func appElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    /// Depth-first, skipping the conversation: it can hold thousands of nodes.
    private static func find(in element: AXUIElement, maxDepth: Int, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        if predicate(element) { return element }
        guard maxDepth > 0, attribute(element, kAXDescriptionAttribute) as? String != "Conversation" else { return nil }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if let match = find(in: child, maxDepth: maxDepth - 1, where: predicate) { return match }
        }
        return nil
    }
}
