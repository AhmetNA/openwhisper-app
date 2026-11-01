import Foundation

/// The video in Safari by English voice, while the dictation language is English
/// (`CommandLanguage`): "pause the video", "skip ahead 30 seconds", "next video". Like the
/// Turkish rules in `SystemCommandParser.parseVideoRequest`, play and pause need a video noun so a
/// bare "pause" stays with Spotify, and the whole utterance must be the command.
enum EnglishVideoCommands {
    private static let noun = #"(?:video|youtube|movie|episode|clip)s?"#
    private static let the = #"(?:(?:the|this|that) )?"#
    private static let number = #"(\d+|a|an|one|two|three|four|five|ten|fifteen|twenty|thirty|forty|forty five|fifty|sixty|ninety)"#
    private static let unit = #"(seconds?|secs?|minutes?|mins?)"#

    static func parse(_ text: String) -> VideoAction? {
        let raw = text.lowercased(with: CommandLanguage.locale)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[!?.,;"]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:hey\s+)?(?:jarvis\s+)?(?:please\s+)?(?:(?:can|could|would) you\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:please|now)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw.split(separator: " ").count <= 9 else { return nil }

        if let state = group(#"^(?:turn )?(on|off) (?:the )?(?:subtitles|captions)$|^(?:turn )?(?:the )?(?:subtitles|captions) (on|off)$"#, in: raw) {
            return .subtitles(on: state == "on")
        }
        if matches(raw, #"^(?:go |make it |make \#(the)\#(noun) )?full ?screen$"#) { return .fullscreen }
        if matches(raw, #"^(?:play )?(?:the )?next \#(noun)$|^skip \#(the)\#(noun)$"#) { return .next }
        if matches(raw, #"^how (?:much|long) is left (?:in|on|of) \#(the)\#(noun)$|^how long until \#(the)\#(noun) (?:ends|is over)$"#) {
            return .remaining
        }
        if matches(raw, #"^mute \#(the)\#(noun)$"#) { return .mute(true) }
        if matches(raw, #"^unmute \#(the)\#(noun)$"#) { return .mute(false) }

        // Seeking: "skip ahead 30 seconds", "go back a minute", "rewind 10 seconds".
        if let match = groups(#"^(?:skip|jump|go|fast forward|move)? ?(ahead|forward|back|backward|backwards)? ?\#(number) \#(unit)(?: (ahead|forward|back|backward|backwards))?$"#, in: raw),
           let seconds = seconds(match[1], match[2]) {
            let direction = match[0] + match[3]
            guard !direction.isEmpty || raw.hasPrefix("fast forward") else { return nil }
            return .seekBy(direction.hasPrefix("back") ? -seconds : seconds)
        }
        if let match = groups(#"^rewind (?:\#(the)\#(noun) )?\#(number) \#(unit)$"#, in: raw), let seconds = seconds(match[0], match[1]) {
            return .seekBy(-seconds)
        }
        if matches(raw, #"^(?:rewind|skip back|go back) \#(the)\#(noun)$"#) { return .seekBy(-10) }
        if matches(raw, #"^(?:fast forward|skip ahead|skip forward) \#(the)\#(noun)$"#) { return .seekBy(10) }

        if matches(raw, #"^restart \#(the)\#(noun)$|^(?:start|play) \#(the)\#(noun) (?:over|from the (?:beginning|start))$"#) {
            return .restart
        }
        if matches(raw, #"^(?:pause|stop) \#(the)\#(noun)$"#) { return .pause }
        if matches(raw, #"^(?:play|resume|continue|unpause) \#(the)\#(noun)$"#) { return .play }
        return nil
    }

    private static func seconds(_ amount: String, _ unit: String) -> Int? {
        let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "ten": 10, "fifteen": 15,
                     "twenty": 20, "thirty": 30, "forty": 40, "forty five": 45, "fifty": 50, "sixty": 60, "ninety": 90]
        guard let value = Int(amount) ?? words[amount] else { return nil }
        return unit.hasPrefix("m") ? value * 60 : value
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
