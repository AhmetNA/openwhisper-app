import Foundation

/// Second stage for wake-word scores in the grey zone (between the candidate and the direct
/// threshold): Whisper transcribes the ~3.5 s around the candidate, the transcript must contain
/// a "Jarvis"-like word, and then the local LLM judges whether someone is calling the assistant
/// or the word came from a song, a video or talk about Jarvis. It checks the word only, never
/// who said it.
///
/// This file holds the pure word rules; Whisper and the LLM come in
/// `WakeWordVerifier+Audio.swift`.
enum WakeWordVerifier {
    /// Word shapes after `fold`: Whisper writes a Turkish "Jarvis" as Cervis, Carvis, Jarvıs,
    /// Çarvis, Jervis, Jarviz…; folding maps all of those to "jarvis".
    private static let target = "jarvis"

    /// Lowercases and merges the letters Whisper swaps for this word.
    static func fold(_ word: String) -> String {
        let lowered = word.lowercased(with: Locale(identifier: "tr_TR"))
        var out = ""
        for ch in lowered {
            switch ch {
            case "c", "ç", "j", "ş", "g": out.append("j")
            case "e", "a", "â": out.append("a")
            case "ı", "i", "î", "y": out.append("i")
            case "w", "b", "v": out.append("v")
            case "z", "s": out.append("s")
            default:
                if ch.isLetter { out.append(ch) }
            }
        }
        return out
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
            .map { String($0.split(whereSeparator: { $0 == "'" || $0 == "’" }).first ?? $0) }
            .filter { !$0.isEmpty }
    }

    /// Whether the transcript holds the wake word, also split in two ("Car vis") or carrying a
    /// Turkish suffix ("Jarvis'e", "Cervisim"), or a near miss right after "hey" (`isHeyNearMiss`).
    static func containsWakeWord(_ text: String) -> Bool {
        let folded = words(text).map(fold)
        var candidates = folded
        for i in folded.indices.dropLast() { candidates.append(folded[i] + folded[i + 1]) }
        if candidates.contains(where: isWakeWord) { return true }
        for i in folded.indices {
            if folded[i].hasPrefix("haj"), isHeyNearMiss(folded[i]) { return true }
            if heyForms.contains(folded[i]), i + 1 < folded.count, isHeyNearMiss(folded[i + 1]) { return true }
        }
        return false
    }

    private static func isWakeWord(_ word: String) -> Bool {
        // "Servis", "Harvey"… sit one edit away; a real call always starts with a j-like sound.
        guard word.count >= 5, word.first == "j" else { return false }
        if editDistance(word, target) <= 1 { return true }
        // Suffixed forms: compare the stem only.
        return word.count > target.count && editDistance(String(word.prefix(target.count)), target) <= 1
    }

    /// "Hey" + a j-word close to "jarvis". Whisper wrote the user's real calls as "Hey Jars",
    /// "Hey Jaws", "Hey Jairz", "Hey Jairus", and as one word "Hecaviz" (wake clips, 27 Sep
    /// 2026), and the strict one-edit rule threw those sessions away. Only after "hey": alone,
    /// "Canis" or "Jale" are ordinary words. Two edits, or three when the j…r…s skeleton is
    /// kept ("jairs", "jairus"; "Hey canım" is not). `word` is folded; "haj…" is the merged form.
    private static func isHeyNearMiss(_ word: String) -> Bool {
        var stem = Substring(word)
        if stem.hasPrefix("haj") { stem = stem.dropFirst(2) }
        guard stem.count >= 4, stem.count <= 7, stem.first == "j" else { return false }
        let distance = editDistance(String(stem), target)
        return distance <= 2 || distance == 3 && stem.hasPrefix("ja") && stem.contains("r") && stem.last == "s"
    }

    /// Folded "hey", "hay", "hei", "hi".
    private static let heyForms: Set<String> = ["hai", "hi"]

    /// Drops a leading "(hey) Jarvis" and the punctuation after it: "Hey Jarvis, şarkıyı durdur."
    /// → "Şarkıyı durdur." A suffixed form ("Jarvis'e …") is kept: that is talk about Jarvis.
    static func strippingLeadingWakeWord(_ text: String) -> String {
        func nextWord(_ s: Substring) -> (word: Substring, rest: Substring)? {
            let start = s.drop(while: { !$0.isLetter })
            guard !start.isEmpty else { return nil }
            let word = start.prefix(while: { $0.isLetter || $0 == "'" || $0 == "’" })
            return (word, start.dropFirst(word.count))
        }
        var rest = Substring(text)
        guard var next = nextWord(rest) else { return text }
        let hasHey = heyForms.contains(fold(String(next.word)))
        if hasHey {
            guard let after = nextWord(next.rest) else { return text }
            next = after
        }
        let word = String(next.word)
        let folded = fold(word)
        guard !word.contains("'"), !word.contains("’"),
              (isWakeWord(folded) && folded.count <= target.count + 1
               || isHeyNearMiss(folded) && (hasHey || folded.hasPrefix("haj")))
        else { return text }
        rest = next.rest.drop(while: { !$0.isLetter && !$0.isNumber })
        guard let first = rest.first else { return "" }
        return String(first).uppercased(with: Locale(identifier: "tr_TR")) + rest.dropFirst()
    }

    /// "Jarvis" alone or with a filler ("hey Jarvis", "Jarvis?") is plainly a call: no LLM needed.
    static func isBareCall(_ text: String) -> Bool {
        let folded = words(text).map(fold)
        let rest = folded.enumerated().filter { i, word in
            if editDistance(word, target) <= 1 || fillers.contains(word) || isHeyNearMiss(word) && word.hasPrefix("haj") {
                return false
            }
            return !(i > 0 && heyForms.contains(folded[i - 1]) && isHeyNearMiss(word))
        }
        return rest.isEmpty
    }

    /// Greetings count too: "Selam Jarvis", "Merhaba Jarvis", "Günaydın Jarvis" are calls.
    private static let fillers = Set(["hey", "hi", "hello", "ah", "eh", "ee", "hadi", "ok", "okay", "alo", "şey",
                                      "selam", "selamlar", "merhaba", "günaydın", "naber", "iyi", "akşamlar", "geceler"].map(fold))

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
