import Foundation

/// What Jarvis says back after a voice command: short and butler-like. Questions ("saat kaç?")
/// get their answer; every action he takes on the computer gets a one-word ack; failures say
/// why. Plain dictation gets nothing. Nothing narrates what Spotify is doing, the ack is enough.
/// Now and then the user is addressed as "patron" / "efendim", never twice in a row.
struct JarvisReply {
    private var rng: any RandomNumberGenerator
    private var addressedLastTime = false
    /// So the same ack ("Tamamdır.") never comes twice in a row.
    private var lastAckIndex: Int?
    /// Share of replies that address the user.
    var addressChance: Double = 0.3

    init(rng: any RandomNumberGenerator = SystemRandomNumberGenerator()) {
        self.rng = rng
    }

    static let acks = ["Tamamdır.", "Hallettim.", "Hemen.", "Oldu.", "Anlaşıldı.", "Tamam."]
    static let addresses = ["patron", "efendim"]
    /// Replies that aren't in `acks` but repeat word for word, so they're worth pre-synthesizing.
    static let fixedPhrases = ["Not ettim.", "Gönderdim.", "Yazdım."]

    /// Endings of `SystemController` statuses that mean it didn't work: "değiştirilemedi",
    /// "çalıştırılamadı", "bulunamadı", "Bağlı kulaklık yok".
    private static let failureMarkers = ["emedi", "amadı", " yok"]

    // MARK: - Per route

    /// nil = stay silent (the Mac is going to sleep, sound is muted, …).
    mutating func system(_ command: SystemCommand, status: String) -> String? {
        switch command {
        case .mute(true), .sleep, .displaySleep, .lockScreen, .screenSaver:
            return nil
        case .time, .battery, .mailCount, .mailCheck, .mailLatest, .mailReadUnread, .mailOpen, .briefing:
            return answer(Self.speakable(Self.shortened(status, for: command)))
        case .calendarEvent:
            // Say the date and time back, so a wrong hour is caught right away.
            if Self.isFailure(status) { return failure(Self.speakable(status)) }
            return answer(Self.speakable(status.replacingOccurrences(of: "Takvime eklendi:", with: "Takvime ekledim:")))
        case .browser(let action):
            // A summary or a search query may contain "yok"; only the fixed statuses are failures.
            if BrowserController.failures.contains(status) { return failure(Self.speakable(status)) }
            if action == .summarize { return answer(Self.speakable(Self.shortened(status, for: command))) }
            return ack()
        case .switchToApp, .switchToAgent:
            // The switch itself is the answer; an ack would talk over a video or song the
            // next command of the chain starts.
            return Self.isFailure(status) ? failure(Self.speakable(status)) : nil
        case .video(let action):
            if VideoController.failures.contains(status) || status.hasPrefix("Tam ekran yalnızca") || status == "Tam ekran yapılamadı" { return failure(Self.speakable(status)) }
            switch action {
            case .remaining: return answer(Self.speakable(status))
            // Pausing or silencing it: a short ack. Anything that keeps it playing stays silent,
            // so Jarvis doesn't talk over the video (as with starting a song).
            case .pause, .mute(true): return ack()
            default: return nil
            }
        default:
            if Self.isFailure(status) { return failure(Self.speakable(status)) }
            // "Safari zaten kapalı": worth saying instead of a plain ack.
            if status.lowercased(with: Locale(identifier: "tr_TR")).contains("zaten") {
                return answer(Self.speakable(status))
            }
            return ack()
        }
    }

    /// Spotify: a short ack, never a description of what plays. The caller holds the music
    /// back until the ack is spoken, so it doesn't talk over it.
    mutating func spotify(handled: Bool) -> String? {
        handled ? ack() : nil
    }

    /// "Claude Code'a şunu yaz … gönder": the text went in, and was sent if asked.
    mutating func agent(sent: Bool) -> String {
        addressing(sent ? "Gönderdim." : "Yazdım.")
    }

    /// "Claude Code'da yeni session aç" with nothing to write.
    mutating func newAgentSession() -> String {
        addressing("Yeni session açtım.")
    }

    /// `when` is the reminder's time ("bugün 15:46"), nil when it couldn't be set. Saying the
    /// time back catches a misheard one right away.
    mutating func reminder(at when: String?) -> String? {
        guard let when else { return failure("hatırlatıcıyı kuramadım") }
        return answer("Not ettim, \(when) hatırlatırım")
    }

    /// A reminder came due: "Patron, hatırlatma: toplantı."
    mutating func reminderDue(_ task: String) -> String {
        "Patron, hatırlatma: \(Self.speakable(task))."
    }

    /// The status `TimerManager.perform` returned, as a sentence; a stop is a plain ack.
    mutating func timer(_ command: TimerCommandParser.Command, status: String) -> String {
        if case .stop = command { return ack() }
        return answer(Self.speakable(status))
    }

