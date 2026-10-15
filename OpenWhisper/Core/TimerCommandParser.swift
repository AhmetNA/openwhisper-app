import Foundation

/// Timer and alarm commands: "20 dakikalık alarm kur", "10 dakika sonra beni uyar",
/// "10 dakika sonra bana hatırlat" (nothing to remind of), "saat 7'de alarm kur",
/// "yarın sabah 7'de beni uyandır", "zamanlayıcı ne kadar kaldı", "alarmı iptal et",
/// and, while one is ringing, "tamam" / "5 dakika ertele". Pure, so it is unit-tested.
///
/// A reminder with a task ("15 dakika sonra toplantıyı hatırlat") is not a timer; it goes on
/// to `ReminderManager`, which also puts it in Apple Reminders.
enum TimerCommandParser {
    enum Command: Equatable {
        /// A countdown; `label` is what it is for ("çay"), if said.
        case start(seconds: Int, label: String?)
        /// A wall-clock alarm.
        case alarm(at: Date, label: String?)
        case remaining
        case cancel(all: Bool)
        /// While ringing: stop it.
        case stop
        /// While ringing: ring again in this many seconds.
        case snooze(seconds: Int)
    }

    static let defaultSnooze = 5 * 60
    private static let locale = Locale(identifier: "tr_TR")
    private static let maxWords = 14

    private static let timerNoun = #"(?:alarm|zamanlayıcı|zamanlayici|sayaç|sayac|geri sayım|timer)\p{L}*"#
    private static let startVerb = #"(?:kur|kurar mısın|kurabilir misin|kursana|başlat|başlatır mısın|ayarla|ayarlar mısın|koy|koyar mısın|aç|açar mısın)"#
    /// "beni uyar", "bana haber ver", "beni dürt", "alarm çal".
    private static let alertVerb = #"(?:(?:beni |bana )?(?:uyar|uyarır mısın|uyarabilir misin|uyarsana|haber ver|haber verir misin|seslen|dürt|ses ver)|alarm çal\p{L}*)"#
    private static let remindVerb = #"(?:bana |beni )?(?:hatırlat|hatırlatır mısın|hatırlatabilir misin|hatırlatsana)"#
    private static let wakeVerb = #"(?:beni )?(?:uyandır|uyandırır mısın|uyandırabilir misin|uyandırsana|kaldır)"#
    private static let tail = #"(?: lütfen)?$"#

