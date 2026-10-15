import Foundation

/// Hard output guard for decoder artifacts that must never reach history, commands,
/// the clipboard, or an injected text field.
enum TranscriptSanitizer {
    private static let forbiddenPatterns = [
        #"(?iu)(?:[ \t]*[,;:\-–—][ \t]*)?\baltyaz[\u0131i][ \t]+m[ \t]*\.?[ \t]*k[ \t]*\.?(?:[!?\u2026]+)?"#,
    ]

    private static let forbiddenRegexes: [NSRegularExpression] = forbiddenPatterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    /// Whisper glues a percent to the word before it ("Sesi%30", "Jarvis%80"); Turkish
    /// writes "sesi %30". "100%" and a bare "%20" stay as they are.
    static func spacingPercentSigns(in text: String) -> String {
        text.replacingOccurrences(of: #"(?<=\p{L})%(?=\d)"#, with: " %", options: .regularExpression)
    }

    static func removeForbiddenArtifacts(from text: String) -> String {
        var result = text
        for regex in forbiddenRegexes {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        result = spacingPercentSigns(in: result)

        result = result.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-–—"))
        )
    }
}
