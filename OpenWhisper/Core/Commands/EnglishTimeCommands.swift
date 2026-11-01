import Foundation

/// Timers, reminders and calendar events in English, while the dictation language is English
/// (`CommandLanguage`): "set a timer for 10 minutes", "remind me to call mom tomorrow at 3",
/// "schedule a meeting with Ali on Monday at 2". The same hour rule as the Turkish parsers:
/// 1–7 without "am" or "morning" is the afternoon, except when waking up.
enum EnglishTimeCommands {
    // MARK: - Lengths of time

    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8,
        "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "twenty five": 25,
        "thirty": 30, "forty": 40, "forty five": 45, "fifty": 50, "sixty": 60, "ninety": 90,
    ]
    private static let number = "(?:\\d+(?:\\.\\d+)?|" + numberWords.keys.sorted { $0.count > $1.count }.joined(separator: "|") + ")"
    private static let unit = #"(?:hours?|hrs?|minutes?|mins?|seconds?|secs?)"#
    private static let segment = #"\#(number) \#(unit)"#
    /// "10 minutes", "an hour and a half", "half an hour", "1 hour 30 minutes".
    static let duration = #"(?:half an hour|a quarter of an hour|\#(segment)(?:(?: and|,)? \#(segment))*(?: and a half)?)"#

    static func seconds(_ spoken: String) -> Int? {
        if spoken == "half an hour" { return 1800 }
        if spoken == "a quarter of an hour" { return 900 }
        guard let regex = try? NSRegularExpression(pattern: #"(\#(number)) (\#(unit))"#) else { return nil }
        var total = 0.0
        var lastUnit = 0.0
        for match in regex.matches(in: spoken, range: NSRange(spoken.startIndex..., in: spoken)) {
            guard let n = Range(match.range(at: 1), in: spoken), let u = Range(match.range(at: 2), in: spoken) else { continue }
            let amount = Double(spoken[n]) ?? Double(numberWords[String(spoken[n])] ?? 0)
            lastUnit = spoken[u].hasPrefix("h") ? 3600 : spoken[u].hasPrefix("m") ? 60 : 1
            total += amount * lastUnit
        }
        if spoken.hasSuffix("and a half") { total += lastUnit / 2 }
        return total > 0 ? Int(total.rounded()) : nil
    }

    // MARK: - Days and clock times

    struct When {
        var date: Date
        var hasTime: Bool
        var hasDay: Bool
        /// The text with the day and time words taken out.
        var rest: String
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let hourWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12,
    ]

    /// "tomorrow at 3", "at 7:30 pm", "next Monday", "tonight at 8", "at noon". Nil when the
    /// text names no day and no time.
    static func when(in text: String, now: Date, calendar: Calendar = .current, morningByDefault: Bool = false) -> When? {
        var rest = text
        func take(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let whole = Range(match.range, in: rest) else { return nil }
            let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: rest).map { String(rest[$0]) } ?? "" }
            rest.replaceSubrange(whole, with: " ")
            return groups
        }

        var dayOffset: Int?
        var evening = false
        var morning = false
        if take(#"\b(?:the )?day after tomorrow\b"#) != nil { dayOffset = 2 }
        else if take(#"\btomorrow\b"#) != nil { dayOffset = 1 }
        else if take(#"\btonight\b"#) != nil { dayOffset = 0; evening = true }
        else if take(#"\btoday\b"#) != nil { dayOffset = 0 }
        else if let match = take(#"\b(?:on |this |next )?(sunday|monday|tuesday|wednesday|thursday|friday|saturday)\b"#) {
            let target = (weekdays.firstIndex(of: match[1]) ?? 0) + 1
            let today = calendar.component(.weekday, from: now)
            var ahead = (target - today + 7) % 7
            if ahead == 0 { ahead = 7 }
            dayOffset = ahead
        }
        if take(#"\b(?:in the |this )?(?:evening|afternoon)\b|\bat night\b"#) != nil { evening = true }
        if take(#"\b(?:in the |this )?morning\b"#) != nil { morning = true }

        var hour: Int?
        var minute = 0
        /// Noon, midnight and "12 am" are already on the 24-hour clock.
        var exact = false
        if let match = take(#"\b(?:at )?(noon|midnight)\b"#) {
            hour = match[1] == "noon" ? 12 : 0
            exact = true
        } else if let match = take(#"\b(?:at |by |for )?(\d{1,2})(?::(\d{2}))? ?(am|pm|a m|p m|o'clock)\b"#)
                    ?? take(#"\b(?:at|by|for) (\d{1,2})(?::(\d{2}))?\b(?! ?(?:minutes?|hours?|seconds?|mins?|hrs?|days?))"#) {
            hour = Int(match[1])
            minute = Int(match[2]) ?? 0
            let marker = match.count > 3 ? match[3] : ""
            if marker.hasPrefix("p") { evening = true }
            if marker.hasPrefix("a") { morning = true }
            if marker.hasPrefix("a"), hour == 12 { hour = 0; exact = true }
        } else if let match = take(#"\bat (one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)(?: (thirty|fifteen|forty five))?(?: o'clock)?\b"#) {
            hour = hourWords[match[1]]
            minute = ["thirty": 30, "fifteen": 15, "forty five": 45][match[2]] ?? 0
        }
        guard dayOffset != nil || hour != nil else { return nil }
        guard (hour ?? 0) <= 23, minute <= 59 else { return nil }

        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = 0
        guard let midnight = calendar.date(from: comps),
              var date = calendar.date(byAdding: .day, value: dayOffset ?? 0, to: midnight) else { return nil }
        if var h = hour {
            if !exact, h < 12, evening || (!morning && !morningByDefault && (1...7).contains(h)) { h += 12 }
            date = calendar.date(bySettingHour: h, minute: minute, second: 0, of: date) ?? date
            if dayOffset == nil, date <= now {
                // "at 7" at 15:00 means 19:00, not tomorrow morning.
                if !exact, !morning, !evening, !morningByDefault, h < 12,
                   let later = calendar.date(byAdding: .hour, value: 12, to: date), later > now {
                    date = later
                } else {
                    date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
                }
            }
        }
        let cleaned = rest.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return When(date: date, hasTime: hour != nil, hasDay: dayOffset != nil, rest: cleaned)
    }

    // MARK: - Timers

    private static let timerNoun = #"(?:timers?|countdowns?|alarms?)"#

    static func timer(_ text: String, ringing: Bool, active: Bool, now: Date, calendar: Calendar = .current) -> TimerCommandParser.Command? {
        let t = normalize(text)
        guard !t.isEmpty, t.split(separator: " ").count <= 14 else { return nil }
        if ringing {
            if matches(t, #"^snooze\b"#) {
                let d = firstMatch(duration, in: t).flatMap(seconds)
                return .snooze(seconds: d ?? TimerCommandParser.defaultSnooze)
            }
            if matches(t, #"^(?:(?:ok|okay|alright|stop|stop it|enough|thanks|thank you|got it|i'm up|i am up|turn it off|shut up|cancel)(?: jarvis)? ?)+$"#)
                || matches(t, #"^(?:stop|cancel|turn off) (?:the )?\#(timerNoun)$"#) {
                return .stop
            }
        }
        // The music's sleep timer is Spotify's.
        if matches(t, #"\bsleep timer\b"#) { return nil }

        if matches(t, #"^how (?:much time|long) (?:is )?(?:left|remaining)(?: on (?:the |my )?\#(timerNoun))?$|^(?:what's|what is) (?:the )?time (?:left|remaining)(?: on (?:the |my )?\#(timerNoun))?$"#),
           active || matches(t, timerNoun) {
            return .remaining
        }
        if matches(t, #"^(?:cancel|stop|delete|remove|clear|turn off) (?:the |my |all (?:the |my )?|all )?(?:\w+ )?\#(timerNoun)$"#) {
            return .cancel(all: matches(t, #"\ball\b|(?:timers|alarms|countdowns)$"#))
        }

        // Countdowns: "set a timer for 10 minutes (for tea)", "start a 20 minute tea timer",
        // "remind me in 10 minutes" (nothing to remind of), "alert me in an hour".
        let d = "(\(duration))"
        let label = #"(?: for (?:the |my )?([a-z ]{1,30}))?"#
        if let m = firstGroups(#"^(?:set|start|create|make|put on|begin) (?:a |an |the )?(?:timer|countdown) (?:for |of )?\#(d)\#(label)$"#, in: t)
            ?? firstGroups(#"^(?:timer|countdown) (?:for )?\#(d)\#(label)$"#, in: t),
           let s = seconds(m[0]) {
            return .start(seconds: s, label: cleanLabel(m.last ?? ""))
        }
        if let m = firstGroups(#"^(?:(?:set|start|create|make|begin) (?:a |an )?)?\#(d)(?: long)? (?:([a-z]+) )?(?:timer|countdown)$"#, in: t),
           let s = seconds(m[0]) {
            return .start(seconds: s, label: cleanLabel(m.last ?? ""))
        }
        if let m = firstGroups(#"^(?:remind|alert|tell|notify|ping|wake) me(?: up)? in \#(d)$|^(?:set (?:an |a )?)?alarm (?:for |in )\#(d)$"#, in: t),
           let s = seconds(m.first { !$0.isEmpty } ?? "") {
            return .start(seconds: s, label: nil)
        }

        // Clock alarms: "set an alarm for 7 am", "wake me up tomorrow at 6:30", "alarm at 8".
        let isWake = matches(t, #"^wake me(?: up)?\b"#)
        guard isWake || matches(t, #"^(?:(?:set|create|make) (?:an |a |the )?)?alarm\b"#),
              !matches(t, #"\bin \#(duration)$"#),
              let when = when(in: t.replacingOccurrences(of: #"\balarm for\b"#, with: "alarm at", options: .regularExpression),
                              now: now, calendar: calendar, morningByDefault: isWake),
              when.hasTime else { return nil }
        return .alarm(at: when.date, label: nil)
    }

    // MARK: - Reminders

    private static let reminderTriggers = #"^(?:please )?(?:remind me(?: to| that| about)?|set (?:a |an )?reminder(?: to| for)?|create (?:a |an )?reminder(?: to| for)?|add (?:a |an )?reminder(?: to| for)?|don't let me forget(?: to)?|don't forget to|reminder(?: to)?)\b"#

    /// "remind me to call mom tomorrow at 3", "remind me in 20 minutes to check the oven".
    /// Nil when there is no time to set it for; `ReminderManager` then asks the model.
    static func reminder(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> TurkishDateParser.ParsedResult? {
        var t = normalize(text)
        guard matches(t, reminderTriggers) else { return nil }
        t = t.replacingOccurrences(of: reminderTriggers, with: " ", options: .regularExpression)
        var fire: Date?
        if let m = firstGroups(#"\bin (\#(duration))\b|\b(\#(duration)) from now\b"#, in: t),
           let s = seconds(m.first { !$0.isEmpty } ?? "") {
            fire = now.addingTimeInterval(TimeInterval(s))
            t = t.replacingOccurrences(of: #"\bin \#(duration)\b|\b\#(duration) from now\b"#, with: " ", options: .regularExpression)
        } else if let when = when(in: t, now: now, calendar: calendar) {
            fire = when.hasTime ? when.date
                : calendar.date(bySettingHour: TurkishDateParser.defaultHour, minute: TurkishDateParser.defaultMinute, second: 0, of: when.date)
            t = when.rest
        }
        guard let fire else { return nil }
        let task = t.replacingOccurrences(of: #"^\s*(?:to|that|about|for)\s+|\s+(?:to|at|on)\s*$"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty else { return nil }
        return TurkishDateParser.ParsedResult(task: casing(task, from: text), fireDate: fire)
    }

    // MARK: - Calendar

    /// "schedule a meeting with Ali tomorrow at 3", "add dentist appointment on Friday at 10 to
    /// my calendar", "add an event called launch on Monday" (all day). A verb must open it:
    /// "schedule" and "book" alone, the others only with an event word.
    static func calendarRequest(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> AppState.CalendarRequest? {
        var t = normalize(text)
        let eventWord = #"\b(?:event|meeting|appointment|calendar)\b"#
        guard matches(t, #"^(?:schedule|book)\b"#)
                || (matches(t, #"^(?:add|create|put|make|set up|plan)\b"#) && matches(t, eventWord)) else { return nil }
        var minutes = CalendarEventParser.defaultMinutes
        if let m = firstGroups(#"\bfor (\#(duration))\b"#, in: t), let s = seconds(m[0]) {
            minutes = max(5, s / 60)
            t = t.replacingOccurrences(of: #"\bfor \#(duration)\b"#, with: " ", options: .regularExpression)
        } else if let m = firstGroups(#"\b(\#(number)) (?:hour|minute)(?:-| )?long\b|\b(\#(number))[- ](hour|minute)\b"#, in: t),
                  let s = seconds(m[0].isEmpty ? "\(m[1]) \(m[2])" : "\(m[0]) hour") {
            minutes = max(5, s / 60)
        }
        guard let when = when(in: t, now: now, calendar: calendar) else { return .needsDate }
        let title = when.rest
            .replacingOccurrences(of: #"^(?:schedule|book|add|create|put|make|set up|plan)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:to|on|in|into) (?:my |the )?calendar\b|\bcalendar\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:a|an|new) (?=event|meeting|appointment)|\bevent (?:called|named|titled)\b|\b(?:called|named|titled)\b|\bevent\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{1,3}[- ](?:hour|minute)(?:[- ]long)?\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:a|an|the|new)\s+|\s+(?:at|on|for|to)\s*$"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let event = CalendarEventParser.Event(
            title: title.isEmpty ? "Event" : casing(title, from: text),
            start: when.date, allDay: !when.hasTime, minutes: minutes)
        return .event(event)
    }

    // MARK: - Helpers

    static func normalize(_ text: String) -> String {
        text.lowercased(with: CommandLanguage.locale)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[!?;"]|,(?!\d)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\.\s*$|\.(?=\s)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(\d)-(minute|hour|second)"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"\b(a|p)\.m\b\.?"#, with: "$1m", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:hey\s+)?(?:jarvis\s+)?(?:please\s+)?(?:(?:can|could|would) you\s+)?(?:please\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:please|for me)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The words as the user said them ("Ali", "iPhone"), the first one capitalized.
    private static func casing(_ lowered: String, from original: String) -> String {
        var spoken: [String: String] = [:]
        for word in original.split(whereSeparator: { $0.isWhitespace }) {
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'’"))
            if spoken[bare.lowercased()] == nil { spoken[bare.lowercased()] = bare }
        }
        let words = lowered.split(separator: " ").map { spoken[String($0)] ?? String($0) }
        let joined = words.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private static func cleanLabel(_ raw: String) -> String? {
        let label = raw.replacingOccurrences(of: #"^(?:the|my|a)\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return label.isEmpty || ["timer", "countdown", "long"].contains(label) ? nil : label
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }

    /// Every capture group, "" for one that took no part.
    private static func firstGroups(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
}
