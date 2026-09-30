import Foundation

/// Coding agents Jarvis can write to by name ("Claude Code'a şunu yaz …").
enum AgentApp: String, CaseIterable, Sendable {
    case claudeCode
    case codex
    case chatGPT

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .chatGPT: return "ChatGPT"
        }
    }

    /// Codex and ChatGPT are two names for the same desktop app on this machine.
    /// Resolve both through its bundle ID rather than assuming an app path.
    var bundleIdentifiers: [String] {
        switch self {
        case .claudeCode: return ["com.anthropic.claudefordesktop"]
        case .codex: return ["com.openai.codex"]
        case .chatGPT: return ["com.openai.codex"]
        }
    }

    /// Apps where a trailing "gönder" presses Return even without naming a target: the agent
    /// apps themselves plus terminals and editors that run the Claude Code / Codex CLIs.
    /// Everywhere else (Slack, Mail, …) "gönder" stays plain dictation and nothing is sent.
    /// Whether the user is probably talking to Claude Code / Codex rather than to Jarvis:
    /// one of them, or a terminal / editor that runs their CLIs, is in front.
    static func isAgentFront(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(sendCapableBundleIdentifiers.contains) ?? false
    }

    static let sendCapableBundleIdentifiers: Set<String> = [
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "ai.opencode.desktop",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "dev.zed.Zed",
    ]
}

/// A dictation addressed to a coding agent: where it goes, what to type, and whether to
/// press Return afterwards.
struct AgentDictation: Equatable, Sendable {
    /// Named target, nil when the text only ends with "gönder".
    let target: AgentApp?
    let body: String
    let send: Bool
}

/// Pure parsing, no app or keyboard access. Works on the raw Whisper transcript, so it
/// accepts common mishearings ("Cloud Code", "Klod", "Kodeks").
enum AgentCommandParser {
    private static let locale = Locale(identifier: "tr_TR")

    // "claude code'a", "cloud code'a", "cloudco'da", "klod koda", "claude'a", "codex'e", "kodekse" …
    // followed by an optional "şunu/şöyle/bunu" and a required verb, then an optional ":".
    private static let claudeName = #"(?:claude|cloud|clod|klod|klot|clot|klaud|claud|kılık|kilik|klık|kılod|kılot|kulod)(?:\s*(?:code|kodu|kod|kot|co|ko))?"#
    private static let codexName = #"(?:codex|kodeks|kodex|codeks|codecs|kodaks|kadex|kadexe|kadeks)"#
    // Whisper often writes the spoken English name as "chatypti" / "chatypt".
    private static let chatGPTName = #"(?:chat\s*gpt|chatgpt|chat\s*y?pti|chatypti|chatypt|çet\s*citi\s*piti|çetypti|çetypt)"#
    private static let suffix = #"(?:['’`]?\s*(?:y?a|y?e|n?[dt][ae]|n[ae]))?"#
    private static let filler = #"(?:\s+(?:şunu|şöyle|bunu|şu|sunu|soyle))?"#
    // The final capture: a "gönder" / "yolla" verb here means send without a trailing verb.
    private static let verb = #"\s+(?:yaz|yazsın|yazın|söyle|soyle|sor|((?:gönder|gonder|yolla)\p{L}*))"#

    private static let targetRegex: NSRegularExpression = {
        let pattern = "^\\s*(?:(\(claudeName))|(\(codexName))|(\(chatGPTName)))\(suffix)\(filler)\(verb)\\b[\\s:,.;-]*"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // Also accept the natural form "Codex'e merhaba ... gönder". This fallback requires an
    // explicit trailing send verb below, so "Claude'a geçtim" can never become a message.
    private static let directTargetRegex: NSRegularExpression = {
        let pattern = "^\\s*(?:(\(claudeName))|(\(codexName))|(\(chatGPTName)))\(suffix)\\s+"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // The last word is any form of "gönder" / "yolla" ("gönder", "gönderildi", "gönderme",
    // "gönderir misin", "yolla bunu"), optionally after "ve" / "sonra", and possibly
    // followed by closing punctuation or quotes (Whisper sometimes quotes the whole body).
    private static let sendRegex: NSRegularExpression = {
        let quotes = #""'“”‘’«»`"#
        let pattern = #"[\s,;:.!?\-"# + quotes + #"]*(?:\b(?:ve\s+)?(?:sonra|sonrasında|ardından)\s+|\bve\s+)?\b(?:gönder|gonder|yolla)\p{L}*(?:\s+(?:bunu|onu|mesajı|hemen))?(?:\s+m[iı]s[iı]n)?[\s.!?,;:"# + quotes + #"]*$"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// Returns nil when the text is neither addressed to an agent nor ends with "gönder".
    static func parse(_ text: String) -> AgentDictation? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var target: AgentApp?
        var sendVerb = false

        // Match on a Turkish-lowercased copy: "I" → "ı" etc. keep the same UTF-16 length
        // for the letters these patterns use, but compute the cut on the original string.
        let lowered = body.lowercased(with: locale)
        if lowered.utf16.count == body.utf16.count,
           let match = targetRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) {
            target = targetApp(for: match)
            sendVerb = match.range(at: 4).location != NSNotFound
            let cut = String.Index(utf16Offset: match.range.upperBound, in: body)
            body = String(body[cut...])
        } else if lowered.utf16.count == body.utf16.count,
                  let match = directTargetRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) {
            let cut = String.Index(utf16Offset: match.range.upperBound, in: body)
            let candidate = String(body[cut...])
            let loweredCandidate = candidate.lowercased(with: locale)
            guard loweredCandidate.utf16.count == candidate.utf16.count,
                  let sendMatch = sendRegex.firstMatch(in: loweredCandidate, range: NSRange(loweredCandidate.startIndex..., in: loweredCandidate)) else {
                return nil
            }
            target = targetApp(for: match)
            sendVerb = true
            let bodyEnd = String.Index(utf16Offset: sendMatch.range.location, in: candidate)
            body = String(candidate[..<bodyEnd])
        }

        var send = sendVerb
        let loweredBody = body.lowercased(with: locale)
        if loweredBody.utf16.count == body.utf16.count,
           let match = sendRegex.firstMatch(in: loweredBody, range: NSRange(loweredBody.startIndex..., in: loweredBody)) {
            send = true
            let cut = String.Index(utf16Offset: match.range.location, in: body)
            body = String(body[..<cut])
        }

        body = body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-\"'“”‘’«»`")))
        guard target != nil || send else { return nil }
        return AgentDictation(target: target, body: body, send: send)
    }

    private static func targetApp(for match: NSTextCheckingResult) -> AgentApp? {
        if match.range(at: 1).location != NSNotFound { return .claudeCode }
        if match.range(at: 2).location != NSNotFound { return .codex }
        if match.range(at: 3).location != NSNotFound { return .chatGPT }
        return nil
    }
}
