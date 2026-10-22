import Foundation
import SQLite3

/// WhatsApp Desktop's own chat database (`ChatStorage.sqlite`), opened read-only. Jarvis never
/// writes to it and never talks to WhatsApp's servers, so nothing here can get the account
/// flagged. The app's group container is protected: reading it needs Full Disk Access.
///
/// The tables are Core Data's (`ZWACHATSESSION`, `ZWAMESSAGE`, `ZWAGROUPMEMBER`); WhatsApp
/// changes them now and then, so every optional column is looked up before it is used.
enum WhatsAppStore {
    struct Chat: Equatable {
        let id: Int64
        /// The name WhatsApp shows: the contact's name from the phone, or the group's subject.
        let name: String
        /// "905321234567@s.whatsapp.net", "…@g.us" for a group, "…@lid" when hidden.
        let jid: String
        let unread: Int
        let isGroup: Bool
        let lastDate: Date?
        /// Archived chats don't count towards WhatsApp's own unread badge either.
        var isArchived = false
    }

    struct Message: Equatable {
        let text: String
        let fromMe: Bool
        /// Who wrote it in a group; nil in a one-to-one chat or when WhatsApp doesn't know.
        let sender: String?
        let date: Date
    }

    enum Failure: Error, Equatable {
        /// No WhatsApp data folder on this Mac.
        case notInstalled
        /// The folder is there but macOS keeps Jarvis out (no Full Disk Access).
        case noAccess
        case unreadable(String)
    }

    static let containerURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
    static var defaultURL: URL { containerURL.appendingPathComponent("ChatStorage.sqlite") }

    /// Every one-to-one and group chat, newest first. Status updates, broadcast lists and
    /// channels are left out.
    static func chats(at url: URL = defaultURL) throws -> [Chat] {
        let db = try Connection(url)
        let columns = db.columns(of: "ZWACHATSESSION")
        let unread = columns.contains("ZUNREADCOUNT") ? "IFNULL(ZUNREADCOUNT, 0)" : "0"
        let type = columns.contains("ZSESSIONTYPE") ? "IFNULL(ZSESSIONTYPE, 0)" : "0"
        let last = columns.contains("ZLASTMESSAGEDATE") ? "ZLASTMESSAGEDATE" : "NULL"
        let removed = columns.contains("ZREMOVED") ? "AND IFNULL(ZREMOVED, 0) = 0" : ""
        let archived = columns.contains("ZARCHIVED") ? "IFNULL(ZARCHIVED, 0)" : "0"
        let sql = """
            SELECT Z_PK, IFNULL(ZPARTNERNAME, ''), IFNULL(ZCONTACTJID, ''), \(unread), \(type), \(last), \(archived)
            FROM ZWACHATSESSION
            WHERE IFNULL(ZCONTACTJID, '') NOT LIKE '%@broadcast'
              AND IFNULL(ZCONTACTJID, '') NOT LIKE '%@newsletter' \(removed)
            ORDER BY \(last) DESC
            """
        return try db.rows(sql) { row in
            let jid = row.text(2)
            return Chat(id: row.int(0), name: row.text(1), jid: jid, unread: Int(row.int(3)),
                        isGroup: row.int(4) == 1 || jid.hasSuffix("@g.us"),
                        lastDate: row.isNull(5) ? nil : Date(timeIntervalSinceReferenceDate: row.double(5)),
                        isArchived: row.int(6) != 0)
        }
    }

    /// The newest `limit` readable messages of the chat, newest first. Group events ("X
    /// joined") are skipped; photos, voice notes and the like are named instead of read.
    static func messages(in chatID: Int64, limit: Int, at url: URL = defaultURL) throws -> [Message] {
        let db = try Connection(url)
        let columns = db.columns(of: "ZWAMESSAGE")
        let type = columns.contains("ZMESSAGETYPE") ? "IFNULL(m.ZMESSAGETYPE, 0)" : "0"
        let members = db.columns(of: "ZWAGROUPMEMBER")
        let joinsMember = columns.contains("ZGROUPMEMBER") && members.contains("ZCONTACTNAME")
        let sender = joinsMember
            ? (members.contains("ZFIRSTNAME") ? "COALESCE(NULLIF(g.ZCONTACTNAME, ''), g.ZFIRSTNAME)" : "g.ZCONTACTNAME")
            : "NULL"
        let join = joinsMember ? "LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER" : ""
        // Extra rows so skipped events still leave `limit` messages.
        let sql = """
            SELECT m.ZTEXT, IFNULL(m.ZISFROMME, 0), m.ZMESSAGEDATE, \(type), \(sender)
            FROM ZWAMESSAGE m \(join)
            WHERE m.ZCHATSESSION = \(chatID)
            ORDER BY m.ZMESSAGEDATE DESC
            LIMIT \(limit * 4)
            """
        let messages: [Message?] = try db.rows(sql) { row in
            let raw = row.isNull(0) ? "" : row.text(0).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text = readableText(raw, type: Int(row.int(3))) else { return nil }
            let name = row.isNull(4) ? "" : row.text(4)
            return Message(text: text, fromMe: row.int(1) != 0, sender: name.isEmpty ? nil : name,
                           date: Date(timeIntervalSinceReferenceDate: row.double(2)))
        }
        return Array(messages.compactMap { $0 }.prefix(limit))
    }

