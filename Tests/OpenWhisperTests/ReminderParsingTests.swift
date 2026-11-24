import XCTest
@testable import OpenWhisper

/// Reminder creation end to end without the UI: the rule parser first, then the Ollama
/// fallback's answer → date. The 24 November 2026 logs are the source of most phrasings:
/// "6 dakika sonrası için" went to Ollama, which answered "now", and the reminder fired at once.
final class ReminderParsingTests: XCTestCase {
    private let cal = Calendar.current
    /// Tuesday 24 November 2026, 20:57.
    private var now: Date { cal.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 20, minute: 57))! }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: Rule parser

    func testRelativeOffsetsAreParsedByRules() {
        let cases: [(String, Double, String)] = [
            ("6 dakika sonra hatırlatıcı oluştur", 6, "Hatırlatma"),
            ("6 dakika sonrası için hatırlatıcı oluştur.", 6, "Hatırlatma"),
            ("6 dakika sonrasına hatırlatıcı oluştur.", 6, "Hatırlatma"),
            ("Bugün saat 6 dakika sonrasına hatırlatıcı oluşturur.", 6, "Hatırlatma"),
            ("8 dakika sonra hatırlatıcı oluştur.", 8, "Hatırlatma"),
            ("10 dakika sonrasında suyu kapatmayı hatırlat", 10, "Suyu kapatmayı"),
            ("Bana 10 dakika sonra kahve içmeyi hatırlat", 10, "Kahve içmeyi"),
            ("Yirmi dakika sonra fırına bakmayı hatırlat", 20, "Fırına bakmayı"),
            ("2 saat sonra toplantıyı hatırlat", 120, "Toplantıyı"),
            ("Yarım saat sonra çayı hatırlat", 30, "Çayı"),
            ("1 saat 15 dakika sonra annemi aramayı hatırlat", 75, "Annemi aramayı"),
            ("7 dakikanın ardından çamaşırları asmamı hatırlat", 7, "Çamaşırları asmamı"),
            ("Yirmi dakika geçince fırını kontrol etmeyi hatırlat", 20, "Fırını kontrol etmeyi"),
            ("Yarım saat içinde annemi aramayı hatırlat", 30, "Annemi aramayı"),
        ]
        for (spoken, minutes, task) in cases {
            let parsed = TurkishDateParser.parse(spoken, now: now)
            XCTAssertNotNil(parsed, spoken)
            XCTAssertEqual(parsed.map { $0.fireDate.timeIntervalSince(now) / 60 }, minutes, spoken)
            XCTAssertEqual(parsed?.task, task, spoken)
        }
    }

    func testDayAndClockAreParsedByRules() {
        let cases: [(String, Date, String)] = [
            ("Yarın saat 17'de telefonu yıkamayı hatırlat", at(25, 17), "Telefonu yıkamayı"),
            ("Bugün saat 22'de ilacımı hatırlat", at(24, 22), "İlacımı"),
            ("Yarın kahvaltıyı hatırlat", at(25, 9), "Kahvaltıyı"),
            ("Perşembe öğlen 12 de toplantı için hatırlatıcı kur", at(26, 12), "Toplantı için"),
            ("Öbür gün akşam 8de faturayı ödemeyi hatırlat", at(26, 20), "Faturayı ödemeyi"),
            ("Yarın sabah 9 buçukta doktoru aramayı hatırlat", at(25, 9, 30), "Doktoru aramayı"),
            ("Yarın öğlen 2'de ilacı hatırlat", at(25, 14), "İlacı"),
            ("Yarın gece 11'de çöpü hatırlat", at(25, 23), "Çöpü"),
            ("Yarın gece 2'de alarmı hatırlat", at(25, 2), "Alarmı"),
            ("Cuma saat 17:45'te raporu hatırlat", at(27, 17, 45), "Raporu"),
        ]
        for (spoken, date, task) in cases {
            let parsed = TurkishDateParser.parse(spoken, now: now)
            XCTAssertEqual(parsed?.fireDate, date, spoken)
            XCTAssertEqual(parsed?.task, task, spoken)
        }
    }

    // MARK: Ollama answer → date

    func testOllamaAnswersBecomeFutureDates() {
        let cases: [(String, Date, String)] = [
            (#"{"task": "", "minutes": 6, "hours": 0, "day": "", "time": ""}"#, now.addingTimeInterval(360), "Hatırlatma"),
            (#"{"task": "çamaşırları as", "minutes": 7, "hours": 0, "day": "", "time": ""}"#, now.addingTimeInterval(420), "çamaşırları as"),
            (#"{"task": "annemi ara", "minutes": 0, "hours": 0.5, "day": "", "time": ""}"#, now.addingTimeInterval(1800), "annemi ara"),
            (#"{"task": "toplantı", "minutes": 0, "hours": 0, "day": "thursday", "time": "12:00"}"#, at(26, 12), "toplantı"),
            (#"{"task": "spor", "minutes": 0, "hours": 0, "day": "tuesday", "time": ""}"#, at(1, 9, month: 12), "spor"),
            (#"{"task": "fatura", "minutes": 0, "hours": 0, "day": "tomorrow", "time": "8:30"}"#, at(25, 8, 30), "fatura"),
            (#"{"task": "çöp", "minutes": 0, "hours": 0, "day": "day_after_tomorrow", "time": ""}"#, at(26, 9), "çöp"),
            // Numbers as strings and code fences still parse.
            ("```json\n{\"task\": \"x\", \"minutes\": \"15\", \"hours\": \"0\", \"day\": \"\", \"time\": \"\"}\n```", now.addingTimeInterval(900), "x"),
        ]
        for (answer, date, task) in cases {
            let parsed = ReminderManager.reminder(fromOllama: answer, spoken: "", now: now, calendar: cal)
            XCTAssertEqual(parsed?.fireDate, date, answer)
            XCTAssertEqual(parsed?.task, task, answer)
        }
    }

    /// Misreads gemma4 e2b made in live runs: the spoken length and the clock time win.
    func testModelMisreadsAreCorrectedFromTheSentence() {
        let cases: [(String, String, Date)] = [
            ("yarım saat içinde annemi aramam lazım hatırlat",
             #"{"time": "", "day": "", "minutes": 0.5, "hours": 0, "task": "Annemi ara"}"#, now.addingTimeInterval(1800)),
            ("çeyrek saat kadar sonra kapıya bakmamı söyle",
             #"{"time": "", "day": "", "minutes": 0.25, "hours": 0, "task": "kapıya bak"}"#, now.addingTimeInterval(900)),
            ("7 dakikanın ardından çamaşırları asmamı hatırlat",
             #"{"task": "çamaşırları as", "minutes": 420, "hours": 0, "day": "", "time": ""}"#, now.addingTimeInterval(420)),
            ("Bugün saat 6 dakika sonrasına hatırlatıcı oluşturur.",
             #"{"hours": 0, "day": "today", "time": "06:00", "task": "", "minutes": 6}"#, now.addingTimeInterval(360)),
            ("perşembe öğlen 12 de toplantı için hatırlatıcı kur",
             #"{"task": "toplantı", "minutes": 0, "day": "thursday", "hours": 12, "time": "12:00"}"#, at(26, 12)),
            ("yarın sabah 9 buçukta doktoru aramayı hatırlat",
             #"{"task": "doktoru ara", "minutes": 0, "day": "tomorrow", "hours": 9, "time": "09:30"}"#, at(25, 9, 30)),
        ]
        for (spoken, answer, date) in cases {
            XCTAssertEqual(ReminderManager.reminder(fromOllama: answer, spoken: spoken, now: now, calendar: cal)?.fireDate,
                           date, spoken)
        }
    }

    func testOllamaAnswersWithoutAFutureTimeAreRefused() {
        for answer in [
            #"{"task": "x", "minutes": 0, "hours": 0, "day": "", "time": "20:57"}"#,   // "now": the old bug
            #"{"task": "x", "minutes": 0, "hours": 0, "day": "today", "time": "06:00"}"#,
            #"{"task": "x", "minutes": 0, "hours": 0, "day": "", "time": ""}"#,
            #"{"task": "x", "minutes": 0, "hours": 0, "day": "", "time": "25:00"}"#,
            #"{"task": "x", "minutes": 0, "hours": 0, "day": "someday", "time": ""}"#,
            #"{"task": "x", "minutes": 0.5, "hours": 0, "day": "", "time": ""}"#,  // no length in the sentence to check
            "bilmiyorum",
        ] {
            XCTAssertNil(ReminderManager.reminder(fromOllama: answer, spoken: "", now: now, calendar: cal), answer)
        }
    }

    // MARK: Live Ollama (opt-in: JARVIS_LIVE_REMINDER_TEST=1, Ollama running)

    /// The fallback model alone, on real phrasings (the rule parser normally answers most
    /// of these first): each must land on the right time, or be refused, never a wrong time.
    /// Run after changing the prompt, the schema or the Ollama model.
    func testLiveOllamaReadsReminderTimes() async throws {
        guard ProcessInfo.processInfo.environment["JARVIS_LIVE_REMINDER_TEST"] == "1" else {
            throw XCTSkip("Live Ollama is opt-in")
        }
        let model = UserDefaults.standard.string(forKey: "ollamaModel") ?? LLMCleanup.defaultModel
        let live = Date()
        func later(_ minutes: Double) -> Date { live.addingTimeInterval(minutes * 60) }
        func day(_ ahead: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            var c = cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: ahead, to: live)!)
            c.hour = hour; c.minute = minute
            return cal.date(from: c)!
        }
        func daysUntil(_ weekday: Int) -> Int {
            let diff = (weekday - cal.component(.weekday, from: live) + 7) % 7
            return diff == 0 ? 7 : diff
        }
        let cases: [(String, Date)] = [
            ("6 dakika sonrası için hatırlatıcı oluştur.", later(6)),
            ("Bugün saat 6 dakika sonrasına hatırlatıcı oluşturur.", later(6)),
            ("7 dakikanın ardından çamaşırları asmamı hatırlat", later(7)),
            ("yirmi dakika geçince fırını kontrol etmeyi hatırlat", later(20)),
            ("yarım saat içinde annemi aramam lazım hatırlat", later(30)),
            ("iki saat geçince ilacımı hatırlat", later(120)),
            ("çeyrek saat kadar sonra kapıya bakmamı söyle bana hatırlatıcı olarak", later(15)),
            ("perşembe öğlen 12 de toplantı için hatırlatıcı kur", day(daysUntil(5), 12)),
            ("öbür gün akşam 8de faturayı ödemeyi hatırlat", day(2, 20)),
            ("yarın sabah 9 buçukta doktoru aramayı hatırlat", day(1, 9, 30)),
        ]
        var failures: [String] = []
        // Three rounds: a model that is right only sometimes still fails.
        for _ in 0..<3 {
            for (spoken, expected) in cases {
                let answer = try await LLM.default.generate(ReminderManager.ollamaRequest(text: spoken, model: model))
                let parsed = ReminderManager.reminder(fromOllama: answer, spoken: spoken, now: live, calendar: cal)
                if parsed.map({ abs($0.fireDate.timeIntervalSince(expected)) < 1 }) != true {
                    failures.append("\(spoken) → \(answer)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "Model misread:\n" + failures.joined(separator: "\n"))
    }
}
