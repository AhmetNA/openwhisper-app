import Foundation

/// Every chat with Jarvis, dated, in `jarvis_journal.jsonl` ("geçen hafta ne demiştim?").
/// Unlike `UserMemory` it never goes into an ordinary chat prompt: the file is only read when
/// the user asks about a past time (`TimeQuery`), and then only that time's lines are handed
/// to the model, so everyday replies stay as short and fast as before. Dictation is never
/// written here; it belongs to the app it was typed into.
@MainActor
final class JarvisJournal {
    static let shared = JarvisJournal()

    struct Entry: Codable, Equatable {
        var date: Date
        var user: String
        var reply: String?
    }

    /// Older lines are dropped the next time the file is read.
    private static let keepDays = 90
    private static let maxReplyLength = 200
    private let url: URL?

    init(url: URL? = JarvisJournal.defaultURL) {
        self.url = url
    }

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenWhisper/jarvis_journal.jsonl")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// One appended line; the file is not read.
    func append(user: String, reply: String?, now: Date = Date()) {
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url, !user.isEmpty else { return }
        let reply = reply.map { String($0.prefix(Self.maxReplyLength)) }.flatMap { $0.isEmpty ? nil : $0 }
        guard var line = try? Self.encoder.encode(Entry(date: now, user: user, reply: reply)) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// Entries inside `interval`, oldest first. Drops lines older than `keepDays` from the file.
    func entries(in interval: DateInterval, now: Date = Date()) -> [Entry] {
        let all = load()
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        let kept = all.filter { $0.date >= cutoff }
        if kept.count != all.count { rewrite(kept) }
        return kept.filter { interval.contains($0.date) }
    }

    /// Lines for the chat prompt: the journal and the remembered facts of that time, at most
    /// `budget` characters (the newest win), so the model's context never overflows.
    func recall(_ query: TimeQuery, facts: [UserMemory.Fact], now: Date = Date(), budget: Int = 1500) -> [String] {
        Self.recallLines(entries: entries(in: query.interval, now: now), facts: facts, in: query.interval, budget: budget)
    }

    nonisolated static func recallLines(entries: [Entry], facts: [UserMemory.Fact], in interval: DateInterval, budget: Int) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM EEEE HH:mm"
        var dated: [(Date, String)] = entries.map { entry in
            let reply = entry.reply.map { " / Sen: \($0.prefix(80))" } ?? ""
            return (entry.date, "\(formatter.string(from: entry.date)) — Kullanıcı: \(entry.user)\(reply)")
        }
        dated += facts.filter { interval.contains($0.saved) }.map { fact in
            (fact.saved, "\(formatter.string(from: fact.saved)) — Hatırlamanı istedi: \(fact.text)")
        }
        var lines = dated.sorted { $0.0 < $1.0 }.map(\.1)
        while lines.count > 1, lines.reduce(0, { $0 + $1.count + 3 }) > budget { lines.removeFirst() }
        return lines
    }

    private func load() -> [Entry] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    private func rewrite(_ entries: [Entry]) {
        guard let url else { return }
        var data = Data()
        for entry in entries {
            guard let line = try? Self.encoder.encode(entry) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
        owLog("[Journal] Pruned to \(entries.count) entr(ies)")
    }
}

/// "Geçen hafta ne demiştim?", "dün ne konuşmuştuk?", "pazartesi sana ne sordum?": a past time
/// and a recall verb together. Either alone is something else ("dünkü toplantıyı sil",
/// "ne demiştin?"), so both are required.
struct TimeQuery: Equatable, Sendable {
    let interval: DateInterval
    /// How the reply names the time ("geçen hafta", "dün").
    let label: String

