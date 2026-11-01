import Foundation

/// Mac and app commands in English, while the dictation language is English
/// (`CommandLanguage`): "turn off Wi-Fi", "open Safari", "take a screenshot". The whole
/// utterance must be the command, as in `SystemCommandParser.parseMac`, so dictation that
/// mentions Bluetooth or brightness is never run.
enum EnglishSystemCommands {
    private static let maxWords = 9
    private static let the = #"(?:(?:the|my|this|that) )?"#
    private static let percent = #"(\d{1,3})(?: ?%| percent)?"#

    static func parse(_ text: String, installedApps: [String]) -> SystemCommand? {
        let raw = text.lowercased(with: CommandLanguage.locale)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[!?.,;:"]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:hey\s+)?(?:jarvis\s+)?(?:please\s+)?(?:(?:can|could|would) you\s+)?(?:please\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:please|now|for me)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw.split(separator: " ").count <= maxWords else { return nil }
        return parseAction(raw) ?? parseToggle(raw) ?? parseTab(raw).map(SystemCommand.browser)
            ?? parseApp(raw, installedApps: installedApps)
    }

    private static func parseAction(_ text: String) -> SystemCommand? {
        if matches(text, #"^(?:stop listening(?: to me)?|turn off (?:the )?(?:microphone|mic)|disable (?:hey jarvis|the wake word))$"#) {
            return .disableWakeWord
        }
        if matches(text, #"^(?:what time is it|what is the time|what's the time|tell me the time|what time is it right now)$"#) { return .time }
        // "brief me", "what's on today", "what does my day look like", "what's on tomorrow".
        let day = #"(?:today|my day|the day|tomorrow)"#
        if matches(text, #"^(?:brief me|(?:give me |read me )?(?:my |the )?(?:daily )?briefing|(?:give me |read me )?(?:a |the )?(?:daily |morning )?summary of \#(day)|what(?: is|'s) (?:on |planned |happening |up )?(?:for )?\#(day)|what(?: is|'s) on (?:my |the )?(?:calendar|schedule|agenda)(?: for)? \#(day)|what does \#(day) look like|how does \#(day) look|what do i have \#(day))(?: for me)?$"#) {
            return .briefing(dayOffset: text.contains("tomorrow") ? 1 : 0)
        }
        if matches(text, #"^(?:how much battery(?: do i have| is left| left)?|what(?: is|'s) (?:my |the )?battery(?: level| at)?|battery(?: level| status| percentage)?)$"#) {
            return .battery
        }

        // Scrolling the frontmost app: "scroll down", "scroll the page up a lot", "scroll more".
        let large = matches(text, #"\b(?:a lot|way|all the way)\b"#)
        if matches(text, #"^scroll (?:\#(the)page )?down(?: a lot| a bit| way down)?$|^scroll(?: a bit)?$"#) { return .scroll(up: false, large: large) }
        if matches(text, #"^scroll (?:\#(the)page )?up(?: a lot| a bit| way up)?$"#) { return .scroll(up: true, large: large) }
        if matches(text, #"^(?:scroll (?:some )?more|keep scrolling)$"#) { return .scroll(up: SystemCommandParser.lastScrollUp, large: false) }

        // Brightness: "brightness up", "set the brightness to 50", "make the screen dimmer".
        if matches(text, #"bright|\bdim\b|dimmer"#) {
            guard matches(text, #"^(?:turn|set|make|change|put|increase|decrease|raise|lower|dim|brighten|max|maximum|full|lowest|minimum)\b|^(?:the )?(?:screen )?brightness\b"#)
            else { return nil }
            if let level = group(#"(?:brightness|screen) (?:to |at )?\#(percent)$"#, in: text).flatMap(Int.init), (0...100).contains(level) {
                return .brightness(up: true, level: level)
            }
            if matches(text, #"\b(?:max|maximum|full|all the way up)\b"#) { return .brightness(up: true, level: 100) }
            if matches(text, #"\b(?:lowest|minimum|all the way down)\b"#) { return .brightness(up: false, level: 0) }
            if matches(text, #"\b(?:down|lower|decrease|dim|dimmer|darker)\b"#) { return .brightness(up: false, level: nil) }
            if matches(text, #"\b(?:up|raise|increase|brighter|brighten)\b"#) { return .brightness(up: true, level: nil) }
            return nil
        }

        // "turn on dark mode", "dark mode off", "switch to light mode".
        if matches(text, #"^(?:(?:turn on|enable|switch to|go to|use) dark mode|dark mode on)$"#) { return .darkMode(on: true) }
        if matches(text, #"^(?:(?:turn off|disable) dark mode|dark mode off|(?:turn on|enable|switch to|go to|use) light mode)$"#) {
            return .darkMode(on: false)
        }

        if matches(text, #"^lock (?:the |my )?(?:screen|computer|mac|laptop)$|^lock$"#) { return .lockScreen }
        if matches(text, #"^unlock (?:the |my )?(?:screen|computer|mac|laptop)$|^(?:enter|type) (?:my |the )?password$"#) { return .unlockRequest }
        if matches(text, #"^(?:turn off|sleep) (?:the )?(?:screen|display|monitor)$|^put (?:the )?(?:screen|display) to sleep$"#) { return .displaySleep }
        if matches(text, #"^(?:turn on|wake(?: up)?) (?:the )?(?:screen|display|monitor)$"#) { return .displayWake }
        if matches(text, #"^put (?:the |my )?(?:computer|mac|laptop) to sleep$|^sleep (?:the |my )?(?:computer|mac|laptop)$"#) { return .sleep }
        if matches(text, #"^(?:start |turn on |show )?(?:the )?screen ?saver$"#) { return .screenSaver }
        if matches(text, #"^(?:take|grab|capture) (?:a )?screenshot$|^screenshot$|^capture the screen$"#) { return .screenshot }

        if matches(text, #"^mute(?: (?:the )?(?:sound|audio|volume|mac|computer|speakers))?$"#) { return .mute(true) }
        if matches(text, #"^unmute(?: (?:the )?(?:sound|audio|volume|mac|computer|speakers))?$"#) { return .mute(false) }
        return nil
    }

    /// "turn off Wi-Fi", "Bluetooth on", "connect my AirPods", "disconnect the headphones".
    private static func parseToggle(_ text: String) -> SystemCommand? {
        let headset = #"(?:headphones|headset|earbuds|airpods|buds)"#
        if matches(text, #"^connect \#(the)\#(headset)$"#) { return .headset(connect: true) }
        if matches(text, #"^disconnect \#(the)\#(headset)$"#) { return .headset(connect: false) }
        let device = #"(wi ?-?fi|wireless|internet|bluetooth)"#
        guard let match = groups(#"^(?:turn (on|off)|switch (on|off)|(enable|disable)) \#(the)\#(device)$|^\#(the)\#(device) (on|off)$"#, in: text)
        else { return nil }
        let state = match[0] + match[1] + match[2] + match[5]
        let name = match[3] + match[4]
        let on = state == "on" || state == "enable"
        return name == "bluetooth" ? .bluetooth(on: on) : .wifi(on: on)
    }

    /// Safari: "open a new tab", "close this tab", "reload the page", "go back".
    private static func parseTab(_ text: String) -> BrowserAction? {
        // "search for Daft Punk on Spotify" is Spotify's.
        guard !text.contains("spotify") else { return nil }
        if matches(text, #"^(?:open )?(?:a )?new tab$"#) { return .newTab }
        if matches(text, #"^close \#(the)tab$"#) { return .closeTab }
        if matches(text, #"^(?:reload|refresh) (?:\#(the)page)?$|^(?:reload|refresh)$"#) { return .reload }
        if matches(text, #"^go back(?: a page| to the previous page)?$"#) { return .back }
        if matches(text, #"^go forward(?: a page)?$"#) { return .forward }
        if matches(text, #"^(?:go to the )?next tab$"#) { return .nextTab }
        if matches(text, #"^(?:go to the )?previous tab$"#) { return .previousTab }
        if let query = group(#"^(?:search|look up) (?:youtube|on youtube) for (.+)$|^(?:search for |find )?(.+) on youtube$"#, in: text) {
            return .search(.youtube, query)
        }
        if let query = group(#"^(?:google|search google for|search the web for|search for|look up) (.+)$"#, in: text) {
            return .search(.google, query)
        }
        return nil
    }

    /// "open Safari", "launch Xcode", "quit Chrome", "force quit Slack", "switch to Mail".
    private static func parseApp(_ text: String, installedApps: [String]) -> SystemCommand? {
        guard let match = groups(#"^(open|launch|start|quit|close|exit|force quit|kill|switch to|go to|bring up) (?:the )?(.+?)(?: app| application)?$"#, in: text)
        else { return nil }
        let verb = match[0]
        let spoken = match[1]
        if ["open", "launch", "start", "switch to", "go to", "bring up"].contains(verb),
           let agent = AgentCommandParser.agentApp(named: spoken) {
            return .switchToAgent(agent)
        }
        switch verb {
        case "switch to", "go to", "bring up":
            return SystemCommandParser.resolveName(spoken, in: installedApps).map { .switchToApp($0) }
        default:
            guard let app = SystemCommandParser.resolveApp(spoken, in: installedApps) else { return nil }
            if ["open", "launch", "start"].contains(verb) { return .openApp(app) }
            if ["force quit", "kill"].contains(verb) { return .forceQuitApp(app) }
            return .quitApp(app)
        }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The first group that matched.
    private static func group(_ pattern: String, in text: String) -> String? {
        groups(pattern, in: text)?.first { !$0.isEmpty }
    }

    /// Every capture group, "" for one that took no part.
    private static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
