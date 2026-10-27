import Foundation

enum SpokenDoneEndpoint {
    /// Only the standalone final word is a control token; "done" inside a sentence is text.
    static func removingSuffix(from text: String) -> String? {
        guard let range = text.range(of: #"(?i)(?<![\p{L}\p{N}_'])\bdone\b[\s.!?,;:…]*$"#,
                                     options: .regularExpression) else { return nil }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
