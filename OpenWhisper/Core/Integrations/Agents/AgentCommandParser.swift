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

    /// "Claude'da", "Codex'te": where something is, for spoken replies.
    var locative: String {
        switch self {
        case .claudeCode: return "Claude'da"
        case .codex: return "Codex'te"
        case .chatGPT: return "ChatGPT'de"
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
    /// Spoken project name ("Bitirme projesine yaz …"), matched against the app's projects.
    var project: String? = nil
    /// No app was named, so Claude is assumed; a project only Codex knows goes to Codex.
    var targetAssumed = false
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
    // Whisper's spellings of "session" from real voice tests: "sesion", "seçeneğine" (2026-10-15).
    private static let sessionStem = #"(?:session|sesion|sesyon|seşın|seşin|seşn|sesin|sesşın|seçene[kğ]|seans|oturum|konuşma|sohbet|chat(?!\s*(?:g?pt|y?pti?))|thread)"#
    private static let sessionCase = #"(?:['’`]\s*)?(?:s?[ıiuü]?n?[dt][ae]|s?[ıiuü]?n[ae]|y?[ae])"#
    private static let newSession = #"(?<new>(?:yeni|new)(?:\s+bir)?)"#
    // "Sağ seçeneğine" was Whisper's "son session'ına"; only counts before a session word.
    private static let lastSession = #"(?<last>(?:en\s+)?(?:son|sağ)|bir\s+önceki|önceki|last|previous)"#
    private static let openVerb = #"(?:aç|açıp|açın|açtır|başlat)\p{L}*"#
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
    // "CloudCode'da şu an yeni bir sesion aç" (voice test 2026-10-22): a time word or
    // "lütfen" may sit around the command.
    private static let openNewSessionRegex: NSRegularExpression = {
        let word = "(?:\(sessionStem)|(?<spotify>spotify))\(sessionCase)?(?:y[ıi])?"
        let extra = #"(?:\s*,?\s*(?:şu\s+an|şimdi|hemen|lütfen))?"#
        let pattern = "^\\s*(?:\(names)\(suffix)\(extra)\\s+)?\(extra)\\s*\(newSession)\\s+\(word)\\s+\(openVerb)(?:\\s+m[ıi]s[ıi]n)?\(extra)[\\s.!?,]*$"
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

    // "Claude Code'a" / "ChatGPT'ye" alone: the app a "… geç" switches to.
    private static let nameOnlyRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: "^\\s*\(names)\(suffix)\\s*$", options: [.caseInsensitive])
    }()

    // "Claude Code'a geç ve şunu yolla …", "Cloud koda geç, yeni session başlat": the switch,
    // then everything after it. The tail is free text, so it is never cut at its own "ve".
    private static let switchThenRegex: NSRegularExpression = {
        let switchVerb = #"(?:uygulamasına\s+)?(?:geç|geçiş\s+yap|git|dön)(?:er\s+m[ıi]s[ıi]n|elim|sene)?"#
        let connector = #"(?:(?:ve\s+sonra|ve\s+ardından|ve|sonra|ardından)\s+)?"#
        let pattern = "^\\s*\(names)\(suffix)\\s+\(switchVerb)(?:\\s+lütfen)?(?:[\\s,.;:!]+)\(connector)(?<tail>\\S.*)$"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()

    // "Bitirme projesine yaz …", "Voice2TextLocal projesinde Claude'a şunu yaz …", "Codex'te
    // Bitirme projesinde yeni session aç": up to four words of project name right before a
    // "projesi…" word, then the usual command. Only at the start, so a "projesine" inside a
    // message stays text.
    private static let projectRegex: NSRegularExpression = {
        let word = #"[\p{L}\p{N}][\p{L}\p{N}._\-]*"#
        let projectWord = #"(?:proje(?:s[iı]|y|d|n)\p{L}*|projects?\p{L}*)"#
        let pattern = "^\\s*(?:\(names)\(suffix)\\s+)?(?<project>\(word)(?:\\s+\(word)){0,3}?)\\s+\(projectWord)[\\s,:;.-]+(?:ve\\s+)?(?<rest>\\S.*)$"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }()

    // "Bitirme projesine geç" / "… projesini aç": switch to the project's session only.
    private static let projectSwitchRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^(?:geç|git|dön|aç)\p{L}*(?:\s+m[ıi]s[ıi]n)?[\s.!?,]*$"#, options: [.caseInsensitive])
    }()

    /// Words that point at a project without naming it ("bu projeye", "yeni projede").
    private static let projectPronouns: Set<String> = [
        "bu", "şu", "o", "bir", "yeni", "eski", "benim", "bizim", "senin", "sizin", "diğer", "başka", "hangi", "her", "aynı", "son",
    ]
    /// Command words never belong to a project name: "Claude'a şunu yaz bu projeye …" is a message.
    private static let commandWords: Set<String> = [
        "yaz", "gönder", "gonder", "yolla", "söyle", "sor", "şunu", "bunu", "şöyle", "sunu",
    ]

    /// "<name> projesine/projesinde …": the command that follows, carrying the project, or nil.
    private static func parseWithProject(_ text: String) -> AgentDictation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased(with: locale)
        guard lowered.utf16.count == trimmed.utf16.count,
              let match = projectRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              let projectRange = Range(match.range(withName: "project"), in: trimmed),
              let restRange = Range(match.range(withName: "rest"), in: trimmed) else { return nil }
        let project = String(trimmed[projectRange])
        let projectLowered = project.lowercased(with: locale)
        let words = projectLowered.split(separator: " ").map(String.init)
        guard let first = words.first, !projectPronouns.contains(first), !words.contains(where: commandWords.contains),
              agentApp(named: project) == nil else { return nil }
        let rest = String(trimmed[restRange])
        let restLowered = rest.lowercased(with: locale)
        let leadTarget = targetApp(for: match)

        if projectSwitchRegex.firstMatch(in: restLowered, range: NSRange(restLowered.startIndex..., in: restLowered)) != nil {
            return AgentDictation(target: leadTarget ?? .claudeCode, body: "", send: false, project: project, targetAssumed: leadTarget == nil)
        }
        // The rest names the app itself ("… projesinde Claude'a şunu yaz"), or it gets the
        // app named before the project, Claude when none was.
        let restNamesApp = restLowered.range(of: "^\\s*\(names)\(suffix)(?!\\p{L})", options: [.regularExpression, .caseInsensitive]) != nil
        let command = restNamesApp ? rest : "\(callName(leadTarget ?? .claudeCode)) \(rest)"
        let commandLowered = command.lowercased(with: locale)
        let range = NSRange(commandLowered.startIndex..., in: commandLowered)
        // Only a command with its verb right there: "Bitirme projesine bugün çalıştım" is no message.
        guard openNewSessionRegex.firstMatch(in: commandLowered, range: range) != nil
                || targetRegex.firstMatch(in: commandLowered, range: range) != nil,
              var dictation = parse(command, allowProject: false), dictation.target != nil else { return nil }
        dictation.project = project
        dictation.targetAssumed = leadTarget == nil && !restNamesApp
        return dictation
    }

    /// How a command names the app ("Claude'a …"), so a rewritten command parses as if said.
    private static func callName(_ app: AgentApp) -> String {
        switch app {
        case .claudeCode: return "Claude'a"
        case .codex: return "Codex'e"
        case .chatGPT: return "ChatGPT'ye"
        }
    }

    /// The coding agent a spoken name means ("claude code'a", "cloud koda", "chatgpt'ye").
    static func agentApp(named spoken: String) -> AgentApp? {
        let lowered = spoken.lowercased(with: locale)
        guard let match = nameOnlyRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) else { return nil }
        return targetApp(for: match)
    }

    /// "Claude Code'a geç ve şunu yolla: …", "ChatGPT'ye geç, şunu yaz …", "Claude'a geç ve
    /// yeni session başlat": the agent dictation that follows the switch, or nil. The tail is
    /// read as if it had named the app itself ("Claude'a şunu yolla …"), or as "… yaz".
    static func parseAfterSwitch(_ text: String) -> AgentDictation? {
        let trimmed = WakeWordVerifier.strippingLeadingWakeWord(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased(with: locale)
        guard lowered.utf16.count == trimmed.utf16.count,
              let match = switchThenRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)),
              let target = targetApp(for: match),
              let tailRange = Range(match.range(withName: "tail"), in: trimmed) else { return nil }
        let tail = String(trimmed[tailRange])
        if let dictation = parse("\(callName(target)) \(tail)"), dictation.target == target { return dictation }
        if let body = JarvisAddressee.trailingTypeCommand(tail) {
            return AgentDictation(target: target, body: body, send: false)
        }
        return nil
    }

    // "Claude'da son session'ı özetle", "Cloud Code son sesinden özet", "son session'da ne
    // yaptık", "Claude'da nerede kalmıştık": a Claude name or a last-session word, then a
    // summary ask that ends the sentence. A bare "ne yaptık" names neither, so it stays chat.
    private static let summaryRegex: NSRegularExpression = {
        let session = "(?:(?:en\\s+)?(?:son|sağ)\\s+\(sessionStem)\\p{L}*(?:['’`]\\p{L}*)?)"
        let head = "(?:\(claudeName)(?:['’`]?\\p{L}*)?(?:\\s+\(session))?|\(session))"
        let ask = #"(?:bana\s+)?(?:(?:bir\s+)?özet\p{L}*(?:\s+(?:ver|geç|çıkar|yap|söyle)\p{L}*)?|(?:en\s+son\s+)?ne\s+(?:yaptık|yaptın|yapmıştık|yapmıştın|yaptınız|yapıldı|oldu)|nerede\s+kal(?:dık|mıştık))(?:\s+m[ıi]s[ıi]n)?"#
        let pattern = "^\\s*\(head)(?:\\s+(?:neler|ne)\\s+yaptığını)?[\\s,]+\(ask)[\\s.!?]*$"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    /// "Claude'da son session'ı özetle": Jarvis reads out what the last Claude Code session did.
    static func isSessionSummaryRequest(_ text: String) -> Bool {
        let lowered = WakeWordVerifier.strippingLeadingWakeWord(text).lowercased(with: locale)
        return summaryRegex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil
    }

    /// Returns nil when the text is neither addressed to an agent nor ends with "gönder".
    static func parse(_ text: String) -> AgentDictation? {
        parse(text, allowProject: true)
    }

    private static func parse(_ text: String, allowProject: Bool) -> AgentDictation? {
        if allowProject, let dictation = parseWithProject(text) { return dictation }
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
