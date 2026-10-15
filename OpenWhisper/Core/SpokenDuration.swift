import Foundation

/// Spoken Turkish lengths of time: "10 dakika", "yarım saat", "çeyrek saat", "bir buçuk saat",
/// "1,5 saat", "2 saat 15 dakika", "otuz saniye", "yirmi beş dakika". Shared by reminders
/// ("… sonra hatırlat") and timers ("20 dakikalık alarm"). Expects Turkish-lowercased text.
enum SpokenDuration {
    struct Match: Equatable {
        let seconds: Int
        let range: Range<String.Index>
    }

    private static let ones: [String: Int] = [
        "bir": 1, "iki": 2, "üç": 3, "uc": 3, "dört": 4, "dort": 4, "beş": 5, "bes": 5,
        "altı": 6, "alti": 6, "yedi": 7, "sekiz": 8, "dokuz": 9
    ]
    private static let tens: [String: Int] = [
        "on": 10, "yirmi": 20, "otuz": 30, "kırk": 40, "kirk": 40, "elli": 50,
        "altmış": 60, "altmis": 60, "yetmiş": 70, "yetmis": 70, "seksen": 80, "doksan": 90
    ]

    /// A number written with digits ("1,5" too) or words ("yirmi beş").
    static let number: String = {
        let words = (tens.keys.sorted { $0.count > $1.count }.map { "\($0)(?:\\s+(?:\(onesAlternation)))?" })
            + [onesAlternation]
        return "(?:\\d+(?:[.,]\\d+)?|" + words.joined(separator: "|") + ")"
    }()
    private static let onesAlternation = ones.keys.sorted { $0.count > $1.count }.joined(separator: "|")

    /// "dakika", "dakikalık", "dakikaya", "dk"; the suffix is left to the caller's pattern.
    private static let unitStems = #"(saat|dakika|dk|saniye|sn)"#

    static func value(_ spoken: String) -> Double? {
        let text = spoken.trimmingCharacters(in: .whitespaces)
        if let n = Double(text.replacingOccurrences(of: ",", with: ".")) { return n }
        let parts = text.split(separator: " ").map(String.init)
        if parts.count == 1 { return (tens[parts[0]] ?? ones[parts[0]]).map(Double.init) }
        if parts.count == 2, let t = tens[parts[0]], let o = ones[parts[1]] { return Double(t + o) }
        return nil
    }

    private static func unitSeconds(_ stem: String) -> Double {
        switch stem {
        case "saat": return 3600
        case "dakika", "dk": return 60
        default: return 1
        }
    }

    /// The first spoken length in `text`, followed by whatever `suffix` (a regex) requires,
    /// e.g. `\s+sonra\b` or `l[ıiuü]k\b`. The range covers the suffix too.
    static func first(in text: String, suffix: String = "") -> Match? {
        let n = number
        // Longest forms first so "1 saat 15 dakika" isn't read as "1 saat".
        let patterns: [(String, ([String?]) -> Double?)] = [
            // "2 saat 15 dakika", "bir saat yirmi dakika"
            ("\\b(\(n))\\s*saat\\s+(\(n))\\s*(?:dakika|dk)", { g in
                guard let h = g[0].flatMap(value), let m = g[1].flatMap(value) else { return nil }
                return h * 3600 + m * 60
            }),
            // "bir buçuk saat", "2 buçuk dakika"
            ("\\b(\(n))\\s+buçuk\\s*\(unitStems)", { g in
                guard let v = g[0].flatMap(value), let unit = g[1] else { return nil }
                return (v + 0.5) * unitSeconds(unit)
            }),
            // "yarım saat", "çeyrek saat", "yarım dakika"
            ("\\b(yarım|yarim|çeyrek|ceyrek)\\s*\(unitStems)", { g in
                guard let word = g[0], let unit = g[1] else { return nil }
                return (word.hasPrefix("y") ? 0.5 : 0.25) * unitSeconds(unit)
            }),
            // "10 dakika", "1,5 saat", "otuz saniye", "20dk"
            ("\\b(\(n))\\s*\(unitStems)", { g in
                guard let v = g[0].flatMap(value), let unit = g[1] else { return nil }
                return v * unitSeconds(unit)
            })
        ]
        var best: Match?
        for (body, compute) in patterns {
            // The unit's own suffix ("dakikalık", "saatlik") sits between the unit and `suffix`.
            let pattern = body + "\\p{L}*" + suffix
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(m.range, in: text) else { continue }
            let groups = (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } }
            guard let seconds = compute(groups), seconds >= 1 else { continue }
            // Prefer the earliest match; at the same start, the longer (earlier-listed) form.
            if best == nil || range.lowerBound < best!.range.lowerBound {
                best = Match(seconds: Int(seconds.rounded()), range: range)
            }
        }
        return best
    }

    /// Whisper hears "yarım saat" as "20 saat" ("20 saat sonra çay için haber ver", voice
    /// test 2026-10-15). Twenty hours is almost never what a timer or reminder means, so only
    /// that exact length, right before "sonra" / "-lik", is read as half an hour.
    static func repairMishearing(_ lowered: String) -> String {
        lowered.replacingOccurrences(of: #"\b(?:20|yirmi)\s*saat(?=\s+sonra\b|l[ıi]k\b)"#, with: "yarım saat", options: .regularExpression)
    }

    /// "20 dakika", "1 saat 30 dakika", "yarım saat", "45 saniye" — for spoken replies.
    static func spoken(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) saniye" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600 + 30) / 60
        if hours == 0 { return minutes == 30 ? "yarım saat" : "\(minutes) dakika" }
        if minutes == 0 { return "\(hours) saat" }
        if minutes == 30 { return "\(hours) buçuk saat" }
        return "\(hours) saat \(minutes) dakika"
    }
}
