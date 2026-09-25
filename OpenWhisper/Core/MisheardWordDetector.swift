import AppKit

/// Finds words Whisper produced that exist in neither Turkish nor English ("Hadisedüm" for
/// "Hadise Düm", "Sesifullah" for "sesi fulle"), using the macOS spell checker's Turkish and
/// English dictionaries. Such a word is almost always a mishearing, so `LLMCleanup` may replace
/// it (preferring Turkish, then English) while every other word stays untouched.
///
/// Real words in the wrong place ("Aç da pek kandan" for "Ajda Pekkan'dan") are not caught:
/// each word is a real word on its own.
///
/// NSSpellChecker is main-thread only, hence `@MainActor`.
@MainActor
enum MisheardWordDetector {

    struct Word: Equatable, Sendable {
        let text: String
    }

    /// Shorter words are too often interjections or abbreviations ("hm", "ok").
    private static let minLength = 3

    /// Unknown words in `text`, each once, in order. `ignoring` holds lowercased words the user
    /// wants kept as-is (glossary terms, learned correction targets).
    static func find(in text: String, ignoring: Set<String> = []) -> [Word] {
        var seen = Set<String>()
        var result: [Word] = []
        for word in words(in: text) {
            let lower = word.lowercased(with: Locale(identifier: "tr_TR"))
            guard word.count >= minLength,
                  !word.contains(where: \.isNumber),
                  word != word.uppercased(),          // acronyms: API, MLP
                  !ignoring.contains(lower),
                  seen.insert(lower).inserted,
                  !isKnown(word) else { continue }
            result.append(Word(text: word))
        }
        return result
    }

    /// Whether the word is in the Turkish or the English dictionary.
    static func isKnown(_ word: String) -> Bool {
        isKnown(word, language: "tr") || isKnown(word, language: "en")
    }

    /// Letter runs, keeping a word-internal apostrophe so "Tarkan'ın" is checked whole.
    static func words(in text: String) -> [String] {
        text.split { !$0.isLetter && $0 != "'" && $0 != "’" }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
            .filter { !$0.isEmpty }
    }

    private static func isKnown(_ word: String, language: String) -> Bool {
        let range = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        return range.location == NSNotFound
    }
}
