import AppKit
import ApplicationServices
import SQLite3

/// An immutable recording destination. A composer AX reference alone is insufficient:
/// Electron can reuse that very same element when the user changes conversations.
struct RecordedConversation: @unchecked Sendable {
    let agent: AgentApp
    let window: AXUIElement
    let title: String
    let sessionID: String
    var draft: RecordedDraft? = nil

    static func requiresBinding(_ bundleID: String?) -> Bool {
        bundleID == "com.openai.codex" || bundleID == "com.anthropic.claudefordesktop"
    }

    static func capture(app: NSRunningApplication) -> RecordedConversation? {
        guard requiresBinding(app.bundleIdentifier), AXIsProcessTrusted() else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = element(root, kAXFocusedWindowAttribute) else {
            owLog("[Agent] Conversation capture failed: no focused window")
            return nil
        }
        let agent: AgentApp = app.bundleIdentifier == "com.openai.codex" ? .codex : .claudeCode
        guard let title = currentTitle(window: window, agent: agent), !title.isEmpty else {
            owLog("[Agent] Conversation capture failed: missing window title")
            return nil
        }
        let sessions = agent == .codex ? codexSessions() : claudeSessions()
        // A first message has no database row yet. Bind it to the original input,
        // and invalidate that binding as soon as navigation changes focus/title.
        if isDraftTitle(title, agent: agent), !sessions.contains(where: { $0.title == title }),
           let draft = RecordedDraft(app: app, window: window) {
            return RecordedConversation(agent: agent, window: window, title: title,
                                        sessionID: "draft:" + UUID().uuidString, draft: draft)
        }
        guard let id = uniqueSessionID(title: title, sessions: sessions),
              currentTitle(window: window, agent: agent) == title else {
            owLog("[Agent] Conversation capture failed: title has no unique session or changed during capture (sessions=\(sessions.count), title=\(title))")
            return nil
        }
        return RecordedConversation(agent: agent, window: window, title: title, sessionID: id)
    }

