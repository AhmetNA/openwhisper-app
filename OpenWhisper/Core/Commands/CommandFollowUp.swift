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
        /// Videos were just read out: "ikincisi", "aç", "başka".
        case youtubeList
    }

    /// The domain a command that ran sets for its follow-up; nil when "sonraki" means nothing.
    static func domain(of command: VoiceCommand) -> Domain? {
        switch command {
        case .spotify: .music
        case .system(.browser(.youtubeHome)), .system(.browser(.youtubeMore)),
             .system(.browser(.search(.youtube, _))): .youtubeList
        case .system(.video), .system(.browser(.youtubePick)), .system(.browser(.youtubeTitle)): .video
        default: nil
        }
    }

    private enum Action { case next, previous, pause, resume }

    /// The window opens while Jarvis is still answering, so the recording starts with his own
    /// reply ("Tamamdır. Sonrakine geç."). Drops those leading words; Whisper may cut them
    /// short ("Tamam"), so a shared start of four letters is enough.
    static func removingEcho(of reply: String?, from transcript: String) -> String {
        guard let reply else { return transcript }
        let replyWords = words(reply)
        var tokens = transcript.split(whereSeparator: \.isWhitespace).map(String.init)
        var dropped = 0
        while dropped < replyWords.count + 1, let first = tokens.first, let word = words(first).first,
              replyWords.contains(where: { $0 == word || ($0.count >= 4 && word.count >= 4 && $0.prefix(4) == word.prefix(4)) }) {
            tokens.removeFirst()
            dropped += 1
        }
        return tokens.joined(separator: " ")
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// A long sentence is something else ("sonra Ahmet'e geçen haftayı anlatırım"), not a fix.
    private static let maxWords = 5

    /// The command a bare answer means after a `domain` command, or nil when it is none.
    static func resolve(_ text: String, after domain: Domain) -> VoiceCommand? {
        if domain == .youtubeList {
            if let number = YouTubeList.pick(in: text, requireVerb: false) { return .system(.browser(.youtubePick(number))) }
            if YouTubeList.isBarePlay(text) { return .system(.browser(.youtubePick(1))) }
            if YouTubeList.isMore(text) { return .system(.browser(.youtubeMore)) }
            // "Orkun'un videosunu aç": by channel or title.
            if case .youtubeTitle(let title) = SystemCommandParser.parseBrowserRequest(text) {
                return .system(.browser(.youtubeTitle(title)))
            }
            return nil
        }
        guard let action = action(in: text) else { return nil }
        switch (domain, action) {
        case (.music, .next): return .spotify("sonraki şarkıya geç")
        case (.music, .previous): return .spotify("önceki şarkıya geç")
        case (.music, .pause): return .spotify("şarkıyı durdur")
        case (.music, .resume): return .spotify("şarkıya devam et")
        case (.video, .next): return .system(.video(.next))
        case (.video, .pause): return .system(.video(.pause))
        case (.video, .resume): return .system(.video(.play))
        case (.video, .previous), (.youtubeList, _): return nil
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
