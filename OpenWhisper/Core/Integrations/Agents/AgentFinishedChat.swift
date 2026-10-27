import Foundation
import SQLite3

/// "Biten sohbete geç": the Claude Code session or Codex chat whose answer came in last, read
/// from the apps' own files. A chat still working on its answer never counts.
enum AgentFinishedChat {
    struct Chat: Equatable, Sendable {
        let agent: AgentApp
        let id: String
        let title: String
        let finishedAt: Date
        /// Codex rollout path, or Claude's CLI transcript id: where the last answer is read.
        var transcript: String? = nil
    }

    // MARK: - Pure

    /// A Claude session whose last turn ended after the user's last message. The app stamps
    /// `lastTurnEdgeAt` both when a turn starts (just before the message lands) and when it
    /// ends, so a finish is an edge clearly after the message.
    static func claudeChat(fromJSON data: Data) -> Chat? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["sessionId"] as? String, (json["isArchived"] as? Bool) != true,
              (json["completedTurns"] as? Int ?? 0) > 0,
              let edge = json["lastTurnEdgeAt"] as? Double else { return nil }
        if let asked = json["latestUserFrameAt"] as? Double, edge < asked + 1000 { return nil }
        return Chat(agent: .claudeCode, id: id, title: (json["title"] as? String) ?? "",
                    finishedAt: Date(timeIntervalSince1970: edge / 1000), transcript: json["cliSessionId"] as? String)
    }

    /// When a Codex rollout's last turn completed; nil while a turn runs.
    static func codexFinishedAt(inRollout text: String) -> Date? {
        for line in text.split(separator: "\n").reversed()
        where line.contains("\"task_complete\"") || line.contains("\"task_started\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = (json["payload"] as? [String: Any])?["type"] as? String,
                  type == "task_complete" || type == "task_started" else { continue }
            guard type == "task_complete", let stamp = json["timestamp"] as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: stamp)
        }
        return nil
    }

    /// The newest finish, never the chat already on screen.
    static func newest(_ chats: [Chat], excluding currentID: String?) -> Chat? {
        chats.filter { $0.id != currentID }.max { $0.finishedAt < $1.finishedAt }
    }

    // MARK: - Files

    static func load(_ agent: AgentApp) -> [Chat] {
        agent == .claudeCode ? claudeChats() : codexChats()
    }

    private static func claudeChats() -> [Chat] {
        guard let files = FileManager.default.enumerator(at: ClaudeProjectStore.sessionsDirectory,
                                                        includingPropertiesForKeys: nil) else { return [] }
        var chats: [Chat] = []
        for case let url as URL in files where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url), let chat = claudeChat(fromJSON: data) { chats.append(chat) }
        }
        return chats
    }

    /// The 20 most recent chats; only their rollouts' tails are read.
    private static func codexChats() -> [Chat] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(CodexProjectStore.databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db = handle else { sqlite3_close(handle); return [] }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)
        let rows = CodexProjectStore.rows(db, """
            SELECT id, COALESCE(NULLIF(name, ''), title), rollout_path FROM threads
            WHERE archived = 0 AND source NOT LIKE '{%' AND COALESCE(thread_source, '') IN ('user', '')
            ORDER BY recency_at_ms DESC LIMIT 20
            """)
        return rows.compactMap { row in
            guard row.count == 3, let tail = tail(of: row[2]), let finished = codexFinishedAt(inRollout: tail) else { return nil }
            return Chat(agent: .codex, id: row[0], title: row[1], finishedAt: finished, transcript: row[2])
        }
    }

    static func tail(of path: String, bytes: UInt64 = 64_000) -> String? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        try? file.seek(toOffset: size > bytes ? size - bytes : 0)
        return (try? file.readToEnd()).flatMap { String(decoding: $0, as: UTF8.self) }
    }
}