    /// A message that arrived, without its text: enough to say who wrote.
    struct Arrival: Equatable {
        let messageID: Int64
        let chatID: Int64
        let date: Date
        /// Text or media, not a group event or a call.
        let readable: Bool
    }

    /// The newest message row, to start watching from.
    static func newestMessageID(at url: URL = defaultURL) throws -> Int64 {
        try Connection(url).rows("SELECT IFNULL(MAX(Z_PK), 0) FROM ZWAMESSAGE") { $0.int(0) }.first ?? 0
    }

    /// Messages from others whose row is newer than `messageID`, oldest first.
    static func arrivals(after messageID: Int64, at url: URL = defaultURL) throws -> [Arrival] {
        let db = try Connection(url)
        let type = db.columns(of: "ZWAMESSAGE").contains("ZMESSAGETYPE") ? "IFNULL(ZMESSAGETYPE, 0)" : "0"
        let sql = """
            SELECT Z_PK, ZCHATSESSION, ZMESSAGEDATE, \(type), IFNULL(ZTEXT, '')
            FROM ZWAMESSAGE
            WHERE Z_PK > \(messageID) AND IFNULL(ZISFROMME, 0) = 0
            ORDER BY Z_PK LIMIT 200
            """
        return try db.rows(sql) { row in
            Arrival(messageID: row.int(0), chatID: row.int(1),
                    date: Date(timeIntervalSinceReferenceDate: row.double(2)),
                    readable: readableText(row.text(4).trimmingCharacters(in: .whitespacesAndNewlines), type: Int(row.int(3))) != nil)
        }
    }

    /// The kinds of the newest rows of a chat ("0<", "3>", "46<·": type, < theirs, > mine, · no
    /// text), without any message text, for the log when nothing readable was found.
    static func messageKinds(in chatID: Int64, limit: Int, at url: URL = defaultURL) throws -> String {
        let db = try Connection(url)
        let type = db.columns(of: "ZWAMESSAGE").contains("ZMESSAGETYPE") ? "IFNULL(ZMESSAGETYPE, 0)" : "0"
        let sql = """
            SELECT \(type), IFNULL(ZISFROMME, 0), ZTEXT IS NULL OR ZTEXT = ''
            FROM ZWAMESSAGE WHERE ZCHATSESSION = \(chatID) ORDER BY ZMESSAGEDATE DESC LIMIT \(limit)
            """
        return try db.rows(sql) { row in
            "\(row.int(0))\(row.int(1) != 0 ? ">" : "<")\(row.int(2) != 0 ? "·" : "")"
        }.joined(separator: " ")
    }

    /// The text to read for a message of `type`. Only plain text (0) and links (7) are read as
    /// they are: other types carry WhatsApp's own data in `ZTEXT` (a group's settings as JSON,
    /// event descriptions), so media are named and everything else is skipped.
    static func readableText(_ raw: String, type: Int) -> String? {
        if type == 0 || type == 7 {
            guard !raw.isEmpty, !(raw.hasPrefix("{") && raw.hasSuffix("}")) else { return nil }
            return raw
        }
        return mediaLabel(type)
    }

    /// What a media message was, by `ZMESSAGETYPE`; nil for group events and calls.
    static func mediaLabel(_ type: Int) -> String? {
        switch type {
        case 1: return "Fotoğraf"
        case 2: return "Video"
        case 3: return "Sesli mesaj"
        case 4: return "Kişi kartı"
        case 5: return "Konum"
        case 8: return "Belge"
        case 11: return "GIF"
        case 15: return "Çıkartma"
        default: return nil
        }
    }

    // MARK: - Matching a spoken name

    /// Someone from the Mac's Contacts whose name matched what was heard.
    struct Contact: Equatable {
        let fullName: String
        /// Digits only, with the country code when the card has one.
        let phones: [String]
    }

