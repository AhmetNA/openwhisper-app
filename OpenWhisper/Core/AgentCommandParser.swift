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

/// Which session of the agent app the text goes to ("yeni session'a", "son session'a").
enum AgentSession: String, Equatable, Sendable {
    /// Whatever session is open now.
    case current
    /// A freshly opened session.
    case new
    /// The session Jarvis last sent to, even if another one is open now.
    case last
}

/// A dictation addressed to a coding agent: where it goes, what to type, and whether to
/// press Return afterwards.
struct AgentDictation: Equatable, Sendable {
    /// Named target, nil when the text only ends with "gönder".
    let target: AgentApp?
    let body: String
    let send: Bool
    var session: AgentSession = .current
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
    // "yeni session'a", "new session", "yeni konuşmaya", "son session'ına" (Whisper: "son
    // sesine"). The session word itself is required, so "Claude'a yeni bir özellik ekle"
    // keeps its "yeni", and it only takes a dative / locative ending: "son konuşmayı özetle"
    // or "yeni session butonunu" stay part of the message.
    private static let sessionStem = #"(?:session|sesyon|seşın|seşin|seşn|sesin|sesşın|seans|oturum|konuşma|sohbet|chat(?!\s*(?:g?pt|y?pti?))|thread)"#
    private static let sessionCase = #"(?:['’`]\s*)?(?:s?[ıiuü]?n?[dt][ae]|s?[ıiuü]?n[ae]|y?[ae])"#
    private static let newSession = #"(?<new>(?:yeni|new)(?:\s+bir)?)"#
    private static let lastSession = #"(?<last>(?:en\s+)?son|bir\s+önceki|önceki|last|previous)"#
    private static let openVerb = #"(?:aç|açıp|açın|açtır)\p{L}*"#
    /// `bare` also accepts "new session" / "yeni sohbet" with no ending; only used where the
    /// verb has to follow right after, so nothing of the message can be swallowed.
    private static func sessionQualifier(bare: Bool, spotify: Bool) -> String {
        // After a Claude name, "yeni Spotify'a" is Whisper's take on "yeni session'a".
        let stem = spotify ? "(?:\(sessionStem)|spotify)" : sessionStem
        let word = "\(stem)\(sessionCase)\(bare ? "?" : "")(?!\\p{L})"
        return "(?:\(newSession)|\(lastSession))\\s+\(word)(?:\\s+\(openVerb)(?:\\s+ve)?)?"
    }
    // The final capture: a "gönder" / "yolla" verb here means send without a trailing verb.
    private static let verb = #"\s+(?:yaz|yazsın|yazın|söyle|soyle|sor|(?<send>(?:gönder|gonder|yolla)\p{L}*))"#
    private static let names = "(?:(?<claude>\(claudeName))|(?<codex>\(codexName))|(?<chatgpt>\(chatGPTName)))"

    private static let targetRegex: NSRegularExpression = {
        let pattern = "^\\s*\(names)\(suffix)(?:\\s+\(sessionQualifier(bare: true, spotify: true)))?\(filler)\(verb)\\b[\\s:,.;-]*"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // "Yeni session'a şunu gönder …" / "New session bunu yaz …" without naming an app:
    // sessions are a Claude Code thing, so Claude is assumed. The qualifier is mandatory here.
    private static let sessionOnlyRegex: NSRegularExpression = {
        let pattern = "^\\s*\(sessionQualifier(bare: true, spotify: false))\(filler)\(verb)\\b[\\s:,.;-]*"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // "Claude Code'da yeni session aç" / "yeni bir konuşma aç": open it, write nothing.
    private static let openNewSessionRegex: NSRegularExpression = {
        let word = "(?:\(sessionStem)|(?<spotify>spotify))\(sessionCase)?(?:y[ıi])?"
        let pattern = "^\\s*(?:\(names)\(suffix)\\s+)?\(newSession)\\s+\(word)\\s+\(openVerb)(?:\\s+m[ıi]s[ıi]n)?[\\s.!?,]*$"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    // Also accept the natural form "Codex'e merhaba ... gönder". This fallback requires an
    // explicit trailing send verb below, so "Claude'a geçtim" can never become a message.
    private static let directTargetRegex: NSRegularExpression = {
        let pattern = "^\\s*\(names)\(suffix)(?:\\s+\(sessionQualifier(bare: false, spotify: true)))?\\s+"
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
        var session = AgentSession.current

        // Match on a Turkish-lowercased copy: "I" → "ı" etc. keep the same UTF-16 length
        // for the letters these patterns use, but compute the cut on the original string.
        let lowered = body.lowercased(with: locale)
        if let match = openNewSessionRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
           // "Yeni Spotify aç" is only a misheard session after a Claude name.
           match.range(withName: "spotify").location == NSNotFound || targetApp(for: match) != nil {
            return AgentDictation(target: targetApp(for: match) ?? .claudeCode, body: "", send: false, session: .new)
        }
        if lowered.utf16.count == body.utf16.count,
           let match = targetRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) {
            target = targetApp(for: match)
            sendVerb = match.range(withName: "send").location != NSNotFound
            session = sessionKind(for: match)
            let cut = String.Index(utf16Offset: match.range.upperBound, in: body)
            body = String(body[cut...])
        } else if lowered.utf16.count == body.utf16.count,
                  let match = sessionOnlyRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) {
            target = .claudeCode
            sendVerb = match.range(withName: "send").location != NSNotFound
            session = sessionKind(for: match)
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
            session = sessionKind(for: match)
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
        return AgentDictation(target: target, body: body, send: send, session: session)
    }

    private static func targetApp(for match: NSTextCheckingResult) -> AgentApp? {
        if match.range(withName: "claude").location != NSNotFound { return .claudeCode }
        if match.range(withName: "codex").location != NSNotFound { return .codex }
        if match.range(withName: "chatgpt").location != NSNotFound { return .chatGPT }
        return nil
    }

    private static func sessionKind(for match: NSTextCheckingResult) -> AgentSession {
        if match.range(withName: "new").location != NSNotFound { return .new }
        if match.range(withName: "last").location != NSNotFound { return .last }
        return .current
    }
}
