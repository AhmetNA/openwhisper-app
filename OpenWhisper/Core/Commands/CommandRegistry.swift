import Foundation

/// A voice command the rules recognised, ready to run.
enum VoiceCommand: Equatable {
    /// "Claude Code'a yaz …", "… gönder": typed into an agent app (`AgentCommandParser`).
    case agent(AgentDictation)
    case timer(TimerCommandParser.Command)
    /// Mac actions, calendar entries, Safari and video (`SystemController.perform`).
    case system(SystemCommand)
    /// The Spotify request as `SpotifyManager.handleCommand` should read it.
    case spotify(String)

    /// Sleep and lock stop the Mac listening, so nothing can run after them.
    var endsSession: Bool {
        guard case .system(let command) = self else { return false }
        return ([.sleep, .displaySleep, .lockScreen, .disableWakeWord] as [SystemCommand]).contains(command)
    }
}

/// Every rule-based command, in one table: each transcript, and each part of a
/// multi-command one, is read by the same parsers in the same order. Pure, so it is unit-tested.
///
/// The order is the meaning: "yarın saat 7'de beni uyandır" is a timer before it is a
/// calendar entry, "YouTube'da lofi ara" a browser search before a Spotify request.
enum CommandRegistry {
    enum Domain: String, CaseIterable {
        case agent, timer, mailReply, browser, video, system, spotify
    }

    /// What `SystemController.perform` runs.
    static let systemDomains: Set<Domain> = [.mailReply, .browser, .video, .system]
    /// What the single-command route asks for before reminders; Spotify comes after them,
    /// with the models' help.
    static let commandDomains: Set<Domain> = systemDomains.union([.timer])

    /// What the parsers need to know about the app and the Mac.
    struct Context {
        /// An alarm is sounding now ("tamam", "5 dakika ertele").
        var ringing = false
        /// Some timer runs, so a bare "ne kadar kaldı" is about it.
        var timerActive = false
        var installedApps: [String] = []
        /// Shortcuts.app names; only fetched when the text mentions a shortcut.
        var shortcuts: () -> [String] = { [] }
        var now = Date()
    }

    struct Entry {
        let domain: Domain
        /// May be one step of several. An agent body is free text that would be cut apart.
        let chains: Bool
        /// May take the verb of the last command ("hem Wi-Fi hem Bluetooth'u aç"). Not for
        /// free text: "Tarkan ve Sezen Aksu çal" is one search, and a calendar title or a
        /// search query would be cut in two.
        let sharesVerb: Bool
        let parse: (String, Context) -> VoiceCommand?
    }

    static let entries: [Entry] = [
        Entry(domain: .agent, chains: false, sharesVerb: false) { text, _ in
            (AgentCommandParser.parseAfterSwitch(text) ?? AgentCommandParser.parse(text)).map(VoiceCommand.agent)
        },
        Entry(domain: .timer, chains: true, sharesVerb: true) { text, context in
            TimerCommandParser.parse(text, ringing: context.ringing, active: context.timerActive, now: context.now)
                .map(VoiceCommand.timer)
        },
        // The reply keeps its case and punctuation, may be of any length, and may name a
        // date ("yarın gelirim diye son maile cevap ver"), so it comes before the calendar.
        Entry(domain: .mailReply, chains: false, sharesVerb: false) { text, _ in
            SystemCommandParser.parseMailReply(text).map(VoiceCommand.system)
        },
        // Calendar events are SetFit's `calendar_intent` decision (`AppState.calendarEventRequest`).
        Entry(domain: .browser, chains: true, sharesVerb: false) { text, _ in
            SystemCommandParser.parseBrowserRequest(text).map { .system(.browser($0)) }
        },
        Entry(domain: .video, chains: true, sharesVerb: true) { text, _ in
            SystemCommandParser.parseVideoRequest(text).map { .system(.video($0)) }
        },
        Entry(domain: .system, chains: true, sharesVerb: true) { text, context in
            let mentionsShortcut = text.range(of: SystemCommandParser.shortcutMention, options: [.regularExpression, .caseInsensitive]) != nil
            return SystemCommandParser.parseMac(text, installedApps: context.installedApps,
                                                shortcuts: mentionsShortcut ? context.shortcuts() : [])
                .map(VoiceCommand.system)
        },
        // The rule gate only (no model guess), so a song title with "ve" in it isn't cut
        // into two requests; the single-command route asks the models after these rules.
        Entry(domain: .spotify, chains: true, sharesVerb: false) { text, _ in
            let request = SpotifyManager.commandModeText(
                SpotifyManager.repairPlayVerbMishearing(SpotifyManager.repairVolumeMishearing(text)))
            return SpotifyManager.explicitIntent(in: request) != nil ? .spotify(request) : nil
        },
    ]

    /// The first entry, among `domains`, that reads `text` as its command.
    static func match(_ text: String, in domains: Set<Domain> = Set(Domain.allCases),
                      context: Context) -> VoiceCommand? {
        match(text, where: { domains.contains($0.domain) }, context: context)
    }

    private static func match(_ text: String, where include: (Entry) -> Bool, context: Context) -> VoiceCommand? {
        for entry in entries where include(entry) {
            if let command = entry.parse(text, context) { return command }
        }
        return nil
    }

    /// One command of a chain. Developer mode opens apps and starts music: only ever on its own.
    static func step(_ text: String, sharingVerb: Bool = false, context: Context) -> VoiceCommand? {
        let command = match(text, where: { $0.chains && (!sharingVerb || $0.sharesVerb) }, context: context)
        return command == .system(.developerMode) ? nil : command
    }

    /// The commands in `text`, or nil for the single-command route: fewer than two, or one
    /// that ends the session before the last.
    static func plan(_ text: String, context: Context) -> [MultiCommandSplitter.Step<VoiceCommand>]? {
        // "Claude Code'a yaz: Wi-Fi'yi aç ve …", "son maile cevap yaz: …": a message, whatever
        // it says. Any entry that never chains takes the whole text.
        if match(text, where: { !$0.chains }, context: context) != nil { return nil }
        var context = context
        var shortcutNames: [String]?
        let fetch = context.shortcuts
        context.shortcuts = {
            if shortcutNames == nil { shortcutNames = fetch() }
            return shortcutNames ?? []
        }
        let steps = MultiCommandSplitter.plan(
            WakeWordVerifier.strippingLeadingWakeWord(text),
            parse: { step($0, context: context) },
            sharingVerb: { step($0, sharingVerb: true, context: context) }
        )
        guard let steps, !steps.dropLast().contains(where: { $0.command.endsSession }) else { return nil }
        return steps
    }
}
