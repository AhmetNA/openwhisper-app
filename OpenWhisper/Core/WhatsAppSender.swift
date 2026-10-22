import AppKit
import Foundation

/// "Dilayım'a yaz: akşam geliyorum": who it goes to (as heard) and what it says. An empty
/// body only opens the chat.
struct WhatsAppOutgoing: Equatable, Sendable {
    let recipient: String
    let body: String
}

/// Pure parsing of a WhatsApp message request from the raw transcript, so the body keeps its
/// case and punctuation.
enum WhatsAppSendParser {
    private static let locale = Locale(identifier: "tr_TR")
    private static let call = #"^\s*(?:hey\s+)?(?:(?:jarvis|cervis|carvis|jarvıs|çarvis|jervis)[\s,.!]+)?(?:lütfen\s+)?(?:whats ?app\S*\s+)?"#
    // "Dilayım'a", "dilayıma", "Ali'ye", "anneme": the name and its dative ending.
    private static let recipient = #"(.+?)['’]?(?:ya|ye|a|e)"#
    private static let message = #"(?:(?:bir |kısa (?:bir )?)?(?:whats ?app\S* )?mesaj\S*\s+)"#
    private static let verb = #"(?:yaz|gönder|at|yolla|ilet)"#

    /// Words that end in a dative but are no person: "buraya yaz", "bana yaz", "ona at".
    private static let notRecipients: Set<String> = [
        "bur", "bura", "şur", "şura", "or", "ora", "ban", "san", "on", "bun", "şun", "kendim", "kendin",
        "claude", "cloud", "claude code", "cloud code", "codex", "chatgpt", "jarvis", "not", "notlar",
    ]

    static func parse(_ text: String) -> WhatsAppOutgoing? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased(with: locale)
        // Offsets found in the lowered text are cut from the original one.
        guard lowered.utf16.count == trimmed.utf16.count else { return nil }
        let withBody = #"\#(call)\#(recipient)\s+(?:whats ?app\S*\s+)?\#(message)?(?:şunu\s+|şöyle\s+)?\#(verb)(?:\s+ki|\s+diye)?[\s:,.!]+(.+)$"#
        let saidFirst = #"\#(call)(.+?),?\s+diye\s+\#(recipient)\s+\#(message)?\#(verb)[\s.!]*$"#
        let bodyless = #"\#(call)\#(recipient)\s+(?:whats ?app\S*\s+)?\#(message)\#(verb)[\s.!]*$"#

        if let groups = match(withBody, lowered), let name = recipientName(trimmed, groups[0]) {
            return outgoing(name, body: cut(trimmed, groups[1]))
        }
        if let groups = match(saidFirst, lowered), let name = recipientName(trimmed, groups[1]) {
            return outgoing(name, body: cut(trimmed, groups[0]))
        }
        if let groups = match(bodyless, lowered), let name = recipientName(trimmed, groups[0]) {
            return WhatsAppOutgoing(recipient: name, body: "")
        }
        return nil
    }

    private static func outgoing(_ name: String, body: String) -> WhatsAppOutgoing? {
        var body = body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
        guard !body.isEmpty else { return nil }
        body = body.prefix(1).uppercased(with: locale) + body.dropFirst()
        return WhatsAppOutgoing(recipient: name, body: body)
    }

    private static func recipientName(_ text: String, _ range: NSRange) -> String? {
        let name = cut(text, range).trimmingCharacters(in: .whitespaces)
        let lowered = name.lowercased(with: locale)
        guard !name.isEmpty, name.split(separator: " ").count <= 3, !notRecipients.contains(lowered) else { return nil }
        return name.split(separator: " ").map { $0.prefix(1).uppercased(with: locale) + $0.dropFirst() }.joined(separator: " ")
    }

    private static func match(_ pattern: String, _ text: String) -> [NSRange]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<found.numberOfRanges).map { found.range(at: $0) }
    }

    private static func cut(_ text: String, _ range: NSRange) -> String {
        Range(range, in: text).map { String(text[$0]) } ?? ""
    }
}

/// Sends a WhatsApp message only after a spoken yes. The draft is resolved to one chat and
/// read back first; on "evet" the WhatsApp app itself opens the chat with the text in its
/// message field (`whatsapp://send`), Jarvis checks that the field holds exactly that text
/// and presses Return, then looks for the sent message in WhatsApp's database.
@MainActor
final class WhatsAppSender {
    struct Draft: Equatable {
        let chatName: String
        /// International number, digits only.
        let phone: String
        let body: String
        let chatID: Int64?
        var expiresAt: Date
        var retried = false
    }

