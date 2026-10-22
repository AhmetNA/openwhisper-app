import AppKit
import Foundation

/// Apple Mail by AppleScript: unread counts, the newest mail, opening it. Everything stays on
/// the Mac. The first command asks for automation access to Mail.
enum MailController {
    struct Message: Equatable {
        let sender: String
        let subject: String
    }

    /// NSAppleScript is not thread-safe; one serial queue keeps Mail's replies (which can take
    /// seconds while it syncs) off the main thread.
    private static let queue = DispatchQueue(label: "com.openwhisper.mail", qos: .userInitiated)

    static func unreadCount() async -> Int? {
        guard let reply = await run("tell application \"Mail\" to get unread count of inbox") else { return nil }
        return Int(reply.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Newest unread messages first, at most `limit`.
    static func unreadMessages(limit: Int) async -> [Message]? {
        let script = """
            tell application "Mail"
                set found to (messages of inbox whose read status is false)
                set out to ""
                set n to 0
                repeat with m in found
                    set n to n + 1
                    if n > \(limit) then exit repeat
                    set out to out & (sender of m) & tab & (subject of m) & linefeed
                end repeat
                return out
            end tell
            """
        guard let reply = await run(script) else { return nil }
        return parse(reply)
    }

    /// The newest message in the inbox, read or not.
    static func newestMessage() async -> Message? {
        let script = """
            tell application "Mail"
                set m to message 1 of inbox
                return (sender of m) & tab & (subject of m)
            end tell
            """
        guard let reply = await run(script) else { return nil }
        return parse(reply).first
    }

    /// Opens the newest unread message in its own window; false when nothing is unread.
    static func openNewestUnread() async -> Bool {
        let script = """
            tell application "Mail"
                set found to (messages of inbox whose read status is false)
                if (count of found) is 0 then return "none"
                open item 1 of found
                activate
                return "opened"
            end tell
            """
        return await run(script)?.contains("opened") ?? false
    }

    struct FullMessage: Equatable {
        let sender: String
        let subject: String
        let body: String
    }

    /// The newest message in the inbox with its text (quoted earlier mail cut off).
    static func newestMessageWithBody() async -> FullMessage? {
        let script = """
            tell application "Mail"
                set m to message 1 of inbox
                return (sender of m) & tab & (subject of m) & tab & (content of m)
            end tell
            """
        guard let reply = await run(script) else { return nil }
        let fields = reply.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3 else { return nil }
        return FullMessage(sender: displayName(fields[0]), subject: fields[1], body: readableBody(fields[2]))
    }

    /// How many messages `messages(from:)` looks through, newest first.
    static let senderSearchDepth = 150

    /// Recent inbox messages whose sender matches `name`, newest first, with their read status.
    static func messages(from name: String) async -> [(message: Message, unread: Bool)]? {
        let script = """
            tell application "Mail"
                set total to count of messages of inbox
                if total is 0 then return ""
                set last_ to \(senderSearchDepth)
                if total < last_ then set last_ to total
                -- One Apple event per property instead of three per message.
                set senders to sender of messages 1 thru last_ of inbox
                set subjects to subject of messages 1 thru last_ of inbox
                set states to read status of messages 1 thru last_ of inbox
                set out to ""
                repeat with i from 1 to count of senders
                    set out to out & (item i of senders) & tab & (item i of subjects) & tab & (item i of states) & linefeed
                end repeat
                return out
            end tell
            """
        guard let reply = await run(script) else { return nil }
        return reply.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, senderMatches(fields[0], name: name) else { return nil }
            return (Message(sender: displayName(fields[0]), subject: fields[1]), fields[2] == "false")
        }
    }

    /// Opens a reply to the newest inbox message with `text` in it, in its own window. It is
    /// never sent from here: the user reads it and presses Send in Mail.
    static func openReplyDraft(_ text: String) async -> Message? {
        let body = text.isEmpty || text.last.map({ ".!?".contains($0) }) == true ? text : text + "."
        let script = """
            tell application "Mail"
                set m to message 1 of inbox
                set theSender to sender of m
                set theSubject to subject of m
                set theAddress to extract address from theSender
                set theName to extract name from theSender
                if theSubject starts with "Re:" then
                    set replySubject to theSubject
                else
                    set replySubject to "Re: " & theSubject
                end if
                set draft to make new outgoing message with properties {subject:replySubject, content:"\(escaped(body))", visible:true}
                tell draft to make new to recipient at end of to recipients with properties {name:theName, address:theAddress}
                activate
                return theSender & tab & theSubject
            end tell
            """
        guard let reply = await run(script) else { return nil }
        return parse(reply).first
    }

    /// True when every word of `name` begins a word of the sender ("Ahmet" ~ "Ahmet Yılmaz
    /// <ahmet@x.com>"), ignoring case and Turkish letters ("Ayse" ~ "Ayşe").
    static func senderMatches(_ sender: String, name: String) -> Bool {
        let words = { (text: String) in
            fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let senderWords = words(sender)
        let nameWords = words(name)
        guard !nameWords.isEmpty else { return false }
        return nameWords.allSatisfy { part in senderWords.contains { $0.hasPrefix(part) } }
    }

    /// Mail text for speaking: no quoted earlier mail, no signature dashes, single spaces.
    static func readableBody(_ content: String) -> String {
        var kept: [String] = []
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The quoted thread starts here ("On … wrote:", "… tarihinde … şunu yazdı:").
            if trimmed.hasPrefix(">") || trimmed == "--" || trimmed.hasPrefix("-----Original Message")
                || trimmed.range(of: #"(?:wrote|yazdı):$"#, options: .regularExpression) != nil { break }
            kept.append(trimmed)
        }
        return kept.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func fold(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR"))
    }

    /// A Swift string as the inside of an AppleScript string literal.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func checkForNewMail() async {
        _ = await run("tell application \"Mail\" to check for new mail")
        // Mail fetches in the background; give it a moment before counting.
        try? await Task.sleep(for: .seconds(3))
    }

    static func markAllRead() async -> Bool {
        await run("tell application \"Mail\" to set read status of (messages of inbox whose read status is false) to true") != nil
    }

    /// "Ada Lovelace <ada@example.com>" → "Ada Lovelace".
    static func displayName(_ sender: String) -> String {
        guard let bracket = sender.firstIndex(of: "<") else { return sender }
        let name = sender[..<bracket].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return name.isEmpty ? sender.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) : name
    }

    private static func parse(_ reply: String) -> [Message] {
        reply.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let sender = fields.first else { return nil }
            return Message(sender: displayName(String(sender)),
                           subject: fields.count > 1 ? String(fields[1]) : "")
        }
    }

    private static func run(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error {
                    owLog("[Mail] AppleScript failed: \(error)")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: result?.stringValue ?? "")
                }
            }
        }
    }
}
