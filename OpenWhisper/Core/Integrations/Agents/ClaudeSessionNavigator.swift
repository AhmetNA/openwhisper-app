import AppKit
import ApplicationServices

/// Opens a new Claude Code session, or switches back to a named one, in the Claude desktop
/// app through Accessibility, so "yeni session'a gönder" / "son session'a gönder" paste into
/// the right conversation. The app is Electron: its web content only shows up in the AX tree
/// once `AXManualAccessibility` is set, and then fills in lazily, so every lookup retries.
@MainActor
enum ClaudeSessionNavigator {
    private static let titleSuffix = " - Claude Code"
    private static let lastSessionKey = "agent.claude.lastSessionTitle"
    /// Sidebar titles from before the last "New session" press: the new session's row is the
    /// one that shows up later, which tells it apart from a session the user opened by hand.
    private static var rowTitlesBeforeNew: Set<String> = []
    /// Only the newest send may set the last session.
    private static var rememberGeneration = 0

    private static let lastSessionIDKey = "agent.claude.lastSessionID"

    /// The session Jarvis last sent to, kept across restarts.
    static var lastSessionTitle: String? {
        get { UserDefaults.standard.string(forKey: lastSessionKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: lastSessionKey)
            UserDefaults.standard.removeObject(forKey: lastSessionIDKey)
        }
    }

    /// The last session's id, when known (a summarized session): it opens by link, not by title.
    static var lastSessionID: String? { UserDefaults.standard.string(forKey: lastSessionIDKey) }

    /// The session just summarized becomes "son session", so the next message goes there.
    static func rememberSession(id: String, title: String) {
        lastSessionTitle = title
        UserDefaults.standard.set(id, forKey: lastSessionIDKey)
    }

    /// Title of the session shown in the frontmost Claude window, nil outside the Code tab.
    static func currentSessionTitle(_ app: NSRunningApplication) -> String? {
        let root = appElement(app)
        guard let area = find(in: root, maxDepth: 16, where: {
            role($0) == "AXWebArea" && (title($0)?.hasSuffix(titleSuffix) ?? false)
        }), let full = title(area) else { return nil }
        let name = String(full.dropLast(titleSuffix.count)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Presses the sidebar's "New session" and waits for its empty composer to take focus.
    static func openNewSession(_ app: NSRunningApplication) async -> Bool {
        let before = currentSessionTitle(app)
        // Newer Claude versions label it with the title "New" instead (2026-10-22).
        guard let button = await sidebarElement(app, where: {
            description($0) == "New session" || (role($0) == kAXButtonRole && title($0) == "New")
        }) else {
            owLog("[Agent] Claude: no \"New session\" button found")
            return false
        }
        rowTitlesBeforeNew = await sidebarRowTitles(app)
        press(button)
        return await waitForNewSession(app, before: before)
    }

    /// Opens a new Code session in `folder` through Claude's own link (the one its Dock menu
    /// uses), so the session starts in that project.
    static func openNewSession(_ app: NSRunningApplication, folder: String) async -> Bool {
        var components = URLComponents(string: "claude://code/new")!
        components.queryItems = [URLQueryItem(name: "folder", value: folder), URLQueryItem(name: "source", value: "desktop_action")]
        let before = currentSessionTitle(app)
        rowTitlesBeforeNew = await sidebarRowTitles(app)
        guard let url = components.url, await AgentAppActivator.openLink(url) else { return false }
        return await waitForNewSession(app, before: before)
    }

    /// Switches to session `id` through Claude's link; its sidebar row when the link does
    /// nothing (Claude can turn these links off).
    static func openSession(_ app: NSRunningApplication, id: String, title: String) async -> Bool {
        if !title.isEmpty, currentSessionTitle(app) == title {
            if let prompt = promptField(app) { focus(prompt) }
            return true
        }
        var components = URLComponents(string: "claude://code/continue")!
        components.queryItems = [URLQueryItem(name: "session", value: id), URLQueryItem(name: "source", value: "desktop_action")]
        if let url = components.url, await AgentAppActivator.openLink(url) {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if currentSessionTitle(app) == title, let prompt = promptField(app) {
                    focus(prompt)
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    owLog("[Agent] Claude: opened session \"\(title)\" by link")
                    return true
                }
            }
        }
        guard !title.isEmpty, await AgentAppActivator.bringToFront(app) else { return false }
        return await selectSession(app, titled: title)
    }

    /// The composer is reused across sessions, so wait for the title to change (or the
    /// field to be empty) before handing it to the paste path.
    private static func waitForNewSession(_ app: NSRunningApplication, before: String?) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let prompt = promptField(app), (value(prompt) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               currentSessionTitle(app) != before || before == nil {
                focus(prompt)
                try? await Task.sleep(nanoseconds: 150_000_000)
                owLog("[Agent] Claude: opened a new session")
                return true
            }
        }
        owLog("[Agent] Claude: the new session's composer did not appear in time")
        return false
    }