    /// The chat `name` means, and how many other chats it could also mean. A chat whose name
    /// is the whole spoken name wins over one that only shares a word with it, and a person
    /// over a group; among equals the one written in last. `contacts` are the Contacts cards
    /// that match the name, so a nickname or a number saved on the Mac finds the chat too.
    static func bestChat(for name: String, in chats: [Chat], contacts: [Contact] = []) -> (chat: Chat, others: Int)? {
        let spoken = words(name)
        guard !spoken.isEmpty else { return nil }
        let contactNames = Set(contacts.map { fold($0.fullName) })
        let contactPhones = contacts.flatMap(\.phones).map { String($0.suffix(10)) }.filter { $0.count >= 7 }

        var scored: [(chat: Chat, score: Int)] = []
        for chat in chats {
            let chatWords = words(chat.name)
            var score = 0
            // The whole name, word for word, a case ending allowed ("Aliy" ~ "Ali").
            if chatWords.count == spoken.count, zip(spoken, chatWords).allSatisfy({ $0 == $1 || withEnding($0, $1) }) { score = 4 }
            else if contactNames.contains(fold(chat.name)) { score = 3 }
            else if !chat.isGroup, let number = chat.jid.split(separator: "@").first,
                    contactPhones.contains(where: { number.hasSuffix($0) }) { score = 3 }
            else if spoken.allSatisfy({ word in chatWords.contains { matches(word, $0) } }) { score = 2 }
            guard score > 0 else { continue }
            scored.append((chat, score * 2 + (chat.isGroup ? 0 : 1)))
        }
        let ranked = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score
                : ($0.chat.lastDate ?? .distantPast) > ($1.chat.lastDate ?? .distantPast)
        }
        guard let best = ranked.first else { return nil }
        return (best.chat, ranked.count - 1)
    }

    /// Endings Whisper leaves on a name when it drops the apostrophe: "Aliden", "Metinin", "Ayşeye".
    private static let suffixes = ["nin", "nun", "den", "dan", "ten", "tan", "in", "un", "ye", "ya", "e", "a", "y"]

    /// A spoken word against a word of the chat name: a start of it ("Meh" ~ "Mehmet"), or the
    /// whole of it with a case ending ("Aliden" ~ "Ali").
    private static func matches(_ spoken: String, _ word: String) -> Bool {
        word.hasPrefix(spoken) || withEnding(spoken, word)
    }

    /// `spoken` is `word` with a case ending: "aliden" ~ "ali".
    private static func withEnding(_ spoken: String, _ word: String) -> Bool {
        guard spoken.hasPrefix(word), word.count >= 2 else { return false }
        return suffixes.contains(String(spoken.dropFirst(word.count)))
    }

    private static func words(_ text: String) -> [String] {
        fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Lowercase without Turkish letters or accents: "Ayşe" ~ "ayse", "IŞIK" ~ "isik".
    static func fold(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR"))
    }

    // MARK: - SQLite

    private final class Connection {
        private var handle: OpaquePointer?

        init(_ url: URL) throws {
            // Read-only without `immutable`, so the newest messages still in the WAL are seen.
            let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
            guard status == SQLITE_OK else {
                sqlite3_close(handle)
                handle = nil
                let folder = url.deletingLastPathComponent().path
                if !FileManager.default.fileExists(atPath: folder) { throw Failure.notInstalled }
                throw status == SQLITE_CANTOPEN || status == SQLITE_PERM || status == SQLITE_AUTH
                    ? Failure.noAccess : Failure.unreadable("open \(status)")
            }
            sqlite3_busy_timeout(handle, 2000)
        }

        deinit { sqlite3_close(handle) }

        func columns(of table: String) -> Set<String> {
            (try? rows("PRAGMA table_info(\(table))") { $0.text(1) }).map(Set.init) ?? []
        }

        func rows<T>(_ sql: String, _ read: (Row) -> T) throws -> [T] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(handle))
                // Without Full Disk Access the file may open but every read is refused.
                if message.contains("authorization denied") || message.contains("unable to open") {
                    throw Failure.noAccess
                }
                throw Failure.unreadable(message)
            }
            defer { sqlite3_finalize(statement) }
            var result: [T] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    if step == SQLITE_CANTOPEN || step == SQLITE_AUTH || step == SQLITE_PERM { throw Failure.noAccess }
                    throw Failure.unreadable(String(cString: sqlite3_errmsg(handle)))
                }
                result.append(read(Row(statement: statement)))
            }
            return result
        }
    }

    private struct Row {
        let statement: OpaquePointer?
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(statement, i) == SQLITE_NULL }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
        func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
    }
}