    /// "Patron, 20 dakika doldu." / "Patron, çay için süre doldu." / "Patron, alarm çalıyor."
    mutating func timerFired(label: String?, seconds: Int?) -> String {
        if let label { return "Patron, \(label) için süre doldu." }
        if let seconds { return "Patron, \(SpokenDuration.spoken(seconds)) doldu." }
        return "Patron, alarm çalıyor."
    }

    mutating func reminderDeletion(_ result: ReminderManager.DeletionResult) -> String {
        switch result {
        case .confirmationRequired(let matches):
            if matches.count == 1, let name = matches.first {
                return "\(name) hatırlatıcısını silmek üzereyim. Onaylıyor musunuz?"
            }
            let names = matches.prefix(3).joined(separator: ", ")
            return "\(matches.count) hatırlatıcıyı silmek üzereyim: \(names). Onaylıyor musunuz?"
        case .deleted(let count, let appleVerified):
            if appleVerified {
                return addressing(count == 1 ? "Hatırlatıcıyı sildim." : "\(count) hatırlatıcıyı sildim.")
            }
            return failure("yerel hatırlatıcıyı sildim fakat Apple Hatırlatıcılar kaydını doğrulayamadım")
        case .notFound:
            return failure("eşleşen bir hatırlatıcı bulamadım")
        case .ambiguous(let matches):
            let names = matches.prefix(3).joined(separator: ", ")
            return failure("birden fazla eşleşme buldum: \(names); hangisini sileceğinizi söyleyin")
        case .cancelled:
            return "İptal ettim. Hiçbir hatırlatıcı silinmedi."
        case .confirmationUnclear:
            return "Anlayamadım. Silmemi onaylıyor musunuz? Evet ya da hayır deyin."
        case .notConfirmed:
            return "Onay vermediğiniz için hiçbir hatırlatıcı silmedim."
        case .confirmationExpired:
            return "Onay süresi doldu. Hiçbir hatırlatıcı silmedim."
        case .failed:
            return failure("hatırlatıcıları kontrol edemedim")
        }
    }

    /// Several commands at once: answers and failures are all said, in order, but the acks
    /// fold into a single one ("Tamam. Tamam." would sound broken). nil when nothing is said.
    mutating func combined(_ replies: [String?]) -> String? {
        let said = replies.compactMap { $0 }
        let worded = said.filter { !Self.isAck($0) }
        if worded.isEmpty { return said.isEmpty ? nil : ack() }
        return worded.joined(separator: " ")
    }

    /// An ack from `ack()`, with or without the address.
    static func isAck(_ reply: String) -> Bool {
        var body = reply
        for who in addresses { body = body.replacingOccurrences(of: ", \(who).", with: ".") }
        return acks.contains(body)
    }

    // MARK: - Building blocks

    mutating func ack() -> String {
        var index = Int.random(in: 0..<Self.acks.count, using: &rng)
        if index == lastAckIndex { index = (index + 1 + Int.random(in: 0..<(Self.acks.count - 1), using: &rng)) % Self.acks.count }
        lastAckIndex = index
        return addressing(Self.acks[index])
    }

    // MARK: - Memory

    /// "Bunu hatırla …" / "hakkımda ne biliyorsun?" / "… unut". `facts` is what is stored
    /// after the command ran; `removed` how many facts a forget took away.
    mutating func memory(_ command: UserMemoryCommand, facts: [String], removed: Int = 0) -> String {
        switch command {
        case .remember(let fact) where fact.hasPrefix(UserMemory.namePrefix):
            return "Memnun oldum, \(fact.dropFirst(UserMemory.namePrefix.count))."
        case .remember:
            return addressing(choose(["Aklımda tutuyorum.", "Not ettim, unutmam.", "Hafızama ekledim."]))
        case .recall:
            guard !facts.isEmpty else { return addressing("Henüz bana kendinizle ilgili bir şey söylemediniz.") }
            let recent = facts.suffix(6).map { $0.hasSuffix(".") ? $0 : $0 + "." }
            return "Bildiklerim şunlar: " + recent.joined(separator: " ")
        case .forget:
            return removed > 0 ? addressing("Unuttum.") : addressing("Bununla ilgili bir şey hatırlamıyorum.")
        case .forgetLast:
            return removed > 0 ? addressing("Son söylediğinizi unuttum.") : addressing("Hafızamda bir şey yok zaten.")
        case .forgetAll:
            return addressing("Hafızamı temizledim.")
        }
    }

    // MARK: - Greetings

    enum Greeting: Equatable, Sendable {
        case hello, goodMorning, goodDay, goodEvening, goodNight, howAreYou
    }

    /// The whole utterance is a greeting ("Günaydın", "Selam Jarvis", "Nasılsın?"); anything
    /// longer ("günaydın, müziği aç") is left to the command routes.
    static func greeting(in text: String) -> Greeting? {
        let locale = Locale(identifier: "tr_TR")
        var words = text.lowercased(with: locale)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        let fillers: Set<String> = ["jarvis", "hey", "patron", "efendim", "ya", "canım", "dostum"]
        words.removeAll { fillers.contains($0) }
        switch words.joined(separator: " ") {
        case "günaydın", "günaydınlar": return .goodMorning
        case "merhaba", "selam", "selamlar", "selamün aleyküm", "selamun aleykum", "selamın aleyküm": return .hello
        case "iyi günler": return .goodDay
        case "iyi akşamlar": return .goodEvening
        case "iyi geceler": return .goodNight
        case "nasılsın", "naber", "ne haber", "nasıl gidiyor", "naber nasılsın", "selam nasılsın", "merhaba nasılsın", "günaydın nasılsın":
            return .howAreYou
        default: return nil
        }
    }