    /// Waits until the composer exists and focuses it. Right after a cold launch Claude is
    /// frontmost long before its web content loads, and a paste then goes nowhere.
    static func waitForComposer(_ app: NSRunningApplication, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if app.isTerminated { return false }
            if app.isFinishedLaunching, let prompt = promptField(app) {
                focus(prompt)
                // Let the freshly loaded composer take the focus before anything is pasted.
                try? await Task.sleep(nanoseconds: 300_000_000)
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        } while Date() < deadline
        owLog("[Agent] Claude: the composer did not appear within \(Int(timeout))s")
        return false
    }

    /// After Return: whether the composer still holds `text`, i.e. the message never left.
    /// False when the composer cannot be read, so a missing AX tree never fakes a failure.
    static func composerStillHolds(_ app: NSRunningApplication, text: String) async -> Bool {
        let needle = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !needle.isEmpty else { return false }
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let prompt = promptField(app), let current = value(prompt) else { return false }
            if !current.contains(needle) { return false }
        } while Date() < deadline
        return true
    }

    /// Switches to the sidebar session titled `name` (expanding collapsed day groups if
    /// needed) and focuses its composer. False when no such session is listed.
    static func selectSession(_ app: NSRunningApplication, titled name: String) async -> Bool {
        if currentSessionTitle(app) == name {
            if let prompt = promptField(app) { focus(prompt) }
            return true
        }
        // A running or spawned session's row title also carries "Running" / "Started by …",
        // so its first text is compared too.
        let isRow: (AXUIElement) -> Bool = {
            role($0) == kAXButtonRole && (title($0) == name || (title($0)?.hasPrefix(name + " ") == true && rowName($0) == name))
        }
        var row = await sidebarElement(app, where: isRow)
        if row == nil, let sidebar = await sidebarElement(app, where: { _ in true }, wantSidebar: true) {
            // "Show 3 more in Today": older rows of a day are only listed after expanding it.
            for more in findAll(in: sidebar, maxDepth: 12, where: {
                role($0) == kAXButtonRole && (description($0)?.hasPrefix("Show ") ?? false)
                    && (description($0)?.contains(" more") ?? false)
            }) {
                press(more)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            row = find(in: sidebar, maxDepth: 14, where: isRow)
        }
        guard let row else {
            owLog("[Agent] Claude: session \"\(name)\" is not in the sidebar")
            return false
        }
        press(row)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if currentSessionTitle(app) == name, let prompt = promptField(app) {
                focus(prompt)
                try? await Task.sleep(nanoseconds: 150_000_000)
                owLog("[Agent] Claude: switched to session \"\(name)\"")
                return true
            }
        }
        owLog("[Agent] Claude: session \"\(name)\" did not open in time")
        return false
    }

    /// Remembers the session a message just went to. A brand-new session is renamed by
    /// Claude after its first message, so it is only stored once its own sidebar row shows
    /// up; until then "son session" knows no session rather than naming the previous one.
    static func rememberSession(_ app: NSRunningApplication, wasNew: Bool) {
        rememberGeneration += 1
        let generation = rememberGeneration
        let placeholder = currentSessionTitle(app)
        if !wasNew {
            if let placeholder { lastSessionTitle = placeholder }
            return
        }
        lastSessionTitle = nil
        let before = rowTitlesBeforeNew
        Task { @MainActor in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard generation == rememberGeneration else { return }
                // Windows of an app that is not in front can be missing from the AX tree.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      let title = currentSessionTitle(app), title != placeholder, !before.contains(title)
                else { continue }
                lastSessionTitle = title
                owLog("[Agent] Claude: last session is now \"\(title)\"")
                return
            }
            // Claude may have named it from the first message right away.
            guard generation == rememberGeneration, let placeholder, !before.contains(placeholder),
                  await sidebarRowTitles(app).contains(placeholder) else {
                owLog("[Agent] Claude: could not tell the new session's title")
                return
            }
            lastSessionTitle = placeholder
        }
    }

    private static func sidebarRowTitles(_ app: NSRunningApplication) async -> Set<String> {
        guard let sidebar = await sidebarElement(app, where: { _ in true }, wantSidebar: true) else { return [] }
        return Set(findAll(in: sidebar, maxDepth: 14, where: { role($0) == kAXButtonRole }).compactMap(title).filter { !$0.isEmpty })
    }

    // MARK: - Lookup

    /// Finds an element in the sidebar, switching to the Code tab or showing a hidden
    /// sidebar when that is why it is missing.
    private static func sidebarElement(
        _ app: NSRunningApplication,
        where predicate: @escaping (AXUIElement) -> Bool,
        wantSidebar: Bool = false
    ) async -> AXUIElement? {
        var triedCodeTab = false
        var triedShowSidebar = false
        let deadline = Date().addingTimeInterval(2.5)
        repeat {
            let root = appElement(app)
            if let sidebar = find(in: root, maxDepth: 22, where: { description($0) == "Sidebar" }) {
                if wantSidebar { return sidebar }
                if let match = find(in: sidebar, maxDepth: 14, where: predicate) { return match }
                if !triedCodeTab, let code = find(in: sidebar, maxDepth: 6, where: {
                    role($0) == kAXRadioButtonRole && description($0) == "Code"
                }) {
                    triedCodeTab = true
                    press(code)
                }
            } else if !triedShowSidebar, let show = find(in: root, maxDepth: 22, where: {
                role($0) == kAXButtonRole && description($0) == "Show sidebar"
            }) {
                triedShowSidebar = true
                press(show)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        } while Date() < deadline
        return nil
    }

    /// The composer of the primary pane (split view has one per pane).
    private static func promptField(_ app: NSRunningApplication) -> AXUIElement? {
        let root = appElement(app)
        let isPrompt: (AXUIElement) -> Bool = { role($0) == kAXTextAreaRole && description($0) == "Prompt" }
        if let pane = find(in: root, maxDepth: 22, where: { description($0) == "Primary pane" }) {
            return find(in: pane, maxDepth: 30, where: isPrompt)
        }
        return find(in: root, maxDepth: 50, where: isPrompt)
    }

    private static func appElement(_ app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetMessagingTimeout(element, 0.5)
        return element
    }

    private static func find(in element: AXUIElement, maxDepth: Int, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        if predicate(element) { return element }
        guard maxDepth > 0, !isChatTranscript(element) else { return nil }
        for child in children(element) {
            if let match = find(in: child, maxDepth: maxDepth - 1, where: predicate) { return match }
        }
        return nil
    }

    private static func findAll(in element: AXUIElement, maxDepth: Int, where predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
        var matches = predicate(element) ? [element] : []
        guard maxDepth > 0, !isChatTranscript(element) else { return matches }
        for child in children(element) {
            matches += findAll(in: child, maxDepth: maxDepth - 1, where: predicate)
        }
        return matches
    }

    /// The message list can hold thousands of nodes and never contains what we look for.
    private static func isChatTranscript(_ element: AXUIElement) -> Bool {
        description(element) == "Chat messages"
    }

    /// The first text inside a sidebar row: the session's own title.
    private static func rowName(_ row: AXUIElement) -> String? {
        find(in: row, maxDepth: 4, where: { role($0) == kAXStaticTextRole }).flatMap(value)
    }

    // MARK: - AX primitives

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func role(_ element: AXUIElement) -> String? { attribute(element, kAXRoleAttribute) as? String }
    private static func title(_ element: AXUIElement) -> String? { attribute(element, kAXTitleAttribute) as? String }
    private static func description(_ element: AXUIElement) -> String? { attribute(element, kAXDescriptionAttribute) as? String }
    private static func value(_ element: AXUIElement) -> String? { attribute(element, kAXValueAttribute) as? String }

    private static func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private static func focus(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
}
