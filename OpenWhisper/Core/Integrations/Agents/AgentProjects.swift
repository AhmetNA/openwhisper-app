import Foundation
import SQLite3

/// A project folder an agent app has worked in, and its newest conversation there.
struct AgentProject: Equatable, Sendable {
    /// What the app calls it (Codex project name), or the folder's name.
    let name: String
    let folder: String
    var latestSession: AgentProjectSession?

    /// A Codex project can be renamed: it also answers to its folder's name.
    var spokenNames: [String] { [name, (folder as NSString).lastPathComponent] }
}

struct AgentProjectSession: Equatable, Sendable {
    let id: String
    let title: String
    let lastActivity: Date
}

enum AgentProjectMatch: Equatable, Sendable {
    case found(AgentProject)
    /// Several projects fit the spoken name about equally well; their names.
    case ambiguous([String])
    case none
}

/// Matches a spoken project name ("voice to text local", "bitirme", "Open Visper") against
/// the projects an app knows. Pure, so it is unit-tested.
enum AgentProjectMatcher {
    private static let locale = Locale(identifier: "tr_TR")
    private static let threshold = 0.75

    static func match(_ spoken: String, in projects: [AgentProject]) -> AgentProjectMatch {
        let spokenKey = key(spoken)
        guard !spokenKey.isEmpty else { return .none }
        let scored = projects.map { project in
            (project, project.spokenNames.map { similarity(spokenKey, key($0)) }.max() ?? 0)
        }
        .filter { $0.1 >= threshold }
        .sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return .none }
        let close = scored.filter { $0.1 >= best.1 - 0.05 }
        // Same name in two folders (a moved or copied project): the one used last.
        let names = Set(close.map { key($0.0.name) })
        if names.count > 1 {
            var seen = Set<String>()
            return .ambiguous(close.map(\.0.name).filter { seen.insert(key($0)).inserted })
        }
        let newest = close.max {
            ($0.0.latestSession?.lastActivity ?? .distantPast) < ($1.0.latestSession?.lastActivity ?? .distantPast)
        }
        return .found(newest?.0 ?? best.0)
    }

    /// "Voice to Text Local" → "voice2textlocal", "Çift Dört x Bir" → "cift4x1".
    static func key(_ name: String) -> String {
        let folded = name.lowercased(with: locale)
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: locale)
        let numbers: [String: String] = [
            "to": "2", "tu": "2", "two": "2", "for": "4", "four": "4", "one": "1",
            "sıfır": "0", "sifir": "0", "bir": "1", "iki": "2", "uc": "3", "dort": "4", "bes": "5",
            "alti": "6", "yedi": "7", "sekiz": "8", "dokuz": "9", "iks": "x", "eks": "x",
        ]
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.map { numbers[$0] ?? $0 }.joined()
    }

    /// 1 for the same key, 0.9 when one contains the other, else edit-distance based.
    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let shorter = a.count < b.count ? a : b
        let longer = a.count < b.count ? b : a
        if shorter.count >= 4, longer.contains(shorter) { return 0.9 }
        return 1 - Double(editDistance(Array(a), Array(b))) / Double(longer.count)
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (ca == cb ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Projects of the Claude desktop app's Code tab: every session keeps its folder and title
/// in a JSON file, so the newest session of a folder is that project's session.
enum ClaudeProjectStore {
    static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    static func load() -> [AgentProject] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sessionsDirectory, includingPropertiesForKeys: nil) else { return [] }
        var seen = Set<String>()
        var latest: [String: AgentProjectSession] = [:]
        for case let url as URL in enumerator {
            let file = url.lastPathComponent
            guard file.hasPrefix("local_"), file.hasSuffix(".json"),
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["sessionId"] as? String, seen.insert(id).inserted,
                  (json["isArchived"] as? Bool) != true,
                  // A worktree session works on its repository: originCwd is the repo folder.
                  let folder = (json["originCwd"] as? String) ?? (json["cwd"] as? String), !folder.isEmpty
            else { continue }
            let millis = (json["lastActivityAt"] as? Double) ?? (json["createdAt"] as? Double) ?? 0
            let session = AgentProjectSession(id: id, title: (json["title"] as? String) ?? "", lastActivity: Date(timeIntervalSince1970: millis / 1000))
            if session.lastActivity > latest[folder]?.lastActivity ?? .distantPast { latest[folder] = session }
        }
        return latest.map { folder, session in
            AgentProject(name: (folder as NSString).lastPathComponent, folder: folder, latestSession: session)
        }
    }
}

/// Projects of the Codex (ChatGPT) app, read from its state database. Threads are tied to a
/// project only through their folder, and a project's folder may have moved since, so a
/// thread also counts when its folder has the project's folder name.
enum CodexProjectStore {
    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/state_5.sqlite")
    }

    static func load() -> [AgentProject] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            owLog("[Agent] Codex: could not open \(databaseURL.path)")
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        let roots = rows(db, "SELECT p.name, r.path FROM projects p JOIN project_roots r ON r.project_id = p.id AND r.position = 0")
        // The user's own threads only: guardian reviews and subagents also live in this table.
        let threads = rows(db, """
            SELECT id, COALESCE(NULLIF(name, ''), title), cwd, COALESCE(recency_at_ms, updated_at_ms, updated_at * 1000)
            FROM threads
            WHERE archived = 0 AND source NOT LIKE '{%' AND COALESCE(thread_source, '') IN ('user', '')
            ORDER BY 4 DESC LIMIT 2000
            """)
        let sessions: [(folder: String, session: AgentProjectSession)] = threads.compactMap { row in
            guard row.count == 4, let millis = Double(row[3]) else { return nil }
            return (row[2], AgentProjectSession(id: row[0], title: row[1], lastActivity: Date(timeIntervalSince1970: millis / 1000)))
        }

        var projects: [AgentProject] = []
        var claimed = Set<String>()
        for root in roots where root.count == 2 {
            let (name, folder) = (root[0], root[1])
            let base = (folder as NSString).lastPathComponent
            let own = sessions.filter {
                $0.folder == folder || $0.folder.hasPrefix(folder + "/") || ($0.folder as NSString).lastPathComponent == base
            }
            own.forEach { claimed.insert($0.folder) }
            // A moved project: new chats go where its latest chat works, not the stale root.
            var current = folder
            if let newest = own.first?.folder, newest != folder, !newest.hasPrefix(folder + "/"),
               FileManager.default.fileExists(atPath: newest) {
                current = newest
            }
            projects.append(AgentProject(name: name, folder: current, latestSession: own.first?.session))
        }
        // Folders Codex worked in without a project entry still answer to their name.
        var loose: [String: AgentProjectSession] = [:]
        for (folder, session) in sessions where !claimed.contains(folder) && loose[folder] == nil {
            loose[folder] = session
        }
        for (folder, session) in loose {
            projects.append(AgentProject(name: (folder as NSString).lastPathComponent, folder: folder, latestSession: session))
        }
        return projects
    }

    private static func rows(_ db: OpaquePointer, _ sql: String) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            owLog("[Agent] Codex: query failed: \(String(cString: sqlite3_errmsg(db)))")
            return []
        }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return result
    }
}