    /// A greeting answered by the clock: "günaydın" at 22:00 gets a gentle correction.
    mutating func greet(_ greeting: Greeting, hour: Int) -> String {
        let fitting: String
        switch hour {
        case 5..<12: fitting = "Günaydın"
        case 12..<18: fitting = "İyi günler"
        case 18..<23: fitting = "İyi akşamlar"
        default: fitting = "İyi geceler"
        }
        switch greeting {
        case .howAreYou:
            let line = choose(["Gayet iyiyim, sizin için buradayım.", "Her zamanki gibi tetikteyim.", "Sistemler sorunsuz çalışıyor, teşekkürler."])
            return addressing(line)
        case .goodNight:
            return hour >= 20 || hour < 5 ? addressing("İyi geceler, iyi dinlenin.") : addressing("Daha gün bitmedi ama iyi dinlenin.")
        case .goodMorning where !(5..<12).contains(hour):
            return hour < 5 ? addressing("Günaydın demek için biraz erken, yine de buradayım.")
                : addressing("Öğleni geçtik ama günaydın. \(fitting) demek daha doğru olur.")
        case .goodMorning, .hello, .goodDay, .goodEvening:
            let tail = choose(["Nasıl yardımcı olabilirim?", "Emrinizdeyim.", "Buradayım."])
            return "\(addressingGreeting(fitting)) \(tail)"
        }
    }

    private mutating func addressingGreeting(_ word: String) -> String {
        addressedLastTime = true
        return "\(word) \(Self.addresses[Int.random(in: 0..<Self.addresses.count, using: &rng)])."
    }

    private mutating func choose(_ options: [String]) -> String {
        options[Int.random(in: 0..<options.count, using: &rng)]
    }

    mutating func answer(_ text: String) -> String {
        addressing(text.hasSuffix(".") ? text : text + ".")
    }

    mutating func failure(_ reason: String) -> String {
        addressing("Maalesef, \(Self.lowercasedFirst(reason)).")
    }

    /// Appends ", patron" to the sentence at `addressChance`, never on two replies in a row.
    private mutating func addressing(_ sentence: String) -> String {
        let use = !addressedLastTime && Double.random(in: 0..<1, using: &rng) < addressChance
        addressedLastTime = use
        guard use else { return sentence }
        let who = Self.addresses[Int.random(in: 0..<Self.addresses.count, using: &rng)]
        var body = sentence
        while let last = body.last, ".!".contains(last) { body.removeLast() }
        return "\(body), \(who)."
    }

    // MARK: - Text shaping

    static func isFailure(_ status: String) -> Bool {
        let lower = status.lowercased(with: Locale(identifier: "tr_TR"))
        return failureMarkers.contains { lower.contains($0) }
    }

    /// Keeps spoken answers short: unread mail is the count plus the first sender, the
    /// briefing its headline without the "— ilk:" tail if it is long.
    static func shortened(_ status: String, for command: SystemCommand) -> String {
        switch command {
        case .mailReadUnread:
            let items = status.components(separatedBy: " · ")
            guard items.count > 1 else { return status }
            return "\(items.count) okunmamış mail, ilki \(items[0])"
        case .briefing:
            return status.count > 140 ? (status.components(separatedBy: " — ").first ?? status) : status
        case .browser(.summarize):
            // The whole summary is in the notification; three sentences are enough to hear.
            let sentences = status.components(separatedBy: ". ")
            return sentences.count > 3 ? sentences.prefix(3).joined(separator: ". ") + "." : status
        default:
            return status
        }
    }

    /// Flow-bar punctuation read aloud badly: "%80" → "yüzde 80", "—" / "·" → commas.
    static func speakable(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: #"%\s?(\d+)"#, with: "yüzde $1", options: .regularExpression)
            .replacingOccurrences(of: " — ", with: ", ")
            .replacingOccurrences(of: " · ", with: ", ")
            .replacingOccurrences(of: "—", with: ", ")
            .replacingOccurrences(of: "·", with: ", ")
        for mark in ["“", "”", "\""] { out = out.replacingOccurrences(of: mark, with: "") }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Keep names ("Wi-Fi", "Safari") as they are; only a plain Turkish word is lowered.
        let rest = text.dropFirst()
        let firstWord = text.prefix { !$0.isWhitespace }.dropFirst()
        if firstWord.contains(where: { $0.isUppercase || "-'’".contains($0) }) { return text }
        return String(first).lowercased(with: Locale(identifier: "tr_TR")) + rest
    }
}
