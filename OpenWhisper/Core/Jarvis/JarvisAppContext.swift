import AppKit
import ApplicationServices
import Foundation
import SQLite3

/// What the frontmost app shows, for `JarvisContext`: its window title and selected text in any
/// app, and more for Safari, Mail, Claude and ChatGPT (Codex). Only the app in front is read,
/// and long texts (page, mail body, last reply) are cut to `excerptLimit`.
enum JarvisAppContext {
    static let excerptLimit = 600

    private static let claudeBundleID = "com.anthropic.claudefordesktop"
    private static let codexBundleID = "com.openai.codex"
    /// Field separator inside AppleScript replies: no page or mail text contains it.
    private static let separator: Character = "\u{1F}"

    /// Window title and selected text over Accessibility; nil when the app doesn't expose them.
    @MainActor
    static func windowAndSelection(_ app: NSRunningApplication) -> (window: String?, selection: String?) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Electron apps show their web content only with this set (see ClaudeSessionNavigator).
        if [claudeBundleID, codexBundleID].contains(app.bundleIdentifier) {
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        AXUIElementSetMessagingTimeout(root, 0.25)
        let window = element(root, kAXFocusedWindowAttribute).flatMap { string($0, kAXTitleAttribute) }
        let selection = element(root, kAXFocusedUIElementAttribute)
            .flatMap { string($0, kAXSelectedTextAttribute) }
            .flatMap { excerpt($0) }
        return (window?.isEmpty == false ? window : nil, selection)
    }

    /// Extra lines for the app in front; empty for apps without their own reader.
    @MainActor
    static func details(pid: pid_t, bundleID: String?, windowTitle: String?) async -> [String] {
        switch bundleID {
        case "com.apple.Safari": return await safari()
        case "com.apple.mail": return await mail()
        case claudeBundleID:
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let title = ClaudeSessionNavigator.currentSessionTitle(app) else { return [] }
            return await Task.detached { claude(sessionTitle: title) }.value
        case codexBundleID:
            guard let windowTitle else { return [] }
            return await Task.detached { codex(threadTitle: windowTitle) }.value
        default: return []
        }
    }

    // MARK: - Safari

    private static func safari() async -> [String] {
        let video = "(function(){var v=document.querySelector('video');if(!v||!v.duration)return '';"
            + "return (v.paused?'0':'1')+' '+Math.floor(v.currentTime)+' '+Math.floor(v.duration)})()"
        let script = """
            tell application "Safari"
                if (count of windows) is 0 then return ""
                set w to front window
                set t to current tab of w
                set sep to character id 31
                set v to ""
                try
                    set v to (do JavaScript "\(video)" in t) as text
                end try
                set pageText to ""
                try
                    set pageText to text of t
                end try
                return (name of t) & sep & (URL of t) & sep & ((count of tabs of w) as text) & sep & v & sep & pageText
            end tell
            """
        guard let reply = await JarvisContext.osascript(script) else { return [] }
        let fields = reply.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5 else { return [] }
        var lines = ["Safari sekmesi: \(fields[0]) — \(fields[1]) (\(fields[2]) sekme açık)"]
        let parts = fields[3].split(separator: " ").compactMap { Int($0) }
        if parts.count == 3 {
            lines.append("Safari'deki video: \(parts[0] == 1 ? "oynuyor" : "duraklatıldı"), "
                         + "\(VideoController.clock(parts[1])) / \(VideoController.clock(parts[2]))")
        }
        if let text = excerpt(fields[4...].joined(separator: String(separator))) { lines.append("Sayfadan: \(text)") }
        return lines
    }

    // MARK: - Mail

