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

    struct SentWithAttachments: Equatable {
        let id: Int
        let date: Date
        let recipients: String
        let subject: String
        /// Each name once: a reply carries the thread's images again.
        let attachments: [String]
    }

    /// How many sent messages whose headers name the person are looked at.
    static let sentSearchDepth = 40

    /// Sent messages with attachments to someone whose name or address matches `person`,
    /// newest first. Mail's headers have each word as written ("Işık", or "IŞIK") and the
    /// address folded ("isik@"), so every word in both forms is searched; the recipients are
    /// checked again here, since the headers also hold the sender.
    static func sentWithAttachments(to person: String) async -> [SentWithAttachments]? {
        let words = person.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let forms = Array(Set(words + words.map(fold))).map { "all headers contains \"\(escaped($0))\"" }
        guard !forms.isEmpty else { return [] }
        let script = """
            tell application "Mail"
                set found to (messages of sent mailbox whose \(forms.joined(separator: " or ")))
                set out to ""
                set n to 0
                set now to current date
                repeat with m in found
                    set n to n + 1
                    if n > \(sentSearchDepth) then exit repeat
                    -- One Apple event: walking the attachments one by one, Mail repeats some and skips others.
                    set atts to name of mail attachments of m
                    if (count of atts) > 0 then
                        set rs to ""
                        repeat with r in to recipients of m
                            set rn to name of r
                            if rn is missing value then set rn to ""
                            set rs to rs & rn & " <" & (address of r) & ">; "
                        end repeat
                        set an to ""
                        repeat with a in atts
                            set an to an & a & "|"
                        end repeat
                        set out to out & (id of m) & tab & ((date sent of m) - now) & tab & rs & tab & (subject of m) & tab & an & linefeed
                    end if
                end repeat
                return out
            end tell
            """
        guard let reply = await run(script) else { return nil }
        return parseSent(reply, person: person, now: Date())
    }

    static func parseSent(_ reply: String, person: String, now: Date) -> [SentWithAttachments] {
        reply.split(whereSeparator: \.isNewline).compactMap { line -> SentWithAttachments? in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, let id = Int(fields[0]), let offset = Double(fields[1]),
                  senderMatches(fields[2], name: person) else { return nil }
            var names: [String] = []
            for name in fields[4].split(separator: "|").map(String.init) where !names.contains(name) { names.append(name) }
            let recipients = fields[2].trimmingCharacters(in: CharacterSet(charactersIn: "; "))
            return SentWithAttachments(id: id, date: now.addingTimeInterval(offset), recipients: recipients,
                                       subject: fields[3], attachments: names)
        }
        .sorted { $0.date > $1.date }
    }

    struct ConversationMail: Equatable {
        let incoming: Bool
        /// The Message-ID header, for opening it with a `message:` URL.
        let messageID: String
        let date: Date
        /// The sender of an incoming mail, the recipients of a sent one.
        let counterpart: String
        let subject: String
        let body: String
    }

    /// The newest mail exchanged with `person`, both ways, at most `limit`. The inbox is searched
    /// by sender only: a header search there took almost two minutes on 18,000 mails. A word
    /// counts when the name contains it or the address starts with it, so "İrem" doesn't catch
    /// "…ryanairemail.com". Mail doesn't list the hits newest first, so the script picks.
    static func conversation(with person: String, limit: Int = 3) async -> [ConversationMail]? {
        let words = person.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        let list = { (items: [String]) in "{" + items.map { "\"\(escaped($0))\"" }.joined(separator: ", ") + "}" }
        let senderFilter = words.map { "sender contains \"\(escaped($0))\"" }.joined(separator: " or ")
        let headerFilter = words.map { "all headers contains \"\(escaped($0))\"" }.joined(separator: " or ")
        let script = """
            on matchesPerson(theName, theAddress, ws, fws)
                if theName is missing value then set theName to ""
                repeat with i from 1 to count of ws
                    if theName contains (item i of ws) then return true
                    if theAddress starts with (item i of fws) then return true
                end repeat
                return false
            end matchesPerson

            on newest(cands, k)
                set picked to {}
                repeat k times
                    set best to 0
                    set bestOffset to -1.0E+12
                    repeat with i from 1 to count of cands
                        set c to item i of cands
                        if (item 1 of c) > bestOffset and (item 3 of c) is false then
                            set best to i
                            set bestOffset to item 1 of c
                        end if
                    end repeat
                    if best is 0 then exit repeat
                    set item 3 of item best of cands to true
                    set end of picked to item best of cands
                end repeat
                return picked
            end newest

            on run
                set ws to \(list(words))
                set fws to \(list(words.map(fold)))
                tell application "Mail"
                    set rs to character id 30
                    set fs to character id 31
                    set now to current date
                    set out to ""
                    set cands to {}
                    set n to 0
                    -- Into a variable first: in the repeat line itself the search runs again every turn.
                    set found to (messages of inbox whose \(senderFilter))
                    repeat with m in found
                        set n to n + 1
                        if n > 80 then exit repeat
                        set s to sender of m
                        if my matchesPerson(extract name from s, extract address from s, ws, fws) then
                            set end of cands to {(date received of m) - now, contents of m, false, "in", s}
                        end if
                    end repeat
                    set n to 0
                    set found to (messages of sent mailbox whose \(headerFilter))
                    repeat with m in found
                        set n to n + 1
                        if n > 80 then exit repeat
                        set r to ""
                        set hit to false
                        repeat with x in to recipients of m
                            set xn to name of x
                            if xn is missing value then set xn to ""
                            if my matchesPerson(xn, address of x, ws, fws) then set hit to true
                            set r to r & xn & " <" & (address of x) & ">; "
                        end repeat
                        if hit then set end of cands to {(date sent of m) - now, contents of m, false, "out", r}
                    end repeat
                    repeat with c in my newest(cands, \(limit + 2))
                        set m to item 2 of c
                        set t to content of m
                        if length of t > 1500 then set t to text 1 thru 1500 of t
                        set out to out & (item 4 of c) & fs & (message id of m) & fs & (item 1 of c) & fs & (item 5 of c) & fs & (subject of m) & fs & t & rs
                    end repeat
                end tell
                return out
            end run
            """
        guard let reply = await run(script) else { return nil }
        return Array(parseConversation(reply, now: Date()).prefix(limit))
    }

    /// Newest first, each message once: a sent mail can be in two accounts' sent boxes.
    static func parseConversation(_ reply: String, now: Date) -> [ConversationMail] {
        var seen = Set<String>()
        return reply.split(separator: "\u{1E}").compactMap { record -> ConversationMail? in
            let fields = record.split(separator: "\u{1F}", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, let offset = Double(fields[2]), seen.insert(fields[1]).inserted else { return nil }
            return ConversationMail(incoming: fields[0] == "in", messageID: fields[1], date: now.addingTimeInterval(offset),
                                    counterpart: fields[3].trimmingCharacters(in: CharacterSet(charactersIn: "; ")),
                                    subject: fields[4], body: readableBody(fields[5]))
        }
        .sorted { $0.date > $1.date }
    }

    /// Opens the message in Mail by its Message-ID; a lookup by id in a big inbox took 4 s.
    @MainActor
    static func open(messageID: String) -> Bool {
        let encoded = "<\(messageID)>".addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._@"))) ?? ""
        guard let url = URL(string: "message:\(encoded)") else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Saves the attachment of a sent message to Downloads (under a new name if taken) and
    /// returns where; nil when Mail couldn't. Picked by `whose name is` in one Apple event:
    /// walking `mail attachments` item by item, Mail hands out a shuffled list with repeats
    /// and the one asked for can be missing.
    static func saveSentAttachment(messageID: Int, name: String) async -> URL? {
        let fileName = name.precomposedStringWithCanonicalMapping
        guard !fileName.isEmpty, !fileName.contains("/") else { return nil }
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var url = downloads.appendingPathComponent(fileName)
        var copy = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(copy)" : "\(base) \(copy).\(ext)")
            copy += 1
        }
        let script = """
            tell application "Mail"
                set m to first message of sent mailbox whose id is \(messageID)
                save (first mail attachment of m whose name is "\(escaped(fileName))") in (POSIX file "\(escaped(url.path))")
                return "saved"
            end tell
            """
        guard await run(script) == "saved", FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
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
