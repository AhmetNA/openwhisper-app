import Foundation

/// Spoken edits to the dictation OpenWhisper just pasted: "geri al", "son kelimeyi sil",
/// "Ahmed'i Ahmet yap", "enter'a bas". Only the text the app itself pasted is changed, never
/// what the user typed; `AppState.runDictationEdit` also checks that the caret still sits
/// right after it. "Sil" and "alanı temizle" are the exception: they empty the whole field.
enum DictationEdit: Equatable, Sendable {
    /// "geri al", "son yazdığımı sil": the whole last dictation.
    case deleteAll
    /// "sil", "hepsini sil", "alanı temizle": everything in the focused text field.
    case clearField
    case deleteLastWord
    case deleteLastSentence
    /// Every occurrence of `old` (as written in the dictation) becomes `new`.
    case replace(old: String, new: String)
    case pressReturn

    private static let locale = Locale(identifier: "tr_TR")

    private static let deleteAllPhrases: Set<String> = [
        "yazdığımı sil", "son yazdığımı sil", "yazdığını sil", "son yazdığını sil",
        "geri al", "bunu geri al", "onu geri al",
    ]
    private static let clearFieldPhrases: Set<String> = [
        "sil", "bunu sil", "onu sil", "şunu sil", "sil bunu", "sil onu", "sil hepsini",
        "hepsini sil", "tümünü sil", "tüm hepsini sil", "hepsini birden sil", "tamamını sil",
        "her şeyi sil", "yazıyı sil", "yazıları sil", "metni sil", "alanı sil", "kutuyu sil",
        "temizle", "hepsini temizle", "tümünü temizle", "her şeyi temizle", "alanı temizle",
        "metni temizle", "yazıyı temizle", "kutuyu temizle", "imleci temizle", "metin kutusunu temizle",
    ]
    private static let deleteLastWordPhrases: Set<String> = [
        "son kelimeyi sil", "son sözcüğü sil", "en son kelimeyi sil",
    ]
    private static let deleteLastSentencePhrases: Set<String> = [
        "son cümleyi sil", "en son cümleyi sil",
    ]
    private static let returnPhrases: Set<String> = [
        "enter", "enter'a bas", "entera bas", "enter'e bas", "entere bas", "enter bas",
        "enter tuşuna bas", "entır'a bas", "entıra bas",
    ]

    /// "Enter'a bas" needs no dictation before it.
    static func isReturn(_ text: String) -> Bool {
        returnPhrases.contains(folded(text))
    }

    /// "Sil", "alanı temizle" need no dictation before it either.
    static func isClearField(_ text: String) -> Bool {
        clearFieldPhrases.contains(folded(text))
    }

    /// The edit `text` asks for on `dictation`, the text just pasted. A replacement only counts
    /// when its old words are really in the dictation; otherwise "raporu hazır yap" is plain
    /// dictation.
    static func parse(_ text: String, dictation: String) -> DictationEdit? {
        let phrase = folded(text)
        if returnPhrases.contains(phrase) { return .pressReturn }
        if clearFieldPhrases.contains(phrase) { return .clearField }
        if deleteAllPhrases.contains(phrase) { return .deleteAll }
        if deleteLastWordPhrases.contains(phrase) { return .deleteLastWord }
        if deleteLastSentencePhrases.contains(phrase) { return .deleteLastSentence }
        return replacement(in: text, dictation: dictation)
    }

