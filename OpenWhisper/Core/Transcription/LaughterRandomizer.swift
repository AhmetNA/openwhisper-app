import Foundation

/// Turns clear laughter transcript patterns into the keyboard-smash style commonly used in
/// Turkish chat messages (for example, "asdfghj"). The transformation is intentionally
/// conservative so ordinary words containing "ha" are left untouched.
struct LaughterRandomizer {
    struct Result: Equatable {
        let text: String
        let didTransform: Bool
    }

    private static let keyboardCharacters = Array("asdfghjklş")
    private static let laughterPattern = try! NSRegularExpression(
        pattern: #"(?iu)(?<![\p{L}\p{N}])(?:ha(?:[\s\p{P}]*ha)+|he(?:[\s\p{P}]*he)+|hi(?:[\s\p{P}]*hi)+|ah(?:[\s\p{P}]*ah)+|kahkah(?:a|alar))(?![\p{L}\p{N}])"#
    )

    /// Replaces each detected laughter expression with one fresh 8–10 character random.
    static func transform(_ text: String) -> Result {
        if isStandaloneLaughterMarker(text) {
            return Result(text: randomKeyboardSmash(), didTransform: true)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = laughterPattern.matches(in: text, range: fullRange)
        guard !matches.isEmpty else {
            return Result(text: text, didTransform: false)
        }

        var transformed = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: transformed) else { continue }
            transformed.replaceSubrange(range, with: randomKeyboardSmash())
        }
        return Result(text: transformed, didTransform: true)
    }

    private static func randomKeyboardSmash() -> String {
        let length = Int.random(in: 8...10)
        return String((0..<length).compactMap { _ in keyboardCharacters.randomElement() })
    }

    private static func isStandaloneLaughterMarker(_ text: String) -> Bool {
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let marker = folded.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return [
            "kahkaha", "kahkahalar", "guluyor", "guluyorum", "guluyoruz",
            "gulus", "gulmek", "gulucuk", "laughing", "laughter", "lol"
        ].contains(marker)
    }
}
