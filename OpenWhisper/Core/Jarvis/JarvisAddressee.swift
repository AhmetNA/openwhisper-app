import Foundation

/// What Accessibility could prove about the keyboard focus when recording began. `unknown`
/// deliberately differs from `notEditable`: a missing permission or failed cross-process AX
/// request must not make Jarvis assume the user intentionally focused a non-text control.
enum TextFocusStatus: String, Sendable, Equatable {
    case editable
    case notEditable
    case unknown
}

/// Decides, for a "Jarvis" session that is no command, whether the user is talking to Jarvis
/// (he answers out loud) or dictating / talking to someone else (the text is typed). Typing is
/// the safe side: only a clearly addressed question or request reaches the chat.
enum JarvisAddressee {
    private static let locale = Locale(identifier: "tr_TR")

    enum DefaultRoute: String, Equatable, Sendable {
        case type
        case chat
    }

    /// Chat only at or above this score (0–100). `defaults write com.openwhisper.app jarvisChatMinScore 60`
    static var minScore: Int {
        let stored = UserDefaults.standard.integer(forKey: "jarvisChatMinScore")
        return (1...100).contains(stored) ? stored : 70
    }

    static func isForJarvis(score: Int?, minScore: Int) -> Bool {
        guard let score else { return false }
        return score >= minScore
    }

    /// Context is the primary signal. The language model is consulted when Accessibility could
    /// not determine the focus, and for a question in an editable field: "Talon'a karşı en iyi
    /// jungle pick'i hangisi?" with the Claude box focused was typed, not answered (24 Oct 2026).
    static func defaultRoute(
        focusStatus: TextFocusStatus,
        score: Int?,
        minScore: Int,
        isQuestion: Bool = false
    ) -> DefaultRoute {
        switch focusStatus {
        case .editable:
            return isQuestion && isForJarvis(score: score, minScore: minScore) ? .chat : .type
        case .notEditable:
            return .chat
        case .unknown:
            return isForJarvis(score: score, minScore: minScore) ? .chat : .type
        }
    }

    private static let questionRegex = try! NSRegularExpression(
        pattern: #"\?|\b(?:m[ıiuü](?:y[ıiuü]m|s[ıiuü]n|y[ıiuü]z|s[ıiuü]n[ıiuü]z|d[ıiuü]r|yd[ıiuü]|ym[ıiuü][sş])?|ne(?:den|ler|yi|ye)?|nas[ıi]l|hangi\w*|kim\w*|nere\w*|ka[çc]\w*|niye|ni[çc]in)\b"#,
        options: [.caseInsensitive])

    /// A question mark, a Turkish question particle ("mı", "musun") or a question word.
    static func looksLikeQuestion(_ text: String) -> Bool {
        let lowered = text.lowercased(with: locale)
        return questionRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil
    }

    /// On the lock screen (loginwindow in front) nobody can be dictating, so anything reaches the
    /// chat; a transcript with non-words there is noise heard through the locked Mac ("Siz se
    /// sonhalen" got a long spoken reply, 10 Oct 2026). Such text is dropped.
    static let lockScreenBundleID = "com.apple.loginwindow"

    static func skipsChat(frontBundleID: String?, misheardWordCount: Int) -> Bool {
        frontBundleID == lockScreenBundleID && misheardWordCount > 0
    }

    // MARK: - Explicit destination overrides

    // "buraya/imlece/alana yaz ..." is intentionally narrower than a bare leading "yaz".
    // "yaz bana bir şiir" is a request to Jarvis, while "buraya yaz bana bir şiir" is
    // an unambiguous request to type those words into the focused field.
    private static let leadingTypeRegex: NSRegularExpression = {
        let pattern = #"^\s*(?:buraya|imlece|alana|şuraya)\s+(?:şunu\s+|bunu\s+|onu\s+)?yaz(?:sana|abilir\s+m[iı]s[iı]n|ar\s+m[iı]s[iı]n)?\b[\s:,.;-]*"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // An editable field normally means dictation. These phrases are the escape hatch for
    // talking to Jarvis without moving focus away from that field.
    private static let explicitChatRegex: NSRegularExpression = {
        let pattern = #"^\s*(?:bana\s+cevap\s+ver|cevapla|jarvis(?:['’`]?\s*[ae])?\s+sor|seninle\s+konuşuyorum|sohbet\s+edelim)\b[\s:,.;-]*"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func leadingTypeCommand(_ text: String) -> String? {
        body(afterLeadingMatch: leadingTypeRegex, in: text)
    }

    static func explicitChatCommand(_ text: String) -> String? {
        body(afterLeadingMatch: explicitChatRegex, in: text)
    }

    private static func body(afterLeadingMatch regex: NSRegularExpression, in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased(with: locale)
        guard lowered.utf16.count == trimmed.utf16.count,
              let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) else {
            return nil
        }
        let cut = String.Index(utf16Offset: match.range.upperBound, in: trimmed)
        var body = String(trimmed[cut...])
        let leadingSeparators = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: ",;:.!?-\"'“”‘’«»`")
        )
        while let scalar = body.unicodeScalars.first, leadingSeparators.contains(scalar) {
            body.removeFirst()
        }
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    // MARK: - Trailing "yaz"

    // "… yaz", "… yazsana", "… yazar mısın", "… bunu yaz", "… yaz bunu", "… ve yaz."
    private static let typeRegex: NSRegularExpression = {
        let quotes = #""'“”‘’«»`"#
        let pattern = #"[\s,;:.!?\-"# + quotes + #"]*(?:\bve\s+)?(?:\b(?:bunu|şunu|sunu|onu)\s+)?\byaz(?:sana|sın|ın|abilir\s+m[iı]s[iı]n|ar\s+m[iı]s[iı]n)?(?:\s+(?:bunu|şunu|onu|hemen|lütfen))?[\s.!?,;:"# + quotes + #"]*$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// "bu yaz", "geçen yaz": the season, not the verb.
    private static let seasonWords: Set<String> = ["bu", "geçen", "gelecek", "o", "her", "bütün", "tüm", "bir", "bizim", "sıcak"]

    /// The text before a trailing "yaz" command, or nil when the text doesn't end with one.
    static func trailingTypeCommand(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased(with: locale)
        guard lowered.utf16.count == trimmed.utf16.count,
              let match = typeRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered))
        else { return nil }
        let cut = String.Index(utf16Offset: match.range.location, in: trimmed)
        let matched = String(lowered[String.Index(utf16Offset: match.range.location, in: lowered)...])
        let before = String(trimmed[..<cut])
        // A bare "yaz" right after a season word is the noun.
        let bareYaz = matched.split(whereSeparator: { !$0.isLetter }) == ["yaz"]
        if bareYaz, let previous = before.split(whereSeparator: { !$0.isLetter }).last,
           seasonWords.contains(previous.lowercased(with: locale)) {
            return nil
        }
        let body = before.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-\"'“”‘’«»`")))
        return body.isEmpty ? nil : body
    }
}