    nonisolated static func parse(_ text: String, now: Date = Date()) -> TimeQuery? {
        let locale = Locale(identifier: "tr_TR")
        let tokens = text.lowercased(with: locale)
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).inverted)
            .filter { !$0.isEmpty }
        let joined = " " + tokens.joined(separator: " ") + " "
        guard recallVerbs.contains(where: { joined.contains(" \($0) ") }) else { return nil }
        return range(in: joined, now: now)
    }

    /// Past forms only; "hatırlat" (reminders) and "unut" (memory) are not here.
    private static let recallVerbs = [
        "dedim", "demiştim", "dediğim", "dediklerim", "söyledim", "söylemiştim", "söylediğim", "söylediklerim",
        "konuştuk", "konuşmuştuk", "konuştuğumuz", "konuştuklarımız", "sordum", "sormuştum", "sorduğum",
        "anlattım", "anlatmıştım", "bahsettim", "bahsetmiştim", "bahsettiğim", "hatırlıyor", "hatırladın"
    ]

    private static let numberWords = ["bir": 1, "iki": 2, "üç": 3, "dört": 4, "beş": 5, "altı": 6, "yedi": 7, "sekiz": 8, "dokuz": 9, "on": 10]

    private static func range(in joined: String, now: Date) -> TimeQuery? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "tr_TR")
        calendar.timeZone = .current
        calendar.firstWeekday = 2  // Monday
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
        func days(_ from: Int, _ to: Int, _ label: String) -> TimeQuery {
            TimeQuery(interval: DateInterval(start: day(from), end: min(day(to), now)), label: label)
        }
        func has(_ phrase: String) -> Bool { joined.contains(" \(phrase) ") }
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)!.start
        let monthStart = calendar.dateInterval(of: .month, for: now)!.start

        // "3 gün önce", "iki hafta önce".
        if let match = joined.range(of: #" (\d+|bir|iki|üç|dört|beş|altı|yedi|sekiz|dokuz|on) (gün|hafta) önce"#, options: .regularExpression) {
            let parts = joined[match].split(separator: " ")
            let count = Int(parts[0]) ?? numberWords[String(parts[0])] ?? 1
            if parts[1] == "gün" { return days(-count, -count + 1, "\(count) gün önce") }
            let start = calendar.date(byAdding: .weekOfYear, value: -count, to: weekStart)!
            return TimeQuery(interval: DateInterval(start: start, end: calendar.date(byAdding: .weekOfYear, value: 1, to: start)!),
                             label: "\(count) hafta önce")
        }
        if has("dünden önceki gün") || has("evvelsi gün") || has("evvelki gün") || has("önceki gün") {
            return days(-2, -1, "önceki gün")
        }
        if has("dün") || has("dünkü") || has("dün akşam") { return days(-1, 0, "dün") }
        if has("bugün") || has("bugünkü") || has("bu sabah") || has("bu akşam") || has("bu öğlen") {
            return TimeQuery(interval: DateInterval(start: today, end: now), label: "bugün")
        }
        if has("geçen hafta") || has("geçen haftaki") || has("önceki hafta") {
            let start = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart)!
            return TimeQuery(interval: DateInterval(start: start, end: weekStart), label: "geçen hafta")
        }
        if has("bu hafta") || has("bu haftaki") {
            return TimeQuery(interval: DateInterval(start: weekStart, end: now), label: "bu hafta")
        }
        if has("geçen ay") || has("geçen ayki") || has("önceki ay") {
            let start = calendar.date(byAdding: .month, value: -1, to: monthStart)!
            return TimeQuery(interval: DateInterval(start: start, end: monthStart), label: "geçen ay")
        }
        if has("bu ay") || has("bu ayki") {
            return TimeQuery(interval: DateInterval(start: monthStart, end: now), label: "bu ay")
        }
        if has("geçenlerde") || has("son günlerde") || has("yakınlarda") || has("son zamanlarda") {
            return days(-14, 1, "son günlerde")
        }
        // "Pazartesi", "geçen salı", "cumaki": the last such day before today.
        let weekdays = ["pazartesi": 2, "salı": 3, "çarşamba": 4, "perşembe": 5, "cuma": 6, "cumartesi": 7, "pazar": 1]
        for (name, weekday) in weekdays where has(name) || has(name + "ki") || has(name + " günü") {
            let todayWeekday = calendar.component(.weekday, from: now)
            var back = (todayWeekday - weekday + 7) % 7
            if back == 0 { back = 7 }
            return days(-back, -back + 1, name)
        }
        return nil
    }
}