    enum Prepared: Equatable {
        /// Read the draft back and wait for "evet" / "hayır".
        case confirm(String)
        /// Nothing waits: a failure, or a chat opened without a message.
        case done(String)
    }

    private(set) var pending: Draft?
    var hasPending: Bool { pending != nil }
    private static let confirmationTimeout: TimeInterval = 45
    static let bundleIdentifier = "net.whatsapp.WhatsApp"

    /// Presses Return in the app with this pid, only while it is frontmost.
    private let pressReturn: (pid_t) -> Bool

    init(pressReturn: @escaping (pid_t) -> Bool) {
        self.pressReturn = pressReturn
    }

    func cancel() {
        if pending != nil { owLog("[WhatsApp] pending message dropped") }
        pending = nil
    }

    func prepare(_ outgoing: WhatsAppOutgoing) async -> Prepared {
        pending = nil
        let contacts = await WhatsAppController.matchingContacts(outgoing.recipient)
        let chats: [WhatsAppStore.Chat]
        do {
            chats = try await Task.detached(priority: .userInitiated) { try WhatsAppStore.chats() }.value
        } catch {
            return .done(await WhatsAppController.status(for: error))
        }
        let best = WhatsAppStore.bestChat(for: outgoing.recipient, in: chats, contacts: contacts)?.chat
        if best?.isGroup == true { return .done("Gruplara henüz mesaj gönderemiyorum") }
        let name = best.map(WhatsAppController.spokenName) ?? contacts.first?.fullName
        guard let name, let phone = best.flatMap(Self.phone(of:)) ?? contacts.lazy.compactMap(Self.phone(of:)).first else {
            return .done(best == nil && contacts.isEmpty
                ? "WhatsApp'ta \(outgoing.recipient) adında kimse bulunamadı"
                : "\(outgoing.recipient) için telefon numarası bulunamadı")
        }
        guard !outgoing.body.isEmpty else {
            return .done(await openChat(phone: phone) ? "\(name) sohbetini açtım" : "WhatsApp açılamadı")
        }
        pending = Draft(chatName: name, phone: phone, body: outgoing.body, chatID: best?.id,
                        expiresAt: Date().addingTimeInterval(Self.confirmationTimeout))
        owLog("[WhatsApp] message to one chat awaiting confirmation (\(outgoing.body.count) chars)")
        let sentence = outgoing.body.last.map { ".!?".contains($0) } == true ? outgoing.body : outgoing.body + "."
        return .confirm("\(name) kişisine: \(sentence) Göndereyim mi?")
    }

    /// The answer to the pending draft, or nil when `text` is no answer (a new message
    /// request, or nothing pending) and should be routed as usual.
    func handleConfirmation(_ text: String) async -> Prepared? {
        guard var draft = pending else { return nil }
        if WhatsAppSendParser.parse(text) != nil {
            pending = nil
            return nil
        }
        guard draft.expiresAt > Date() else {
            pending = nil
            return .done("Onay süresi doldu, göndermedim")
        }
        switch Self.decision(text) {
        case .approve:
            pending = nil
            return .done(await send(draft))
        case .reject:
            pending = nil
            return .done("Tamam, göndermedim")
        case .unclear where !draft.retried:
            draft.retried = true
            pending = draft
            return .confirm("Anlayamadım. \(draft.chatName) kişisine gönderilsin mi? Evet ya da hayır de")
        case .unclear:
            pending = nil
            return .done("Onay alamadım, göndermedim")
        }
    }

    // MARK: - Sending

