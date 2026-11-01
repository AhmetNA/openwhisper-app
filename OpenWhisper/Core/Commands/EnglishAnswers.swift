import Foundation

/// A spoken English yes or no to a question Jarvis asked, while the dictation language is
/// English (`CommandLanguage`). Only a short, plain answer counts: "yes", "go ahead", "no",
/// "cancel". Anything longer is unclear and the caller asks again or treats it as new speech.
enum EnglishAnswers {
    private static let fillers: Set<String> = ["jarvis", "please", "sir", "thanks", "thank", "you", "ok", "okay"]
    private static let yes: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "of course", "absolutely", "correct", "right", "go ahead", "do it",
        "please do", "confirm", "confirmed", "approve", "i confirm", "yes do it", "yes go ahead",
        "send it", "yes send it", "send", "delete it", "yes delete it", "press it", "yes press it", "read it",
        "yes read it", "allow", "allow it", "yes allow", "run it", "yes run it", "sounds good", "that's right",
    ]
    private static let no: Set<String> = [
        "no", "nope", "nah", "don't", "do not", "cancel", "cancel it", "stop", "wait", "never mind", "nevermind",
        "abort", "no thanks", "not now", "later", "don't send it", "don't send", "don't delete it", "don't press it",
        "don't read it", "deny", "don't allow", "don't run it",
    ]

    /// True for yes, false for no, nil when it is neither.
    static func decision(_ text: String) -> Bool? {
        let words = words(text)
        let answer = words.filter { !fillers.contains($0) }.joined(separator: " ")
        // "Okay" or "thanks" alone is a yes; "no thanks" keeps its no.
        if answer.isEmpty { return words.isEmpty ? nil : words.contains(where: { ["ok", "okay"].contains($0) }) ? true : nil }
        if no.contains(answer) || no.contains(words.joined(separator: " ")) { return false }
        if yes.contains(answer) { return true }
        // "yeah, go ahead", "no, don't send it": a leading yes or no and an answer of the same kind.
        let parts = answer.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if yes.contains(parts[0]), yes.contains(parts[1]) { return true }
        if no.contains(parts[0]), no.contains(parts[1]) { return false }
        return nil
    }

    /// The words of `text`, lowercased, with "don't" and "that's" kept whole.
    static func words(_ text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[^a-z0-9' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
    }
}
