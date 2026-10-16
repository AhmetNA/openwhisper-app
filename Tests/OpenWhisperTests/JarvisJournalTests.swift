import XCTest
@testable import OpenWhisper

@MainActor
final class JarvisJournalTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 12, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    /// Friday 16 October 2026, 15:00.
    private var now: Date { date(16, 15) }

    func testParsesPastTimesWithARecallVerb() {
        let lastWeek = TimeQuery.parse("Geçen hafta ne demiştim?", now: now)
        XCTAssertEqual(lastWeek?.label, "geçen hafta")
        // The previous calendar week, Monday to Monday.
        XCTAssertEqual(lastWeek?.interval, DateInterval(start: date(5, 0), end: date(12, 0)))

        XCTAssertEqual(TimeQuery.parse("Hey Jarvis, dün ne konuşmuştuk", now: now)?.interval, DateInterval(start: date(15, 0), end: date(16, 0)))
        XCTAssertEqual(TimeQuery.parse("Bugün sana ne sordum?", now: now)?.interval, DateInterval(start: date(16, 0), end: now))
        XCTAssertEqual(TimeQuery.parse("Pazartesi ne söylemiştim", now: now)?.interval, DateInterval(start: date(12, 0), end: date(13, 0)))
        // On a Friday, "cuma" is last Friday.
        XCTAssertEqual(TimeQuery.parse("Cuma günü ne dedim", now: now)?.interval, DateInterval(start: date(9, 0), end: date(10, 0)))
        XCTAssertEqual(TimeQuery.parse("Cumartesi ne konuştuk", now: now)?.label, "cumartesi")
        XCTAssertEqual(TimeQuery.parse("3 gün önce ne demiştim", now: now)?.interval, DateInterval(start: date(13, 0), end: date(14, 0)))
        XCTAssertEqual(TimeQuery.parse("Geçen ay neler konuştuk", now: now)?.interval, DateInterval(start: date(1, 0, month: 9), end: date(1, 0)))
        XCTAssertEqual(TimeQuery.parse("Bu hafta ne konuştuk", now: now)?.interval, DateInterval(start: date(12, 0), end: now))
    }

    func testLeavesCommandsAndOtherTalkAlone() {
        XCTAssertNil(TimeQuery.parse("Dünkü toplantıyı sil", now: now))
        XCTAssertNil(TimeQuery.parse("Bana yarın 9'da toplantıyı hatırlat", now: now))
        XCTAssertNil(TimeQuery.parse("Geçen haftaki videoyu aç", now: now))
        XCTAssertNil(TimeQuery.parse("Ne dedin?", now: now))
        XCTAssertNil(TimeQuery.parse("Dünya ne demiştim", now: now))
    }

    func testAppendsReadsAndPrunes() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let journal = JarvisJournal(url: url)
        journal.append(user: "Çok eski", reply: nil, now: date(1, month: 6))
        journal.append(user: "Kara delik nedir?", reply: "Işığın bile kaçamadığı bir bölge.", now: date(8))
        journal.append(user: "Dün ne yesem?", reply: "Mercimek çorbası.", now: date(15))

        let lastWeek = TimeQuery.parse("geçen hafta ne konuştuk", now: now)!
        XCTAssertEqual(journal.entries(in: lastWeek.interval, now: now).map(\.user), ["Kara delik nedir?"])
        // The June line went out of the file on that read.
        let lines = try! String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)

        let fact = UserMemory.Fact(text: "kahveyi şekersiz içiyorum", saved: date(7))
        let recalled = journal.recall(lastWeek, facts: [fact], now: now)
        XCTAssertEqual(recalled.count, 2)
        XCTAssertTrue(recalled[0].contains("Hatırlamanı istedi: kahveyi şekersiz içiyorum"))
        XCTAssertTrue(recalled[1].contains("Kullanıcı: Kara delik nedir? / Sen: Işığın"))
    }

    func testRecallKeepsTheNewestWithinBudget() {
        let interval = DateInterval(start: date(1), end: now)
        let entries = (1...40).map { JarvisJournal.Entry(date: date(1).addingTimeInterval(Double($0) * 3600), user: "Soru \($0) " + String(repeating: "x", count: 60), reply: nil) }
        let lines = JarvisJournal.recallLines(entries: entries, facts: [], in: interval, budget: 500)
        XCTAssertLessThanOrEqual(lines.reduce(0) { $0 + $1.count + 3 }, 500)
        XCTAssertTrue(lines.last!.contains("Soru 40 "))
    }

    func testOrdinaryPromptHasNoJournal() {
        let plain = JarvisChat.systemPrompt(now: now, userFacts: ["16 Ekim 2026: kahveyi şekersiz içiyorum"])
        XCTAssertFalse(plain.contains("konuşma kayıtların"))
        let asked = JarvisChat.systemPrompt(now: now, recalled: ["8 Ekim — Kullanıcı: Kara delik nedir?"])
        XCTAssertTrue(asked.contains("konuşma kayıtların"))
        XCTAssertTrue(asked.contains("- 8 Ekim — Kullanıcı: Kara delik nedir?"))
    }

    func testFactsCarryTheirDate() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let memory = UserMemory(url: url)
        memory.remember("kahveyi şekersiz içiyorum", now: date(12))
        memory.remember(UserMemory.namePrefix + "Ahmet", now: date(13))
        XCTAssertEqual(memory.promptLines, ["12 Ekim 2026: kahveyi şekersiz içiyorum", UserMemory.namePrefix + "Ahmet"])
    }
}
