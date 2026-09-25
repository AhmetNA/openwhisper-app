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