    private func openChat(phone: String, text: String? = nil) async -> Bool {
        var components = URLComponents()
        components.scheme = "whatsapp"
        components.host = "send"
        components.queryItems = [URLQueryItem(name: "phone", value: phone)] + (text.map { [URLQueryItem(name: "text", value: $0)] } ?? [])
        guard let url = components.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    private func send(_ draft: Draft) async -> String {
        let startedAt = Date()
        guard await openChat(phone: draft.phone, text: draft.body) else { return "WhatsApp açılamadı" }
        guard let app = await waitForFrontWhatsApp() else { return "WhatsApp öne gelmedi, göndermedim" }
        // The field must hold exactly the draft: an older draft in it would be sent along.
        switch await waitForField(pid: app.processIdentifier, text: draft.body) {
        case .matches:
            break
        case .differs:
            owLog("[WhatsApp] message field holds other text; Return not pressed")
            return "WhatsApp'ta yazı alanında başka metin var, göndermedim. Kontrol edip kendin gönder"
        case .unreadable:
            owLog("[WhatsApp] message field unreadable; Return not pressed")
            return "Mesajı WhatsApp'ta hazırladım ama alanı okuyamadım, göndermek için Return'e bas"
        }
        guard pressReturn(app.processIdentifier) else { return "Mesaj hazır ama Return'e basamadım, kendin gönder" }
        guard let chatID = draft.chatID else { return "Gönderdim" }
        // WhatsApp writes the sent message to its database within a second or two.
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(500))
            let sent = (try? await Task.detached(priority: .userInitiated) {
                try WhatsAppStore.messages(in: chatID, limit: 3)
            }.value)?.contains { $0.fromMe && $0.date >= startedAt.addingTimeInterval(-5) && Self.same($0.text, draft.body) }
            if sent == true {
                owLog("[WhatsApp] sent message found in the database")
                return "Gönderdim"
            }
        }
        owLog("[WhatsApp] Return pressed but the message is not in the database yet")
        return "Return'e bastım ama gönderildiğini göremedim, WhatsApp'a bir bak"
    }

    private func waitForFrontWhatsApp() async -> NSRunningApplication? {
        for _ in 0..<25 {
            if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == Self.bundleIdentifier {
                return front
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        owLog("[WhatsApp] WhatsApp did not come to the front")
        return nil
    }

    private enum Field { case matches, differs, unreadable }

    /// The focused field of WhatsApp, read through Accessibility until it holds `text` (the
    /// app fills it a moment after the chat opens).
    private func waitForField(pid: pid_t, text: String) async -> Field {
        var last: String?
        for _ in 0..<15 {
            if let element = AXTextAccess.focusedElement(matchingPID: pid),
               let value = AXTextAccess.readString(element, kAXValueAttribute as CFString).value {
                if Self.same(value, text) { return .matches }
                last = value
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard let last else { return .unreadable }
        return last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .unreadable : .differs
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let clean = { (s: String) in
            s.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return clean(a) == clean(b)
    }

    /// The number of a one-to-one chat; nil for groups and hidden-number (`@lid`) chats.
    static func phone(of chat: WhatsAppStore.Chat) -> String? {
        guard chat.jid.hasSuffix("@s.whatsapp.net") else { return nil }
        let digits = String(chat.jid.prefix { $0 != "@" })
        return digits.count >= 8 ? digits : nil
    }

    /// A Contacts number in international form: "0532…" and "532…" are taken as Turkish.
    static func phone(of contact: WhatsAppStore.Contact) -> String? {
        for raw in contact.phones {
            var digits = raw
            if digits.hasPrefix("00") { digits.removeFirst(2) }
            if digits.count == 11, digits.hasPrefix("0") { digits = "9" + digits }
            else if digits.count == 10, digits.hasPrefix("5") { digits = "90" + digits }
            if digits.count >= 10 { return digits }
        }
        return nil
    }

    // MARK: - The answer

    enum Decision: Equatable { case approve, reject, unclear }

    /// Only a short, plain answer counts; anything else is asked once more.
    static func decision(_ text: String) -> Decision {
        var answer = WhatsAppStore.fold(text)
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if answer.hasPrefix("jarvis ") { answer.removeFirst("jarvis ".count) }
        for ending in [" efendim", " jarvis", " lutfen", " patron"] where answer.hasSuffix(ending) {
            answer.removeLast(ending.count)
        }
        let rejections: Set<String> = [
            "hayir", "hayir gonderme", "gonderme", "yollama", "iptal", "iptal et", "vazgec", "vazgectim",
            "dur", "bekle", "yok", "olmaz", "istemiyorum",
        ]
        if rejections.contains(answer) { return .reject }
        let approvals: Set<String> = [
            "evet", "evet gonder", "gonder", "gonderebilirsin", "evet gonderebilirsin", "yolla", "evet yolla",
            "at", "tamam", "tamam gonder", "olur", "evet olur", "onayla", "onayliyorum", "tabii", "evet tabii",
            "aynen", "aynen gonder", "devam et",
        ]
        return approvals.contains(answer) ? .approve : .unclear
    }
}
