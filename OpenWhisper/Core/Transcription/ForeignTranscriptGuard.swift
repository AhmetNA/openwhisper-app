import Foundation
import NaturalLanguage

/// Whisper is forced to Turkish, yet on garbled audio (music in the buds' mic, a sentence cut
/// mid-word) it still writes German or Icelandic ("Það sem er neyndisvæmdir innan sig hérna.").
/// The user only speaks Turkish and English, so such a transcript is a failed recording, never
/// text to paste or a command to run.
///
/// Language ID is unreliable on a few words ("deploy et" → French, "Selam" → Indonesian), so a
/// transcript is foreign only when some of its words are not Turkish or English (`misheardCount`,
/// from `MisheardWordDetector`) and either two words have letters neither language uses, or it
/// is long enough for a confident other-language verdict.
enum ForeignTranscriptGuard {
    static let minimumWordsForLanguageID = 4
    static let foreignConfidence = 0.8

    static func isForeign(_ text: String, misheardCount: Int) -> Bool {
        guard misheardCount > 0 else { return false }
        let words = text.split { !$0.isLetter && $0 != "'" }
        // Two such words, so one name like "José" or "café" doesn't block a Turkish sentence.
        if words.filter({ hasForeignLetters(String($0)) }).count >= 2 { return true }
        guard words.count >= minimumWordsForLanguageID else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let ours = (hypotheses[.turkish] ?? 0) + (hypotheses[.english] ?? 0)
        guard let top = hypotheses.max(by: { $0.value < $1.value }),
              top.key != .turkish, top.key != .english else { return false }
        return top.value >= foreignConfidence && ours < 0.1
    }

    /// Letters outside the Turkish and English alphabets (plus the circumflex vowels Turkish
    /// still writes): ð, æ, ß, ñ, å, Cyrillic, Arabic, CJK…
    static func hasForeignLetters(_ text: String) -> Bool {
        let allowed = Set("abcçdefgğhıijklmnoöpqrsştuüvwxyzâîû")
        let locale = Locale(identifier: "tr_TR")
        return text.lowercased(with: locale).contains { $0.isLetter && !allowed.contains($0) }
    }
}
