import Foundation

/// Deterministic Turkish (+ a few English) relative-date/time parser for voice reminder
/// commands. Runs BEFORE the Ollama LLM parse in ReminderManager — Ollama is a fuzzy fallback
/// for phrasing this doesn't recognize, not the primary source of truth for arithmetic that a
/// regex can get exactly right every time.
///
/// Deliberately has ZERO dependency on AppKit/EventKit/owLog so it can be compiled and
/// unit-tested standalone with `swiftc` (see Tools/main.swift) — same pattern as
/// CorrectionEngine.swift.
enum TurkishDateParser {

    struct ParsedResult: Equatable {
        let task: String
        let fireDate: Date
    }

    /// Reminders with no explicit time fire at this hour by default.
    static let defaultHour = 9
    static let defaultMinute = 0

    // MARK: - Turkish-safe casing (Swift's plain lowercased() maps "I" -> "i" per ASCII rules,
    // not "ı" — see CorrectionEngine.trLower for the same fix applied there).

    private static func trLower(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "İ": out += "i"
            case "I": out += "ı"
            default: out += String(ch).lowercased()
            }
        }
        return out
    }

    private static func trUpperFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        let rest = s.dropFirst()
        let upperFirst: String
        switch first {
        case "i": upperFirst = "İ"
        case "ı": upperFirst = "I"
        default: upperFirst = String(first).uppercased()
        }
        return upperFirst + rest
    }

    // MARK: - Trigger phrase stripping (leaves just the task behind)

    private static let phraseTriggersLongestFirst = [
        "don't let me forget",
        "don't forget to",
        "create a reminder",
        "add a reminder",
        "set a reminder",
        "set reminder",
        "hatırlatıcı kur",
        "hatırlatıcı ekle",
        "bana unutturma",
        "bana hatırlat",
        "remind me to",
        "remind me",
        "hatırlatıcı",
        "hatırlat",
        "unutturma",
        "reminder",
        // Bare address pronouns left dangling when the paired trigger word ends up elsewhere
        // in the sentence, e.g. "bana 10 dakika sonra kahve içmeyi hatırlat" — "bana" and
        // "hatırlat" aren't adjacent, so the phrase-level "bana hatırlat" match above doesn't
        // fire, and without this the pronoun would leak into the task as "Bana kahve içmeyi".
        "bana",
        "beni"
    ]

    private static func stripTriggers(_ text: String) -> String {
        var result = text
        for phrase in phraseTriggersLongestFirst {
            if let re = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b") {
                let range = NSRange(result.startIndex..., in: result)
                result = re.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
            }
        }
        return result
    }

    // MARK: - Number words

    private static let numberWords: [String: Int] = [
        "bir": 1, "iki": 2, "üç": 3, "uc": 3, "dört": 4, "dort": 4, "beş": 5, "bes": 5,
        "altı": 6, "alti": 6, "yedi": 7, "sekiz": 8, "dokuz": 9, "on": 10
    ]
    private static let numberPattern = "(\\d+|bir|iki|üç|uc|dört|dort|beş|bes|altı|alti|yedi|sekiz|dokuz|on)"

    private static func numberValue(_ s: String) -> Int? {
        if let n = Int(s) { return n }
        return numberWords[s]
    }

    // MARK: - Weekdays (Calendar.weekday: Sunday = 1 ... Saturday = 7)

    private static let weekdays: [String: Int] = [
        "pazartesi": 2, "salı": 3, "sali": 3, "çarşamba": 4, "carsamba": 4,
        "perşembe": 5, "persembe": 5, "cuma": 6, "cumartesi": 7, "pazar": 1
    ]

    // MARK: - Months

    private static let months: [String: Int] = [
        "ocak": 1, "şubat": 2, "subat": 2, "mart": 3, "nisan": 4, "mayıs": 5, "mayis": 5,
        "haziran": 6, "temmuz": 7, "ağustos": 8, "agustos": 8, "eylül": 9, "eylul": 9,
        "ekim": 10, "kasım": 11, "kasim": 11, "aralık": 12, "aralik": 12
    ]

    /// "7 kasım", "7 kasım'a", "7 kasımda", and Whisper's split "7 kasım 'a". Only after a day
    /// number: "Kasım" alone is a name ("Kasım'la toplantı"), "ekim" and "ocak" are words.
    private static let monthDayPattern = "\\b(\\d{1,2})\\s+(ocak|şubat|subat|mart|nisan|mayıs|mayis|haziran|temmuz|ağustos|agustos|eylül|eylul|ekim|kasım|kasim|aralık|aralik)(?:\\s*'\\s*\\p{L}+|\\p{L}*)"

    /// This year's date, or next year's once it has passed. Nil for "31 şubat".
    private static func monthDay(day: Int?, month: Int?, now: Date, calendar cal: Calendar) -> Date? {
        guard let day, let month, (1...31).contains(day) else { return nil }
        var comps = cal.dateComponents([.year], from: now)
        comps.month = month
        comps.day = day
        comps.hour = defaultHour
        comps.minute = defaultMinute
        guard var date = cal.date(from: comps), cal.component(.day, from: date) == day else { return nil }
        if date < cal.startOfDay(for: now) {
            date = cal.date(byAdding: .year, value: 1, to: date) ?? date
        }
        return date
    }

    // MARK: - Match helper

    private struct Match {
        let range: Range<String.Index>
        let groups: [String?]
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: nsRange), let range = Range(m.range, in: text) else { return nil }
        var groups: [String?] = []
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) {
                groups.append(String(text[r]))
            } else {
                groups.append(nil)
            }
        }
        return Match(range: range, groups: groups)
    }

    // MARK: - Parse

    /// Returns nil when no recognizable relative-date expression is found — caller should
    /// fall back to the LLM in that case. `now`/`calendar` are injectable for testing.
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedResult? {
        let cal = calendar
        let lower = SpokenDuration.repairMishearing(trLower(text))
        var working = lower

        var dayLevelDate: Date?
        var exactDate: Date?

        // --- 1. Exact offsets: "10 dakika sonra", "yarım saat sonra", "bir buçuk saat sonra",
        // "2 saat 15 dakika sonra" (override everything else) ---
        if let m = SpokenDuration.first(in: working, suffix: "\\s+sonra\\b") {
            exactDate = now.addingTimeInterval(TimeInterval(m.seconds))
            working.removeSubrange(m.range)
        }

        // --- 2. Day-level expressions (only if no exact minute/hour offset already matched) ---
        if exactDate == nil {
            if let m = firstMatch("\\b(?:öbür|obur)\\s+g[üu]n\\b", in: working) {
                dayLevelDate = cal.date(byAdding: .day, value: 2, to: now)
                working.removeSubrange(m.range)
            } else if let m = firstMatch("\\b\(numberPattern)\\s*hafta\\s+sonra\\b", in: working),
                      let n = numberValue(m.groups[0] ?? "") {
                dayLevelDate = cal.date(byAdding: .day, value: 7 * n, to: now)
                working.removeSubrange(m.range)
            } else if let m = firstMatch("\\b\(numberPattern)\\s*g[üu]n\\s+sonra\\b", in: working),
                      let n = numberValue(m.groups[0] ?? "") {
                dayLevelDate = cal.date(byAdding: .day, value: n, to: now)
                working.removeSubrange(m.range)
            } else if let m = firstMatch("\\bgelecek\\s+hafta\\b", in: working) {
                dayLevelDate = cal.date(byAdding: .day, value: 7, to: now)
                working.removeSubrange(m.range)
            } else if let m = firstMatch("\\bhaftaya\\b", in: working) {
                dayLevelDate = cal.date(byAdding: .day, value: 7, to: now)
                working.removeSubrange(m.range)
            } else if let m = firstMatch("\\bgelecek\\s+ay\\b", in: working) {
                dayLevelDate = cal.date(byAdding: .month, value: 1, to: now)
                working.removeSubrange(m.range)
            } else if let m = firstMatch("\\bay[ıi]n\\s+(\\d{1,2})\\s*'?(?:s[ıi]|[ıi])?\\b", in: working) {
                let day = Int(m.groups[0] ?? "") ?? 1
                var comps = cal.dateComponents([.year, .month], from: now)
                comps.day = day
                comps.hour = defaultHour
                comps.minute = defaultMinute
                var candidate = cal.date(from: comps) ?? now
                if candidate < cal.startOfDay(for: now) {
                    candidate = cal.date(byAdding: .month, value: 1, to: candidate) ?? candidate
                }
                dayLevelDate = candidate
                working.removeSubrange(m.range)
            } else if let m = firstMatch(monthDayPattern, in: working),
                      let date = monthDay(day: Int(m.groups[0] ?? ""), month: months[m.groups[1] ?? ""], now: now, calendar: cal) {
                dayLevelDate = date
                working.removeSubrange(m.range)
            } else if let m = firstMatch("\\b(?:önümüzdeki\\s+|gelecek\\s+)?(pazartesi|sal[ıi]|çarşamba|carsamba|perşembe|persembe|cuma|cumartesi|pazar)(?:\\s+günü)?\\b", in: working) {
                let key = m.groups[0] ?? ""
                if let target = weekdays[key] {
                    let currentWeekday = cal.component(.weekday, from: now)
                    var diff = (target - currentWeekday + 7) % 7
                    if diff == 0 { diff = 7 }
                    dayLevelDate = cal.date(byAdding: .day, value: diff, to: now)
                    working.removeSubrange(m.range)
                }
            } else if let m = firstMatch("\\byar[ıi]n(?:a|da)?\\b", in: working) {  // "yarına", "yarında"
                dayLevelDate = cal.date(byAdding: .day, value: 1, to: now)
                working.removeSubrange(m.range)
            } else if let m = firstMatch("\\bbug[üu]n(?:e|de)?\\b", in: working) {
                dayLevelDate = now
                working.removeSubrange(m.range)
            }
        }

        guard dayLevelDate != nil || exactDate != nil else { return nil }

        // --- 3. Explicit time-of-day, applied on top of a day-level date if present ---
        var explicitTime: (hour: Int, minute: Int)?
        if let m = firstMatch("\\bsaat\\s+(\\d{1,2})(?:[:.](\\d{2}))?\\s*'?(?:ye|ya|de|da|te|ta|e|a)?\\b", in: working) {
            let hour = Int(m.groups[0] ?? "") ?? defaultHour
            let minute = Int(m.groups[1] ?? "0") ?? 0
            explicitTime = (hour, minute)
            working.removeSubrange(m.range)
        } else if let m = firstMatch("\\b(\\d{1,2})(?:[:.](\\d{2}))?\\s*'?(?:ye|ya|de|da|te|ta|e|a)\\b", in: working) {
            let hour = Int(m.groups[0] ?? "") ?? defaultHour
            let minute = Int(m.groups[1] ?? "0") ?? 0
            explicitTime = (hour, minute)
            working.removeSubrange(m.range)
        }

        var resultDate: Date
        if let exactDate {
            // Minute/hour "sonra" offsets are already exact — an explicit clock time found
            // alongside one (rare/contradictory phrasing) is ignored in favor of the offset.
            resultDate = exactDate
        } else {
            let base = dayLevelDate ?? now
            if let explicitTime {
                var comps = cal.dateComponents([.year, .month, .day], from: base)
                comps.hour = explicitTime.hour
                comps.minute = explicitTime.minute
                resultDate = cal.date(from: comps) ?? base
            } else {
                var comps = cal.dateComponents([.year, .month, .day], from: base)
                comps.hour = defaultHour
                comps.minute = defaultMinute
                resultDate = cal.date(from: comps) ?? base
                // "bugün" with no explicit time and default hour already passed would fire
                // immediately — push to the same time tomorrow instead of surprising the user.
                if resultDate <= now {
                    resultDate = cal.date(byAdding: .day, value: 1, to: resultDate) ?? resultDate
                }
            }
        }

        // --- 4. Whatever's left after stripping the time/date expression + trigger words = task ---
        var task = stripTriggers(working)
        task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        while task.contains("  ") { task = task.replacingOccurrences(of: "  ", with: " ") }
        task = task.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!? "))
        guard !task.isEmpty else { return nil }

        return ParsedResult(task: trUpperFirst(task), fireDate: resultDate)
    }
}