    /// `ringing`: an alarm is sounding now. `active`: some timer is running, so a bare
    /// "ne kadar kaldı" is about it.
    static func parse(_ text: String, ringing: Bool = false, active: Bool = false,
                      now: Date = Date(), calendar: Calendar = .current) -> Command? {
        let t = normalize(text)
        guard !t.isEmpty, t.split(separator: " ").count <= maxWords else { return nil }

        if ringing, let command = parseWhileRinging(t) { return command }

        let asksRemaining = matches(t, #"\b(?:ne kadar|kaç dakika|kaç saniye|kaç saat) (?:süre )?kaldı\b|\bkalan süre"#)
        if asksRemaining, matches(t, #"\b(?:\#(timerNoun)|süre\p{L}*)"#)
            || active && matches(t, #"^(?:ne kadar|kaç dakika|kaç saniye|kaç saat) (?:süre )?kaldı$"#) {
            return .remaining
        }
        if matches(t, #"\b\#(timerNoun) (?:\p{L}+ )?(?:iptal et|iptal|kapat|sil|durdur|sustur|kaldır)\p{L}*\#(tail)"#) {
            return .cancel(all: matches(t, #"\b(?:tüm|bütün|hepsi\p{L}*|tümü\p{L}*)\b|(?:alarm|zamanlayıcı|sayaç)\p{L}*l[ae]r"#))
        }

        if let alarm = parseClockAlarm(t, now: now, calendar: calendar) { return alarm }
        return parseCountdown(t)
    }

    // MARK: - Countdown

    private static func parseCountdown(_ t: String) -> Command? {
        // "20 dakikalık alarm kur", "10 dakikalık çay alarmı kur", "10 dakikaya alarm kur"
        if let d = SpokenDuration.first(in: t, suffix: #"\s+(?:\p{L}+\s+)?\#(timerNoun)\s+\#(startVerb)\#(tail)"#) {
            return .start(seconds: d.seconds, label: label(between: t, after: d.range, before: timerNoun))
        }
        // "alarmı 10 dakikaya kur", "zamanlayıcıyı yarım saate ayarla"
        if matches(t, #"^\#(timerNoun) "#), let d = SpokenDuration.first(in: t, suffix: #"\s+\#(startVerb)\#(tail)"#) {
            return .start(seconds: d.seconds, label: nil)
        }
        // "10 dakika sonra beni uyar", "yarım saat sonra çay için haber ver",
        // "10 dakika sonra bana hatırlat" (no task: a reminder needs something to remind of)
        if let d = SpokenDuration.first(in: t, suffix: #"\s+sonra\b"#) {
            var rest = t
            rest.removeSubrange(d.range)
            rest = collapse(rest)
            if let m = firstGroups(#"^(.*?)\s*\#(alertVerb)\#(tail)"#, in: rest) {
                return .start(seconds: d.seconds, label: cleanLabel(m[0]))
            }
            if matches(rest, #"^\#(remindVerb)\#(tail)"#) {
                return .start(seconds: d.seconds, label: nil)
            }
            // "10 dakika sonra alarm kur"
            if matches(rest, #"^\#(timerNoun) \#(startVerb)\#(tail)"#) {
                return .start(seconds: d.seconds, label: nil)
            }
        }
        return nil
    }

    // MARK: - Clock alarm

    /// "saat 7'de alarm kur", "sabah 7'ye alarm kur", "yarın sabah 7 buçukta beni uyandır",
    /// "akşam 8'de beni uyar". Same rule as calendar events: 1–7 without "sabah" is the
    /// afternoon, except "uyandır", which means the morning; 8–11 is the next such hour.
    private static func parseClockAlarm(_ t: String, now: Date, calendar: Calendar) -> Command? {
        let isWake = matches(t, #"\b\#(wakeVerb)\#(tail)"#)
        let isAlarm = matches(t, #"\b\#(timerNoun) \#(startVerb)\#(tail)"#)
        let isAlert = matches(t, #"\b\#(alertVerb)\#(tail)"#)
        guard isWake || isAlarm || isAlert else { return nil }
        // A countdown ("10 dakika sonra …", "20 dakikalık …") is not a clock time.
        guard !matches(t, #"(?:saat|dakika|dk|saniye)\p{L}*\s+sonra|(?:saat|dakika|saniye)l[ıiuü]k"#) else { return nil }

        let spelled = spelledHours(t)
        guard let clock = firstGroups(#"\bsaat\s+(\d{1,2})(?:[:.](\d{2}))?"#, in: spelled)
                ?? firstGroups(#"\b(\d{1,2})(?:[:.](\d{2}))?\s*'?(?:ye|ya|de|da|te|ta|e|a)\b"#, in: spelled)
                ?? firstGroups(#"\b(\d{1,2})(?:[:.](\d{2}))?\s+(?:buçuk)\p{L}*"#, in: spelled).map({ [$0[0], "30"] }),
              var hour = Int(clock[0] ?? ""), hour <= 23 else { return nil }
        var minute = Int(clock[1] ?? "0") ?? 0
        if matches(spelled, #"\b\d{1,2}\s*buçu"#) { minute = 30 }
        guard minute <= 59 else { return nil }

        let evening = matches(t, #"\b(?:akşam|akşamüstü|gece|öğleden sonra|öğlen|öğle)\b"#)
        let morning = matches(t, #"\b(?:sabah|sabahleyin)\b"#)
        let tomorrow = matches(t, #"\byarın\b"#)
        let lateNight = matches(t, #"\bgece\b"#) && hour <= 4
        if hour < 12, !lateNight, evening || (!morning && !isWake && (1...7).contains(hour)) { hour += 12 }

        var comps = calendar.dateComponents([.year, .month, .day], from: now)
        comps.hour = hour
        comps.minute = minute
        guard var date = calendar.date(from: comps) else { return nil }
        if tomorrow {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        } else if !evening, !morning, !isWake, hour < 12, date <= now,
                  let afternoon = calendar.date(byAdding: .hour, value: 12, to: date), afternoon > now {
            // "saat 7'de alarm kur" at 15:00 means 19:00, not tomorrow morning.
            date = afternoon
        } else if date <= now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return .alarm(at: date, label: nil)
    }

    // MARK: - While ringing

    private static func parseWhileRinging(_ t: String) -> Command? {
        if matches(t, #"\bertele\p{L}*"#) {
            let d = SpokenDuration.first(in: t)
            return .snooze(seconds: d?.seconds ?? defaultSnooze)
        }
        let stopWords = #"(?:tamam|tamamdır|tamam tamam|tamam kapat|kapat|sus|sustur|durdur|yeter|anladım|teşekkürler|teşekkür ederim|sağ ol|sağol|okey|ok|kalktım|uyandım|geldim|tamam geldim)"#
        if matches(t, #"^(?:\#(stopWords))(?: \#(stopWords))*(?: jarvis)?(?: lütfen)?$"#)
            || matches(t, #"^\#(timerNoun) (?:kapat|sustur|durdur|iptal et)\p{L}*\#(tail)"#) {
            return .stop
        }
        return nil
    }

    // MARK: - Helpers

    static func normalize(_ text: String) -> String {
        var t = text.lowercased(with: locale)
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[,!?;"“”]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\.\s*$"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"^\s*(?:hey\s+)?(?:(?:jarvis|cervis|carvis|jarvıs|çarvis|jervis)\s+)?"#, with: "", options: .regularExpression)
        return collapse(t)
    }

    private static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// The word between the length and "alarm" in "10 dakikalık çay alarmı kur".
    private static func label(between t: String, after range: Range<String.Index>, before noun: String) -> String? {
        let segment = String(t[range])
        guard let m = firstGroups(#"l[ıiuü]k\s+(\p{L}+)\s+"# + noun, in: segment) else { return nil }
        return cleanLabel(m[0])
    }

    /// "çay için" → "çay"; filler and pronouns are no label.
    private static func cleanLabel(_ raw: String?) -> String? {
        guard var label = raw?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return nil }
        label = label.replacingOccurrences(of: #"\s+için$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:bana|beni|lütfen|bir)\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.split(separator: " ").count <= 4 else { return nil }
        return label
    }

    private static let hourWords: [(String, Int)] = [
        ("on iki", 12), ("on bir", 11), ("bir", 1), ("iki", 2), ("üç", 3), ("dört", 4), ("beş", 5),
        ("altı", 6), ("yedi", 7), ("sekiz", 8), ("dokuz", 9), ("on", 10)
    ]

    /// "saat yedide" → "saat 7'de", "sekize" → "8'e", "yedi buçukta" → "7 buçukta".
    private static func spelledHours(_ t: String) -> String {
        var out = t
        for (word, value) in hourWords {
            let stem = word.hasSuffix("ı") || word.hasSuffix("i") || word.hasSuffix("ü") ? String(word.dropLast()) : word
            out = out.replacingOccurrences(of: #"\bsaat \#(word)\b"#, with: "saat \(value)", options: .regularExpression)
            out = out.replacingOccurrences(of: #"\b\#(word)\s+buçu"#, with: "\(value) buçu", options: .regularExpression)
            // "on" and "bir" alone are too common with a case ending ("ona", "bire").
            guard word != "on", word != "bir" else { continue }
            out = out.replacingOccurrences(of: #"\b\#(stem)(?:[ıiuü]?(?:de|da|te|ta)|[ıiuü]?(?:ye|ya|e|a))\b"#, with: "\(value)'de", options: .regularExpression)
        }
        return out
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstGroups(_ pattern: String, in text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } }
    }
}
