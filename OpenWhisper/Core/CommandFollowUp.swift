import Foundation

/// After a command Jarvis listens a moment longer without the wake word, so the user can
/// correct it: "müzik başlat" → (doesn't like the song) "sonrakine geç". Such an answer is
/// short and leaves out what it is about; the command just run supplies that. Pure, so it is
/// unit-tested.
enum CommandFollowUp {
    /// What the last command was about, so a bare "sonrakine geç" knows what to skip.
    enum Domain: String, Equatable, Sendable {
        case music
        case video
    }

    /// The domain a command that ran sets for its follow-up; nil when "sonraki" means nothing.
    static func domain(of command: VoiceCommand) -> Domain? {
        switch command {
        case .spotify: .music
        case .system(.video): .video
        default: nil
        }
    }

    private enum Action { case next, previous, pause, resume }

    /// A long sentence is something else ("sonra Ahmet'e geçen haftayı anlatırım"), not a fix.
    private static let maxWords = 5

    /// The command a bare answer means after a `domain` command, or nil when it is none.
    static func resolve(_ text: String, after domain: Domain) -> VoiceCommand? {
        guard let action = action(in: text) else { return nil }
        switch (domain, action) {
        case (.music, .next): return .spotify("sonraki şarkıya geç")
        case (.music, .previous): return .spotify("önceki şarkıya geç")
        case (.music, .pause): return .spotify("şarkıyı durdur")
        case (.music, .resume): return .spotify("şarkıya devam et")
        case (.video, .next): return .system(.video(.next))
        case (.video, .pause): return .system(.video(.pause))
        case (.video, .resume): return .system(.video(.play))
        case (.video, .previous): return nil
        }
    }

    /// Word stems a follow-up fix is made of; anything else makes it a sentence of its own.
    private static let vocabulary = [
        "önceki", "onceki", "sonraki", "diğer", "diger", "başka", "baska", "atla", "değiştir", "degistir",
        "beğenme", "begenme", "sevme", "geç", "gec", "olmadı", "olmadi", "durdur", "duraklat", "kapat",
        "sustur", "dur", "devam", "et", "oynat", "başlat", "baslat", "aç", "ac", "çal", "cal",
        "şarkı", "sarki", "parça", "parca", "müzi", "muzi", "video", "onu", "şey", "sey", "bunu", "ver",
    ]

    private static func action(in text: String) -> Action? {
        let words = text.lowercased(with: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .filter { !["jarvis", "hey", "lütfen", "bir", "bu", "bunu", "şunu", "hadi", "tamam", "ya", "o", "zaman"].contains($0) }
        guard !words.isEmpty, words.count <= maxWords else { return nil }
        func has(_ stems: [String]) -> Bool { words.contains { word in stems.contains { word.hasPrefix($0) } } }
        // Every word must belong to such a fix: "Safari'yi kapat" names its own target and
        // is a command of its own, not "stop the music".
        guard words.allSatisfy({ word in vocabulary.contains { word.hasPrefix($0) } }) else { return nil }

        // "Beğenmedim", "olmadı", "başkasını aç", "değiştir", "atla", "sonrakine geç".
        if has(["önceki", "onceki"]) { return .previous }
        if has(["sonraki", "diğer", "diger", "başka", "baska", "atla", "değiştir", "degistir", "beğenmedi", "begenmedi", "sevmedi"])
            || words == ["geç"] || words == ["gec"] || words == ["olmadı"] || words == ["geç", "geç"] {
            return .next
        }
        if has(["durdur", "duraklat", "kapat", "sustur"]) || words == ["dur"] { return .pause }
        if words.contains("devam") || words == ["oynat"] || words == ["başlat"] { return .resume }
        return nil
    }
}