    static func isDraftTitle(_ title: String, agent: AgentApp) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch agent {
        case .codex, .chatGPT:
            return ["codex", "chatgpt", "new chat", "new thread", "yeni sohbet"].contains(title)
        case .claudeCode:
            return ["claude", "claude code", "new session", "new chat", "yeni sohbet"].contains(title)
        }
    }

    /// Never choose the newest of several identically named chats.
    static func uniqueSessionID(title: String, sessions: [(id: String, title: String)]) -> String? {
        let ids = Set(sessions.filter { $0.title == title }.map(\.id))
        return ids.count == 1 ? ids.first : nil
    }

    func isCurrent(in app: NSRunningApplication) -> Bool {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedWindow = Self.element(root, kAXFocusedWindowAttribute),
              CFEqual(focusedWindow, window) else { return false }
        guard let current = Self.currentTitle(window: window, agent: agent) else { return false }
        if let draft { return current == title && draft.isCurrent(in: app) }
        // Auto-generated or user-edited titles can change while transcription is running.
        // Keep the immutable session ID as the identity, rather than rejecting a renamed chat.
        let sessions = agent == .codex ? Self.codexSessions() : Self.claudeSessions()
        return Self.uniqueSessionID(title: current, sessions: sessions) == sessionID
    }

    /// For the Return after a verified paste. Electron replaces a new session's composer
    /// once text lands in it, which ends the draft lease; the window and its still
    /// untitled page are what keep the Return in the chat that was just pasted into.
    func isShown(in app: NSRunningApplication) -> Bool {
        guard draft != nil else { return isCurrent(in: app) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let focusedWindow = Self.element(root, kAXFocusedWindowAttribute),
              CFEqual(focusedWindow, window) else { return false }
        return Self.currentTitle(window: window, agent: agent) == title
    }

    @MainActor
    func restore(in app: NSRunningApplication) async -> Bool {
        guard !app.isTerminated, await AgentAppActivator.bringToFront(app) else { return false }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if isCurrent(in: app) { return await waitForComposer(in: app) }
        // Unsaved drafts have no deep link. Never open another blank chat for them.
        guard draft == nil else { return false }
        let opened: Bool
        switch agent {
        case .codex, .chatGPT:
            opened = await CodexSessionNavigator.openThread(app, id: sessionID, title: title)
        case .claudeCode:
            opened = await ClaudeSessionNavigator.openSession(app, id: sessionID, title: title)
        }
        // A changed title (the navigator's legacy success condition) is not enough.
        guard opened, isCurrent(in: app) else { return false }
        return await waitForComposer(in: app)
    }

    /// The title changes before Electron has mounted the destination's input handlers.
    /// Let navigation settle, then reacquire and focus the new composer before capturing
    /// its paste baseline. Never retain the field found during the transition.
    @MainActor
    private func waitForComposer(in app: NSRunningApplication) async -> Bool {
        do { try await Task.sleep(nanoseconds: 650_000_000) }
        catch { return false }
        guard !app.isTerminated, isCurrent(in: app) else { return false }
        let focused: Bool
        switch agent {
        case .codex, .chatGPT:
            focused = await CodexSessionNavigator.focusComposer(app, timeout: 2.5)
        case .claudeCode:
            focused = await ClaudeSessionNavigator.waitForComposer(app, timeout: 2.5)
        }
        guard focused, !Task.isCancelled, isCurrent(in: app),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              AXTextAccess.focusedEditableElement(matchingPID: app.processIdentifier) != nil else { return false }
        return true
    }

    private static func currentTitle(window: AXUIElement, agent: AgentApp) -> String? {
        if agent == .codex { return string(window, kAXTitleAttribute) }
        // A new session page has no session title yet: its document is titled just "Claude".
        return claudeTitle(window, depth: 24) ?? claudeTitle(window, depth: 24, newSessionPage: true)
    }

    private static func claudeTitle(_ node: AXUIElement, depth: Int, newSessionPage: Bool = false) -> String? {
        let suffix = " - Claude Code"
        if string(node, kAXRoleAttribute) == "AXWebArea", let title = string(node, kAXTitleAttribute) {
            if newSessionPage, title == "Claude" { return title }
            if !newSessionPage, title.hasSuffix(suffix) {
                return String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard depth > 0, string(node, kAXDescriptionAttribute) != "Chat messages" else { return nil }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children)
        for child in children as? [AXUIElement] ?? [] {
            if let title = claudeTitle(child, depth: depth - 1, newSessionPage: newSessionPage) { return title }
        }
        return nil
    }

    private static func element(_ node: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ node: AXUIElement, _ name: String) -> String? {
        AXTextAccess.readString(node, name as CFString).value
    }

    private static func codexSessions() -> [(id: String, title: String)] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(CodexProjectStore.databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { sqlite3_close(handle); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        let sql = "SELECT id, COALESCE(NULLIF(name, ''), title), title FROM threads WHERE archived = 0 AND source NOT LIKE '{%' AND COALESCE(thread_source, '') IN ('user', '')"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var sessions: [(id: String, title: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = sqlite3_column_text(statement, 0), let title = sqlite3_column_text(statement, 1) {
                sessions.append((String(cString: id), String(cString: title)))
                if let originalTitle = sqlite3_column_text(statement, 2) {
                    sessions.append((String(cString: id), String(cString: originalTitle)))
                }
            }
        }
        return sessions
    }

    private static func claudeSessions() -> [(id: String, title: String)] {
        guard let files = FileManager.default.enumerator(at: ClaudeProjectStore.sessionsDirectory,
                                                        includingPropertiesForKeys: nil) else { return [] }
        var sessions: [(id: String, title: String)] = []
        for case let url as URL in files where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["isArchived"] as? Bool != true,
                  let id = json["sessionId"] as? String, let title = json["title"] as? String else { continue }
            sessions.append((id, title))
        }
        return sessions
    }
}

extension PasteContext {
    /// Fail closed if recording-start capture has not completed or the chat cannot be read.
    var conversationIsCurrent: Bool {
        guard RecordedConversation.requiresBinding(bundleIdentifier) else { return true }
        guard let conversation, let targetPID, let app = NSRunningApplication(processIdentifier: targetPID) else { return false }
        return conversation.isCurrent(in: app)
    }

    /// `conversationIsCurrent` for the Return that follows a verified paste.
    var conversationIsShown: Bool {
        guard RecordedConversation.requiresBinding(bundleIdentifier) else { return true }
        guard let conversation, let targetPID, let app = NSRunningApplication(processIdentifier: targetPID) else { return false }
        return conversation.isShown(in: app)
    }
}

/// A draft may only be delivered while its original composer has remained selected.
/// Electron may reuse AX elements, so pointer equality alone is not a navigation guard.
final class RecordedDraft: @unchecked Sendable {
    private let composer: AXUIElement
    private var observer: AXObserver?
    private var deactivationObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var invalidated = false
    /// The app was left (another app, another full-screen Space). Coming back fires one
    /// focus change onto the very same composer; that is not navigation.
    private var awaitingReturn = false

    init?(app: NSRunningApplication, window: AXUIElement) {
        guard let composer = AXTextAccess.focusedEditableElement(matchingPID: app.processIdentifier) else { return nil }
        self.composer = composer
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            let draft = Unmanaged<RecordedDraft>.fromOpaque(context).takeUnretainedValue()
            // Any other focus/navigation event ends the draft's delivery lease, even if the
            // user later returns to a same-titled blank page with a reused AX element.
            draft.lock.lock()
            if draft.awaitingReturn, notification as String == kAXFocusedUIElementChangedNotification,
               CFEqual(element, draft.composer) {
                draft.awaitingReturn = false
            } else {
                draft.invalidated = true
            }
            draft.lock.unlock()
        }
        var observer: AXObserver?
        guard AXObserverCreate(app.processIdentifier, callback, &observer) == .success,
              let observer else { return nil }
        self.observer = observer
        let context = Unmanaged.passUnretained(self).toOpaque()
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard AXObserverAddNotification(observer, root, kAXFocusedUIElementChangedNotification as CFString, context) == .success,
              AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, context) == .success else { return nil }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        let pid = app.processIdentifier
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier == pid else { return }
            self.lock.lock()
            self.awaitingReturn = true
            self.lock.unlock()
        }
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        if let deactivationObserver { NSWorkspace.shared.notificationCenter.removeObserver(deactivationObserver) }
    }

    func isCurrent(in app: NSRunningApplication) -> Bool {
        lock.lock()
        let valid = !invalidated
        lock.unlock()
        guard valid, let current = AXTextAccess.focusedEditableElement(matchingPID: app.processIdentifier) else { return false }
        return CFEqual(current, composer)
    }
}
