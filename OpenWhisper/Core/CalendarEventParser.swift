import Foundation

/// "Yarın saat 3'te Mehmet'le toplantı ekle", "Cuma akşam 7'de yemek takvime ekle",
/// "Pazartesi randevu oluştur" (all day). Pure: the day comes from `TurkishDateParser`, this
/// adds the event-only rules on top (an event word plus an add verb, afternoon hours, all-day
/// events, a length). Runs on the raw transcript so "15:30" keeps its colon.
enum CalendarEventParser {
    struct Event: Equatable, Sendable {
        var title: String
        var start: Date
        var allDay: Bool
        var minutes: Int
    }

    static let defaultMinutes = 60
    private static let maxWords = 16
    private static let locale = Locale(identifier: "tr_TR")

    private static let eventNoun = #"\b(?:takvim\p{L}*|ajanda\p{L}*|etkinli\p{L}*|toplantı\p{L}*|randevu\p{L}*|görüşme\p{L}*|buluşma\p{L}*|meeting|event)"#
    // No "yaz": a trailing "… yaz" types the sentence (`JarvisAddressee.trailingTypeCommand`).
    private static let addVerb = #"\b(?:ekle|ekler misin|ekleyebilir misin|ekleyiver|oluştur|oluşturur musun|koy|koyar mısın|kaydet|ayarla|planla|gir)(?: lütfen)?$"#
    /// Verbs that only make an event when the calendar itself is named ("takvime koy").
    private static let calendarOnlyVerb = #"\b(?:koy|koyar mısın|kaydet|gir)(?: lütfen)?$"#

    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Event? {
        var working = text.lowercased(with: locale)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[,!?;"“”]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\.\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:hey\s+)?(?:(?:jarvis|cervis|carvis|jarvıs|çarvis|jervis)\s+)?(?:lütfen\s+)?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard working.split(separator: " ").count <= maxWords,
              matches(working, addVerb), matches(working, eventNoun),
              !matches(working, #"hatırlat|unutturma|remind"#) else { return nil }
        if matches(working, calendarOnlyVerb), !matches(working, #"\b(?:takvim|ajanda)"#) { return nil }

        // Spoken hours: "saat üçte" → "saat 3'te", "3 buçukta" → "3:30'da".
        working = spelledHours(working)
        working = working.replacingOccurrences(of: #"\b(\d{1,2})\s*buçu\p{L}*"#, with: "$1:30'da", options: .regularExpression)

        let minutes = take(#"\b(yarım|bir|iki|üç|dört|\d{1,2})\s+saatlik\b"#, from: &working)
            .map { $0 == "yarım" ? 30 : 60 * (number($0) ?? 1) } ?? defaultMinutes
        let period = take(#"\b(öğleden sonra|öğlen|öğle|akşamüstü|akşam|gece|sabahleyin|sabah)\b"#, from: &working)

        // An explicit clock time. The regexes mirror `TurkishDateParser` step 3.
        let clock = firstGroups(#"\bsaat\s+(\d{1,2})(?:[:.](\d{2}))?"#, in: working)
            ?? firstGroups(#"\b(\d{1,2})(?:[:.](\d{2}))?\s*'?(?:ye|ya|de|da|te|ta|e|a)\b"#, in: working)
        let offset = matches(working, #"\b\S+\s*(?:dakika|saat)\s+sonra\b"#)
        if let clock {
            guard let hour = Int(clock[0] ?? ""), hour <= 23,
                  (Int(clock[1] ?? "0") ?? 0) <= 59 else { return nil }
        }

        // `TurkishDateParser` needs a day word; a bare time means today.
        let namesDay = TurkishDateParser.parse(working, now: now, calendar: calendar) != nil
        guard let parsed = TurkishDateParser.parse(namesDay ? working : "bugün " + working, now: now, calendar: calendar),
              namesDay || clock != nil else { return nil }

        var start = parsed.fireDate
        let allDay = clock == nil && !offset
        if allDay {
            // The parser moves a time-less "bugün" to tomorrow once 09:00 has passed.
            let day = matches(working, #"\bbug[üu]n\b"#) ? now : parsed.fireDate
            start = calendar.startOfDay(for: day)
        } else if !offset {
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
            parts.hour = afternoonHour(parts.hour ?? 9, period: period)
            start = calendar.date(from: parts) ?? start
            // "Saat 3'te toplantı ekle" at 16:00 is tomorrow's 15:00.
            if !namesDay, start <= now { start = calendar.date(byAdding: .day, value: 1, to: start) ?? start }
        }

        guard let title = title(from: parsed.task, original: text) else { return nil }
        return Event(title: title, start: start, allDay: allDay, minutes: minutes)
    }

    /// Meetings at "3" are at 15:00: hours 1–7 without "sabah"/"gece" are afternoon hours,
    /// "akşam 8" is 20:00, "gece 11" is 23:00 but "gece 2" stays 02:00.
    static func afternoonHour(_ hour: Int, period: String?) -> Int {
        switch period {
        case "sabah", "sabahleyin": return hour
        case "öğle", "öğlen": return hour < 6 ? hour + 12 : hour
        case "öğleden sonra", "akşamüstü", "akşam": return hour < 12 ? hour + 12 : hour
        case "gece": return (7...11).contains(hour) ? hour + 12 : hour
        default: return (1...7).contains(hour) ? hour + 12 : hour
        }
    }

    /// What is left once the date and the command words are gone, with the speaker's casing
    /// ("Mehmet'le toplantı").
    private static func title(from task: String, original: String) -> String? {
        var title = task.lowercased(with: locale)
        for pattern in [
            addVerb,
            #"\b(?:takvim|ajanda)\p{L}*"#,
            #"\b(?:etkinlik|etkinliği|etkinliğini)\b"#,
            #"\b(?:lütfen|olarak|yeni)\b"#,
            #"^\s*bir\b"#,
        ] {
            title = title.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // "toplantıyı ekle" → "toplantı".
        for (object, noun) in [("toplantıyı", "toplantı"), ("randevuyu", "randevu"), ("görüşmeyi", "görüşme"), ("buluşmayı", "buluşma")] {
            title = title.replacingOccurrences(of: #"\b\#(object)\b"#, with: noun, options: .regularExpression)
        }
        let words = title.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return "Etkinlik" }
        let originalWords = original.replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace || ",.!?".contains($0) }).map(String.init)
        let restored = words.map { word in
            originalWords.first { $0.lowercased(with: locale) == word } ?? word
        }.joined(separator: " ")
        guard let first = restored.first else { return nil }
        let upper = first == "i" ? "İ" : String(first).uppercased(with: locale)
        return upper + restored.dropFirst()
    }

    private static let hourWords: [(String, Int)] = [
        ("on bir", 11), ("on iki", 12), ("bir", 1), ("iki", 2), ("üç", 3), ("dört", 4), ("beş", 5),
        ("altı", 6), ("yedi", 7), ("sekiz", 8), ("dokuz", 9), ("on", 10),
    ]

    private static func spelledHours(_ text: String) -> String {
        var out = text
        for (word, value) in hourWords {
            // "üçte", "dörtte", "birde", "ona", "üç buçukta".
            out = out.replacingOccurrences(
                of: #"\bsaat \#(word)(?:'?(de|da|te|ta|e|a|ye|ya))?\b"#,
                with: "saat \(value)'$1", options: .regularExpression
            )
        }
        return out.replacingOccurrences(of: "'(?=\\s|$)", with: "", options: .regularExpression)
    }

    private static func number(_ word: String) -> Int? {
        Int(word) ?? hourWords.first { $0.0 == word }?.1
    }

    /// Removes the first match and returns its first group.
    private static func take(_ pattern: String, from text: inout String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(match.range, in: text),
              let group = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[group])
        text.replaceSubrange(whole, with: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return value
    }

    private static func firstGroups(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