    /// The dictation after the edit; nil when nothing would change.
    func applied(to dictation: String) -> String? {
        let result: String
        switch self {
        case .deleteAll:
            result = ""
        case .deleteLastWord:
            result = dictation.replacingOccurrences(of: #"\s*\S+\s*$"#, with: "", options: .regularExpression)
        case .deleteLastSentence:
            // Keeps everything up to the end of the sentence before the last one.
            let body = dictation.replacingOccurrences(of: #"[\s.!?…]+$"#, with: "", options: .regularExpression)
            if let end = body.lastIndex(where: { ".!?…".contains($0) }) {
                result = String(body[...end])
            } else {
                result = ""
            }
        case .replace(let old, let new):
            result = Self.replacing(old, with: new, in: dictation) ?? dictation
        case .pressReturn, .clearField:
            return nil
        }
        return result == dictation ? nil : result
    }

    // MARK: - Replacement

    /// Pronouns that end "bunu daha iyi yap" or "şunu kırmızı yap": never the words to replace.
    private static let notReplaceable: Set<String> = [
        "bu", "bun", "şu", "şun", "o", "on", "bunu", "şunu", "onu", "hepsi", "hepsini", "bunları", "onları", "şunları",
    ]

    /// "X'i Y yap", "X'i Y olarak düzelt", "X'i Y ile değiştir", "X yerine Y yaz".
    private static func replacement(in text: String, dictation: String) -> DictationEdit? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?")))
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "’", with: "'")
        let words = cleaned.split(separator: " ").map(String.init)
        guard words.count >= 3, words.count <= 10 else { return nil }
        let lower = words.map { $0.lowercased(with: locale) }

        // "X yerine Y yaz / yap / koy / olsun".
        if let pivot = lower.firstIndex(of: "yerine"), pivot > 0,
           let last = lower.last, ["yaz", "yap", "koy", "olsun"].contains(last), pivot < words.count - 2 {
            let old = words[..<pivot].joined(separator: " ")
            let new = words[(pivot + 1)..<(words.count - 1)].joined(separator: " ")
            guard !notReplaceable.contains(old.lowercased(with: locale)),
                  let found = occurrence(of: old, in: dictation) else { return nil }
            return .replace(old: found, new: matchingCase(new, of: found))
        }

        // "X'i Y yap" and the longer verbs, the old words in the accusative.
        let verbs: [[String]] = [
            ["olarak", "düzelt"], ["olarak", "değiştir"], ["olarak", "yaz"], ["olarak", "yap"],
            ["diye", "düzelt"], ["diye", "değiştir"], ["diye", "yaz"], ["ile", "değiştir"], ["yap"],
        ]
        guard let verb = verbs.first(where: { lower.count > $0.count + 1 && Array(lower.suffix($0.count)) == $0 }) else {
            return nil
        }
        let rest = Array(words.dropLast(verb.count))
        // Every split: "Ahmet Yılmaz'ı Mehmet Yılmaz yap" has two words on each side.
        for split in 1..<rest.count {
            let left = rest[..<split].joined(separator: " ")
            let right = rest[split...].joined(separator: " ")
            for old in oldCandidates(accusative: left) {
                if let found = occurrence(of: old, in: dictation) {
                    return .replace(old: found, new: matchingCase(right, of: found))
                }
            }
        }
        return nil
    }

    /// "Ahmed'i" → "Ahmed", "Ahmet"; "Ahmedi" → the same (Whisper drops the apostrophe and
    /// softens the last consonant); "kitabı" → "kitab", "kitap".
    private static func oldCandidates(accusative left: String) -> [String] {
        let lower = left.lowercased(with: locale)
        var stems: [String] = []
        if let apostrophe = left.lastIndex(of: "'") {
            stems.append(String(left[..<apostrophe]))
        } else {
            for suffix in ["yı", "yi", "yu", "yü", "nı", "ni", "nu", "nü", "ı", "i", "u", "ü"] where lower.hasSuffix(suffix) {
                stems.append(String(left.dropLast(suffix.count)))
            }
        }
        let hardened: [Character: String] = ["d": "t", "b": "p", "c": "ç", "ğ": "k"]
        var candidates: [String] = []
        for stem in stems {
            candidates.append(stem)
            if let last = stem.last, let hard = hardened[last] {
                candidates.append(String(stem.dropLast()) + hard)
            }
        }
        return candidates.filter { candidate in
            let folded = candidate.lowercased(with: locale)
            return folded.count >= 2 && !notReplaceable.contains(folded)
        }
    }

    /// `old` as it is written in the dictation, as whole words, ignoring case.
    private static func occurrence(of old: String, in dictation: String) -> String? {
        wordRanges(of: old, in: dictation).first.map { String(dictation[$0]) }
    }

    private static func wordRanges(of old: String, in dictation: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = dictation.startIndex
        while searchStart < dictation.endIndex,
              let range = dictation.range(of: old, options: .caseInsensitive, range: searchStart..<dictation.endIndex, locale: locale) {
            // A whole word: "üç" must not change "üçte"; "Ahmed'e" still has "Ahmed".
            let atWordStart = range.lowerBound == dictation.startIndex
                || !dictation[dictation.index(before: range.lowerBound)].isLetter
            let atWordEnd = range.upperBound == dictation.endIndex || !dictation[range.upperBound].isLetter
            if atWordStart, atWordEnd { ranges.append(range) }
            searchStart = range.upperBound
        }
        return ranges
    }

    private static func replacing(_ old: String, with new: String, in dictation: String) -> String? {
        let ranges = wordRanges(of: old, in: dictation)
        guard !ranges.isEmpty else { return nil }
        var result = ""
        var copied = dictation.startIndex
        for range in ranges {
            result += dictation[copied..<range.lowerBound] + new
            copied = range.upperBound
        }
        return result + dictation[copied...]
    }

    /// "ahmet" for "Ahmed" keeps the capital.
    private static func matchingCase(_ new: String, of old: String) -> String {
        guard let first = old.first, first.isUppercase, let newFirst = new.first, newFirst.isLowercase else { return new }
        return String(newFirst).uppercased(with: locale) + new.dropFirst()
    }

    private static func folded(_ text: String) -> String {
        text.lowercased(with: locale)
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?,")))
            .split(separator: " ").joined(separator: " ")
    }
}
