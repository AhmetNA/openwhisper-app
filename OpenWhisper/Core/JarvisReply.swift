import Foundation

/// What Jarvis says back after a voice command: short and butler-like. Questions ("saat kaç?")
/// get their answer; every action he takes on the computer gets a one-word ack; failures say
/// why. Plain dictation gets nothing. Nothing narrates what Spotify is doing, the ack is enough.
/// Now and then the user is addressed as "patron" / "efendim", never twice in a row.
struct JarvisReply {
    private var rng: any RandomNumberGenerator
    private var addressedLastTime = false
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

    mutating func reminder(scheduled: Bool) -> String? {
        scheduled ? addressing("Not ettim.") : failure("hatırlatıcıyı kuramadım")
    }

    // MARK: - Building blocks

    mutating func ack() -> String {
        let pick = Self.acks[Int.random(in: 0..<Self.acks.count, using: &rng)]
        return addressing(pick)
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