    private static func mail() async -> [String] {
        let script = """
            tell application "Mail"
                set sep to character id 31
                set out to (unread count of inbox) as text
                set sel to selection
                if (count of sel) > 0 then
                    set m to item 1 of sel
                    set out to out & sep & (sender of m) & sep & (subject of m) & sep & ((date received of m) as «class isot» as string) & sep & (content of m)
                else
                    set out to out & sep & sep & sep & sep
                end if
                set drafts to outgoing messages
                if (count of drafts) > 0 then
                    set o to item 1 of drafts
                    set rs to ""
                    repeat with r in (to recipients of o)
                        set rs to rs & (address of r) & " "
                    end repeat
                    set out to out & sep & (subject of o) & sep & rs & sep & (content of o)
                end if
                return out
            end tell
            """
        guard let reply = await JarvisContext.osascript(script) else { return [] }
        let fields = reply.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5 else { return [] }
        var lines: [String] = []
        if let unread = Int(fields[0]) { lines.append("Mail: \(unread) okunmamış") }
        if !fields[1].isEmpty {
            let parser = DateFormatter()
            parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            let printer = DateFormatter()
            printer.dateFormat = "dd.MM HH:mm"
            let date = parser.date(from: fields[3]).map { " (\(printer.string(from: $0)))" } ?? ""
            lines.append("Seçili mail: \(fields[1]) — \(fields[2])\(date)")
            if let body = excerpt(fields[4]) { lines.append("Mailden: \(body)") }
        }
        if fields.count >= 8 {
            lines.append("Yazılan mail: alıcı \(fields[6].trimmingCharacters(in: .whitespaces)), konu \(fields[5])")
            if let body = excerpt(fields[7...].joined(separator: String(separator))) { lines.append("Taslaktan: \(body)") }
        }
        return lines
    }

    // MARK: - Claude and Codex

    /// The Code tab session's project and Claude's last reply, from the app's session files.
    nonisolated private static func claude(sessionTitle: String) -> [String] {
        var newest: (millis: Double, json: [String: Any])?
        let files = FileManager.default.enumerator(at: ClaudeProjectStore.sessionsDirectory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["title"] as? String == sessionTitle, (json["isArchived"] as? Bool) != true else { continue }
            let millis = (json["lastActivityAt"] as? Double) ?? 0
            if millis >= newest?.millis ?? 0 { newest = (millis, json) }
        }
        guard let json = newest?.json else { return ["Claude Code oturumu: \(sessionTitle)"] }
        let folder = (json["originCwd"] as? String) ?? (json["cwd"] as? String) ?? ""
        var lines = ["Claude Code oturumu: \(sessionTitle)" + (folder.isEmpty ? "" : " (proje: \((folder as NSString).lastPathComponent))")]
        if let id = json["cliSessionId"] as? String, let url = claudeTranscript(id),
           let reply = tail(of: url).flatMap(ClaudeSessionRecap.lastAssistantText(inTranscript:)).flatMap({ excerpt($0) }) {
            lines.append("Claude'un son yanıtı: \(reply)")
        }
        return lines
    }

    nonisolated private static func claudeTranscript(_ id: String) -> URL? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent("\(id).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The Codex chat whose title the window shows: its project and the last answer.
    nonisolated private static func codex(threadTitle: String) -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(CodexProjectStore.databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { sqlite3_close(handle); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let quoted = threadTitle.replacingOccurrences(of: "'", with: "''")
        guard let row = CodexProjectStore.rows(db, """
            SELECT t.cwd, t.rollout_path, COALESCE(p.name, '') FROM threads t LEFT JOIN projects p ON p.id = t.project_id
            WHERE t.archived = 0 AND (t.name = '\(quoted)' OR t.title = '\(quoted)')
            ORDER BY t.recency_at_ms DESC LIMIT 1
            """).first, row.count == 3 else { return [] }
        let project = row[2].isEmpty ? (row[0] as NSString).lastPathComponent : row[2]
        var lines = ["ChatGPT (Codex) sohbeti: \(threadTitle)" + (project.isEmpty ? "" : " (proje: \(project))")]
        if let reply = tail(of: URL(fileURLWithPath: row[1])).flatMap(lastCodexAnswer(inRollout:)).flatMap({ excerpt($0) }) {
            lines.append("Codex'in son yanıtı: \(reply)")
        }
        return lines
    }

    /// The newest finished turn's answer in a Codex rollout (one JSON event per line).
    nonisolated static func lastCodexAnswer(inRollout text: String) -> String? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"task_complete\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = json["payload"] as? [String: Any], payload["type"] as? String == "task_complete",
                  let message = payload["last_agent_message"] as? String, !message.isEmpty else { continue }
            return message
        }
        return nil
    }

    // MARK: - Helpers

    /// `text` on one line, cut to `excerptLimit`; nil when nothing is left.
    static func excerpt(_ text: String) -> String? {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > excerptLimit ? String(flat.prefix(excerptLimit)) + "…" : flat
    }

    /// The last `bytes` of a file: transcripts grow to megabytes and only the end is needed.
    /// A line cut at the start fails to parse and is skipped by the readers.
    nonisolated private static func tail(of url: URL, bytes: UInt64 = 400_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
