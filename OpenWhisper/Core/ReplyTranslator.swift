import Foundation

/// English replies for an English voice (Piper Jarvis). Jarvis's replies are written in Turkish
/// (`JarvisReply`, `SystemController`, reminders, Spotify); this turns them into English before
/// they are spoken: the acks through a fixed table (instant, cacheable), everything else through
/// the local Ollama model. Chat sentences the model already wrote in English pass unchanged.
enum ReplyTranslator {
    // MARK: - Fixed phrases

    /// English for every `JarvisReply.acks` / `fixedPhrases` entry (without the full stop).
    static let fixedBodies: [String: String] = [
        "Tamamdır": "Right away",
        "Hallettim": "Done",
        "Hemen": "At once",
        "Oldu": "All set",
        "Anlaşıldı": "Understood",
        "Tamam": "Very well",
        "Not ettim": "Noted",
        "Gönderdim": "Sent",
        "Yazdım": "Written",
    ]

    /// The ack or fixed phrase in English, with "patron"/"efendim" as "sir"; nil for any other
    /// text. "Tamamdır, patron." → "Right away, sir."
    static func fixedEnglish(_ text: String) -> String? {
        var body = text.trimmingCharacters(in: .whitespaces)
        while let last = body.last, ".!".contains(last) { body.removeLast() }
        var address = false
        for who in JarvisReply.addresses where body.hasSuffix(", \(who)") {
            body.removeLast(who.count + 2)
            address = true
        }
        guard let english = fixedBodies[body] else { return nil }
        return address ? "\(english), sir." : "\(english)."
    }

    // MARK: - Language of a sentence

    private static let turkishLetters = Set("çğıöşüÇĞİÖŞÜâîû")
    /// An apostrophe suffix on a name ("Spotify'da", "Ayşe'yle") is Turkish.
    private static let turkishSuffix = try! NSRegularExpression(
        pattern: #"\w['’](da|de|ta|te|dan|den|tan|ten|la|le|yla|yle|ya|ye|yı|yi|yu|yü|ı|i|u|ü|a|e|ın|in|un|ün|nın|nin|nun|nün|lar|ler)\b"#,
        options: .caseInsensitive)
    private static let englishWords: Set<String> = Set("""
        a an the is are was were be been am i i'm i've i'll i'd you you're your it it's this that these \
        those there here what which who when where why how to of in on at for from with about by and or \
        but not no yes do does did don't didn't can can't could would should shall will won't have has \
        had my me we our us he she they them sir please right away now today tomorrow tonight just all \
        some any one two three four five six seven eight nine ten let let's okay ok sorry thank thanks \
        again say said see know think want need playing music meeting meetings minute minutes hour hours \
        good morning evening night
        """.split(separator: " ").map(String.init))

    /// True only when the sentence is clearly English: no Turkish letters or suffixes and at
    /// least two common English words making up 30% of it. Anything unsure counts as Turkish
    /// and gets translated, which costs a little time but never reads Turkish in English.
    static func isClearlyEnglish(_ text: String) -> Bool {
        if text.contains(where: { turkishLetters.contains($0) }) { return false }
        let range = NSRange(text.startIndex..., in: text)
        if turkishSuffix.firstMatch(in: text, range: range) != nil { return false }
        let words = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
        let english = words.filter { englishWords.contains($0) }.count
        return !words.isEmpty && english >= 2 && Double(english) / Double(words.count) >= 0.3
    }

    // MARK: - Ollama

    static let prompt = """
        Translate this Turkish sentence, spoken by a butler-like voice assistant, into natural English. \
        Reply with the English sentence only. Keep names of people, apps, songs and artists as they are. \
        Translate 'patron' and 'efendim' as 'sir'; do not add 'sir' otherwise. Keep numbers and clock \
        times as digits; write a Turkish percentage like %87 as 87%.
        """

    /// Clock times in words, since espeak reads "2:05" as "two zero five": "2:05" → "two oh five",
    /// "14:30" → "fourteen thirty", "9:00" → "nine o'clock". Done here, not by the model, which
    /// turned "14:05" into "two past two".
    static func spokenTimes(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2}):(\d{2})\b"#) else { return text }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        func words(_ value: Int) -> String { formatter.string(from: NSNumber(value: value)) ?? "\(value)" }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let hour = Int(source.substring(with: match.range(at: 1))) ?? 0
            let minute = Int(source.substring(with: match.range(at: 2))) ?? 0
            let spoken = minute == 0 ? "\(words(hour)) o'clock"
                : minute < 10 ? "\(words(hour)) oh \(words(minute))" : "\(words(hour)) \(words(minute))"
            result += source.substring(with: NSRange(location: last, length: match.range.location - last)) + spoken
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }

    /// The English translation from the local model, or nil when Ollama is off, slow (> 8 s:
    /// a model that isn't loaded yet) or answers with something that isn't a translation.
    /// Honours task cancellation.
    static func translate(_ text: String, model: String) async -> String? {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "system", "content": prompt], ["role": "user", "content": text]],
            "stream": false,
            "think": false,
            "keep_alive": LLMCleanup.keepAlive,
            "options": ["temperature": 0, "num_predict": 120],
        ] as [String: Any])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["message"] as? [String: Any])?["content"] as? String
        else { return nil }
        return cleaned(content, source: text)
    }

    /// The model's answer without quotes or a lead-in; nil when it can't be the translation.
    static func cleaned(_ answer: String, source: String) -> String? {
        var line = answer.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        // "Here is the translation: …" / "English translation: …"
        if let colon = line.firstIndex(of: ":"), line[..<colon].lowercased().contains("translation") {
            line = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'` "))
        guard !line.isEmpty, line.count <= source.count * 3 + 20 else { return nil }
        return line
    }
}
