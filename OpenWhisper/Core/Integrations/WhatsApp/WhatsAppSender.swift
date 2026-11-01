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
    // "Dileğimi mesaj gönder": Whisper hears the dative as an accusative. Only before "mesaj".
    private static let misheardRecipient = #"(.+?)\s?['’]?(?:ya|ye|a|e|yi|yı|yu|yü|i|ı|u|ü)"#
    private static let message = #"(?:(?:bir |kısa (?:bir )?)?(?:whats ?app\S* )?mesaj\S*\s+)"#
    private static let verb = #"(?:yaz|gönder|at|yolla|ilet)"#

    /// Words that end in a dative but are no person: "buraya yaz", "bana yaz", "ona at".
    private static let notRecipients: Set<String> = [
        "bur", "bura", "şur", "şura", "or", "ora", "ban", "san", "on", "bun", "şun", "kendim", "kendin",
        "ben", "sen", "onlar", "bunlar", "şunlar",
        "claude", "cloud", "claude code", "cloud code", "codex", "chatgpt", "jarvis", "not", "notlar",
    ]

    static func parse(_ text: String) -> WhatsAppOutgoing? {
        if CommandLanguage.isEnglish { return parseEnglish(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased(with: locale)
        // Offsets found in the lowered text are cut from the original one.
        guard lowered.utf16.count == trimmed.utf16.count else { return nil }
        let withBody = #"\#(call)\#(recipient)\s+(?:whats ?app\S*\s+)?\#(message)?(?:şunu\s+|şöyle\s+)?\#(verb)(?:\s+ki|\s+diye)?[\s:,.!]+(.+)$"#
        let saidFirst = #"\#(call)(.+?),?\s+diye\s+\#(recipient)\s+\#(message)?\#(verb)[\s.!]*$"#
        let bodyless = #"\#(call)\#(misheardRecipient)\s+(?:whats ?app\S*\s+)?\#(message)\#(verb)[\s.!]*$"#

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

    // MARK: - English

    private static let englishCall = #"^\s*(?:hey\s+)?(?:jarvis[\s,.!]+)?(?:please\s+)?(?:(?:can|could|would) you\s+)?(?:please\s+)?"#
    private static let app = #"whats ?app"#
    private static let englishBodyLead = #"(?:\s+(?:saying|that says|that|and say|and tell (?:him|her|them)(?: that)?)|\s*[:,])\s+(.+)$"#

    /// "Send Ali a WhatsApp message saying I'm on my way", "WhatsApp Ali: running late",
    /// "send a WhatsApp to Ali", "tell Ali on WhatsApp that I'll call". WhatsApp must be named,
    /// so "message Ali" alone is never taken for it.
    private static func parseEnglish(_ text: String) -> WhatsAppOutgoing? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased(with: CommandLanguage.locale)
        guard lowered.utf16.count == trimmed.utf16.count, lowered.range(of: app, options: .regularExpression) != nil else { return nil }
        let name = #"([\p{L}'’ ]+?)"#
        let message = #"(?:a |an )?(?:\#(app) )?(?:message|text|msg)|(?:a )?\#(app)"#
        let onApp = #"(?:\s+(?:on|via|over|through|with) \#(app))?"#
        let withBody = [
            #"\#(englishCall)(?:send|write|text|message) \#(name) (?:\#(message))\#(onApp)\#(englishBodyLead)"#,
            #"\#(englishCall)(?:send|write) (?:\#(message)) to \#(name)\#(onApp)\#(englishBodyLead)"#,
            #"\#(englishCall)(?:\#(app)|message|text|tell) \#(name)\#(onApp)\#(englishBodyLead)"#,
        ]
        for pattern in withBody {
            if let groups = match(pattern, lowered), let who = englishRecipient(trimmed, groups[0]) {
                return outgoing(who, body: cut(trimmed, groups[1]))
            }
        }
        let bodyless = [
            #"\#(englishCall)(?:send|write) (?:\#(message)) to \#(name)\#(onApp)[\s.!]*$"#,
            #"\#(englishCall)(?:send|write|text|message) \#(name) (?:\#(message))\#(onApp)[\s.!]*$"#,
            #"\#(englishCall)(?:\#(app)|message|text) \#(name)\#(onApp)[\s.!]*$"#,
        ]
        for pattern in bodyless {
            if let groups = match(pattern, lowered), let who = englishRecipient(trimmed, groups[0]) {
                return WhatsAppOutgoing(recipient: who, body: "")
            }
        }
        return nil
    }

    private static func englishRecipient(_ text: String, _ range: NSRange) -> String? {
        let name = cut(text, range).trimmingCharacters(in: .whitespaces)
        let lowered = name.lowercased(with: CommandLanguage.locale)
        let notPeople: Set<String> = ["me", "myself", "it", "this", "that", "here", "there", "him", "her", "them", "claude", "codex", "jarvis"]
        guard !name.isEmpty, name.split(separator: " ").count <= 3, !notPeople.contains(lowered),
              lowered.range(of: app, options: .regularExpression) == nil else { return nil }
        return name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static func outgoing(_ name: String, body: String) -> WhatsAppOutgoing? {
        let body = cleanBody(body)
        guard !body.isEmpty else { return nil }
        return WhatsAppOutgoing(recipient: name, body: body)
    }

    /// The message as it is sent: no quotes around it, a capital first letter.
    static func cleanBody(_ text: String) -> String {
        let body = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”'")))
        return body.prefix(1).uppercased(with: CommandLanguage.isEnglish ? CommandLanguage.locale : locale) + body.dropFirst()
    }

    /// "Whatsapp'tan" misheard ("Datsattan") is left before the name: "Datsattan Dileyim".
    private static let misheardApp = #"^\S*[st]a[pbt]+\S*(?:tan|dan|ten|den)$"#

    private static func recipientName(_ text: String, _ range: NSRange) -> String? {
        var name = cut(text, range).trimmingCharacters(in: .whitespaces)
        let words = name.split(separator: " ")
        if words.count > 1, WhatsAppStore.fold(String(words[0])).range(of: misheardApp, options: .regularExpression) != nil {
            name = words.dropFirst().joined(separator: " ")
        }
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

/// Sends a WhatsApp message only after a spoken yes. The draft is resolved to one chat (a
/// request without a message first asks "ne yazayım?") and read back first; on "evet" the WhatsApp app itself opens the chat with the text in its
/// message field (`whatsapp://send`), Jarvis checks that the field holds exactly that text
/// and presses Return, then looks for the sent message in WhatsApp's database.
@MainActor
final class WhatsAppSender {
    struct Draft: Equatable {
        let chatName: String
        /// International number, digits only.
        let phone: String
        /// Empty while "ne yazayım?" waits for the message.
        var body: String
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
    /// "Dilayım'dan mesaj var, okuyayım mı?" waits for its answer (`WhatsAppWatcher`).
    private(set) var readOffer: (chatIDs: [Int64], expiresAt: Date)?
    var hasPending: Bool { pending != nil || readOffer != nil }
    /// "Ne yazayım?" waits: the whole next transcript is the message.
    var awaitsBody: Bool { pending?.body.isEmpty == true }
    private static let confirmationTimeout: TimeInterval = 45
    static let bundleIdentifier = "net.whatsapp.WhatsApp"

    /// Presses Return in the app with this pid, only while it is frontmost.
    private let pressReturn: (pid_t) -> Bool

    init(pressReturn: @escaping (pid_t) -> Bool) {
        self.pressReturn = pressReturn
    }

    func setPendingForTesting(_ draft: Draft) {
        pending = draft
    }

    func cancel() {
        if pending != nil { owLog("[WhatsApp] pending message dropped") }
        pending = nil
        readOffer = nil
    }

    /// Jarvis asked whether to read new messages; the next answer decides.
    func offerRead(_ chatIDs: [Int64]) {
        pending = nil
        readOffer = (chatIDs, Date().addingTimeInterval(Self.confirmationTimeout))
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
        if best?.isGroup == true { return .done(L("Gruplara henüz mesaj gönderemiyorum", "I can't send to groups yet")) }
        let name = best.map(WhatsAppController.spokenName) ?? contacts.first?.fullName
        guard let name, let phone = best.flatMap(Self.phone(of:)) ?? contacts.lazy.compactMap(Self.phone(of:)).first else {
            return .done(best == nil && contacts.isEmpty
                ? L("WhatsApp'ta \(outgoing.recipient) adında kimse bulunamadı", "No one named \(outgoing.recipient) found on WhatsApp")
                : L("\(outgoing.recipient) için telefon numarası bulunamadı", "No phone number found for \(outgoing.recipient)"))
        }
        let draft = Draft(chatName: name, phone: phone, body: outgoing.body, chatID: best?.id,
                          expiresAt: Date().addingTimeInterval(Self.confirmationTimeout))
        guard !outgoing.body.isEmpty else {
            pending = draft
            owLog("[WhatsApp] chat found, asking for the message")
            return .confirm(L("\(name) kişisine ne yazayım?", "What should I write to \(name)?"))
        }
        return readBack(draft)
    }

    private func readBack(_ draft: Draft) -> Prepared {
        pending = draft
        owLog("[WhatsApp] message to one chat awaiting confirmation (\(draft.body.count) chars)")
        let sentence = draft.body.last.map { ".!?".contains($0) } == true ? draft.body : draft.body + "."
        return .confirm(L("\(draft.chatName) kişisine: \(sentence) Göndereyim mi?", "To \(draft.chatName): \(sentence) Shall I send it?"))
    }

    /// The answer to the pending draft, or nil when `text` is no answer (a new message
    /// request, or nothing pending) and should be routed as usual.
    func handleConfirmation(_ text: String) async -> Prepared? {
        if let offer = readOffer {
            readOffer = nil
            guard offer.expiresAt > Date() else { return nil }
            switch Self.readDecision(text) {
            case .approve: return .done(await WhatsAppController.latest(inChats: offer.chatIDs))
            case .reject: return .done(L("Tamam", "Okay"))
            // Anything else is a new request ("Dilayım'a yaz: …"), routed as usual.
            case .unclear: return nil
            }
        }
        guard var draft = pending else { return nil }
        if WhatsAppSendParser.parse(text) != nil {
            pending = nil
            return nil
        }
        guard draft.expiresAt > Date() else {
            pending = nil
            return .done(draft.body.isEmpty ? L("Süre doldu, mesaj yazmadım", "Time ran out, I didn't write a message")
                : L("Onay süresi doldu, göndermedim", "The confirmation timed out, I didn't send it"))
        }
        // The answer to "ne yazayım?" is the message, unless it calls the message off.
        if draft.body.isEmpty {
            if Self.decision(text) == .reject {
                pending = nil
                return .done(L("Tamam, göndermedim", "Okay, I didn't send it"))
            }
            draft.body = WhatsAppSendParser.cleanBody(text)
            guard !draft.body.isEmpty else {
                pending = nil
                return nil
            }
            draft.expiresAt = Date().addingTimeInterval(Self.confirmationTimeout)
            return readBack(draft)
        }
        switch Self.decision(text) {
        case .approve:
            pending = nil
            return .done(await send(draft))
        case .reject:
            pending = nil
            return .done(L("Tamam, göndermedim", "Okay, I didn't send it"))
        case .unclear where !draft.retried:
            draft.retried = true
            pending = draft
            return .confirm(L("Anlayamadım. \(draft.chatName) kişisine gönderilsin mi? Evet ya da hayır de", "I didn't catch that. Send it to \(draft.chatName)? Say yes or no"))
        case .unclear:
            pending = nil
            return .done(L("Onay alamadım, göndermedim", "No confirmation, I didn't send it"))
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
        guard await openChat(phone: draft.phone, text: draft.body) else { return L("WhatsApp açılamadı", "Couldn't open WhatsApp") }
        guard let app = await waitForFrontWhatsApp() else { return L("WhatsApp öne gelmedi, göndermedim", "WhatsApp didn't come to the front, I didn't send it") }
        // The field must hold exactly the draft: an older draft in it would be sent along.
        switch await waitForField(pid: app.processIdentifier, text: draft.body) {
        case .matches:
            break
        case .differs:
            owLog("[WhatsApp] message field holds other text; Return not pressed")
            return L("WhatsApp'ta yazı alanında başka metin var, göndermedim. Kontrol edip kendin gönder", "There is other text in the WhatsApp field, I didn't send it. Check it and send it yourself")
        case .unreadable:
            owLog("[WhatsApp] message field unreadable; Return not pressed")
            return L("Mesajı WhatsApp'ta hazırladım ama alanı okuyamadım, göndermek için Return'e bas", "The message is ready in WhatsApp but I couldn't read the field, press Return to send it")
        }
        guard pressReturn(app.processIdentifier) else { return L("Mesaj hazır ama Return'e basamadım, kendin gönder", "The message is ready but I couldn't press Return, send it yourself") }
        guard let chatID = draft.chatID else { return L("Gönderdim", "Sent") }
        // WhatsApp writes the sent message to its database within a second or two.
        for _ in 0..<8 {
            try? await Task.sleep(for: .milliseconds(500))
            let sent = (try? await Task.detached(priority: .userInitiated) {
                try WhatsAppStore.messages(in: chatID, limit: 3)
            }.value)?.contains { $0.fromMe && $0.date >= startedAt.addingTimeInterval(-5) && Self.same($0.text, draft.body) }
            if sent == true {
                owLog("[WhatsApp] sent message found in the database")
                return L("Gönderdim", "Sent")
            }
        }
        owLog("[WhatsApp] Return pressed but the message is not in the database yet")
        return L("Return'e bastım ama gönderildiğini göremedim, WhatsApp'a bir bak", "I pressed Return but couldn't see it sent, take a look at WhatsApp")
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
        if CommandLanguage.isEnglish { return EnglishAnswers.decision(text).map { $0 ? .approve : .reject } ?? .unclear }
        let answer = normalizedAnswer(text)
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

    /// The answer to "okuyayım mı?".
    static func readDecision(_ text: String) -> Decision {
        if CommandLanguage.isEnglish { return EnglishAnswers.decision(text).map { $0 ? .approve : .reject } ?? .unclear }
        let answer = normalizedAnswer(text)
        let rejections: Set<String> = [
            "hayir", "okuma", "sonra", "sonra oku", "simdi degil", "gerek yok", "bosver", "bos ver", "istemiyorum",
            "yok", "kalsin", "dur", "sus", "sonra bakarim",
        ]
        if rejections.contains(answer) { return .reject }
        let approvals: Set<String> = [
            "evet", "oku", "evet oku", "okuyabilirsin", "evet okuyabilirsin", "oku bakalim", "tamam", "tamam oku",
            "olur", "evet olur", "tabii", "tabii oku", "aynen", "hadi oku", "ne yazmis", "ne demis", "ne yazdi",
        ]
        return approvals.contains(answer) ? .approve : .unclear
    }

    private static func normalizedAnswer(_ text: String) -> String {
        var answer = WhatsAppStore.fold(text)
            .replacingOccurrences(of: #"[^a-z0-9 ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if answer.hasPrefix("jarvis ") { answer.removeFirst("jarvis ".count) }
        for ending in [" efendim", " jarvis", " lutfen", " patron"] where answer.hasSuffix(ending) {
            answer.removeLast(ending.count)
        }
        return answer
    }
}
