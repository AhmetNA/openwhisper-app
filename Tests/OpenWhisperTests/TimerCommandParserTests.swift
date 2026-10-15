import XCTest
@testable import OpenWhisper

final class SpokenDurationTests: XCTestCase {
    private func seconds(_ text: String, suffix: String = "") -> Int? {
        SpokenDuration.first(in: text, suffix: suffix)?.seconds
    }

    func testLengths() {
        XCTAssertEqual(seconds("10 dakika"), 600)
        XCTAssertEqual(seconds("yarım saat"), 1800)
        XCTAssertEqual(seconds("çeyrek saat"), 900)
        XCTAssertEqual(seconds("bir buçuk saat"), 5400)
        XCTAssertEqual(seconds("1,5 saat"), 5400)
        XCTAssertEqual(seconds("2 saat 15 dakika"), 8100)
        XCTAssertEqual(seconds("bir saat yirmi dakika"), 4800)
        XCTAssertEqual(seconds("yirmi beş dakika"), 1500)
        XCTAssertEqual(seconds("otuz saniye"), 30)
        XCTAssertEqual(seconds("20 dakikalık", suffix: ""), 1200)
        XCTAssertNil(seconds("saat yedide"))
    }

    func testSpoken() {
        XCTAssertEqual(SpokenDuration.spoken(1200), "20 dakika")
        XCTAssertEqual(SpokenDuration.spoken(1800), "yarım saat")
        XCTAssertEqual(SpokenDuration.spoken(5400), "1 buçuk saat")
        XCTAssertEqual(SpokenDuration.spoken(8100), "2 saat 15 dakika")
        XCTAssertEqual(SpokenDuration.spoken(45), "45 saniye")
    }
}

final class TimerCommandParserTests: XCTestCase {
    private typealias C = TimerCommandParser.Command
    private let calendar = Calendar(identifier: .gregorian)
    /// Thursday 15 Oct 2026, 15:30.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 15, minute: 30))!

    private func parse(_ text: String, ringing: Bool = false, active: Bool = false) -> C? {
        TimerCommandParser.parse(text, ringing: ringing, active: active, now: now, calendar: calendar)
    }

    private func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testCountdowns() {
        XCTAssertEqual(parse("20 dakikalık alarm kur"), .start(seconds: 1200, label: nil))
        XCTAssertEqual(parse("Jarvis 20 dakikalık bir zamanlayıcı kur."), .start(seconds: 1200, label: nil))
        XCTAssertEqual(parse("Yarım saatlik zamanlayıcı başlat"), .start(seconds: 1800, label: nil))
        XCTAssertEqual(parse("10 dakikalık sayaç başlat"), .start(seconds: 600, label: nil))
        XCTAssertEqual(parse("10 dakikalık çay alarmı kur"), .start(seconds: 600, label: "çay"))
        XCTAssertEqual(parse("10 dakikaya alarm kur"), .start(seconds: 600, label: nil))
        XCTAssertEqual(parse("Alarmı 15 dakikaya kur"), .start(seconds: 900, label: nil))
        XCTAssertEqual(parse("10 dakika sonra beni uyar"), .start(seconds: 600, label: nil))
        XCTAssertEqual(parse("1 saat sonra bana haber ver"), .start(seconds: 3600, label: nil))
        XCTAssertEqual(parse("Bir buçuk saat sonra beni uyarır mısın?"), .start(seconds: 5400, label: nil))
        XCTAssertEqual(parse("Yarım saat sonra çay için beni uyar"), .start(seconds: 1800, label: "çay"))
        XCTAssertEqual(parse("10 dakika sonra bana hatırlat"), .start(seconds: 600, label: nil))
        XCTAssertEqual(parse("5 dakika sonra alarm kur"), .start(seconds: 300, label: nil))
    }

    func testRemindersWithATaskAreNotTimers() {
        XCTAssertNil(parse("15 dakika sonra toplantıyı hatırlat"))
        XCTAssertNil(parse("Beş dakika sonra ocağı kontrol etmemi hatırlat"))
        XCTAssertNil(parse("Yarın saat 3'te Mehmet'le toplantı ekle"))
    }

    func testClockAlarms() {
        // 7 at 15:30 without "sabah" is this evening.
        XCTAssertEqual(parse("Saat 7'de alarm kur"), .alarm(at: at(day: 15, 19), label: nil))
        XCTAssertEqual(parse("Sabah 7'ye alarm kur"), .alarm(at: at(day: 16, 7), label: nil))
        XCTAssertEqual(parse("Yarın sabah 7'de beni uyandır"), .alarm(at: at(day: 16, 7), label: nil))
        XCTAssertEqual(parse("Yarın sabah yedi buçukta beni uyandır"), .alarm(at: at(day: 16, 7, 30), label: nil))
        XCTAssertEqual(parse("Saat 7'de beni uyandır"), .alarm(at: at(day: 16, 7), label: nil))
        XCTAssertEqual(parse("Akşam 8'de beni uyar"), .alarm(at: at(day: 15, 20), label: nil))
        XCTAssertEqual(parse("Saat 16:45'te alarm kur"), .alarm(at: at(day: 15, 16, 45), label: nil))
        XCTAssertEqual(parse("Saat 14'te alarm kur"), .alarm(at: at(day: 16, 14), label: nil))
    }

    func testRemainingAndCancel() {
        XCTAssertEqual(parse("Zamanlayıcı ne kadar kaldı?"), .remaining)
        XCTAssertEqual(parse("Alarma kaç dakika kaldı"), .remaining)
        XCTAssertNil(parse("Ne kadar kaldı"))
        XCTAssertEqual(parse("Ne kadar kaldı", active: true), .remaining)
        XCTAssertEqual(parse("Alarmı iptal et"), .cancel(all: false))
        XCTAssertEqual(parse("Zamanlayıcıyı kapat"), .cancel(all: false))
        XCTAssertEqual(parse("Tüm alarmları iptal et"), .cancel(all: true))
        XCTAssertEqual(parse("Alarmları sil"), .cancel(all: true))
    }

    func testWhileRinging() {
        XCTAssertEqual(parse("Tamam", ringing: true), .stop)
        XCTAssertEqual(parse("Tamam Jarvis.", ringing: true), .stop)
        XCTAssertEqual(parse("Kapat", ringing: true), .stop)
        XCTAssertEqual(parse("Alarmı kapat", ringing: true), .stop)
        XCTAssertEqual(parse("Ertele", ringing: true), .snooze(seconds: 300))
        XCTAssertEqual(parse("10 dakika ertele", ringing: true), .snooze(seconds: 600))
        XCTAssertNil(parse("Tamam", ringing: false))
    }

    func testOrdinarySpeechIsNoCommand() {
        for text in ["Toplantı yarın saat üçte başlıyor", "Alarm sesi çok yüksek", "Saat 7'de geliyorum",
                     "10 dakika sonra çıkıyorum", "Bu zamanlayıcı çok güzel", "Yarım saattir bekliyorum",
                     "Beni uyar dedi ama uyarmadı", "Ona göre ayarla"] {
            XCTAssertNil(parse(text), text)
        }
    }
}

final class ReminderDurationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func minutes(_ text: String) -> Double? {
        TurkishDateParser.parse(text, now: now).map { $0.fireDate.timeIntervalSince(now) / 60 }
    }

    func testSpokenLengthsBeforeSonra() {
        XCTAssertEqual(minutes("Yarım saat sonra çayı hatırlat"), 30)
        XCTAssertEqual(minutes("Bir buçuk saat sonra fırını kapatmayı hatırlat"), 90)
        XCTAssertEqual(minutes("Çeyrek saat sonra annemi aramayı hatırlat"), 15)
        XCTAssertEqual(minutes("2 saat 15 dakika sonra ilacımı hatırlat"), 135)
        XCTAssertEqual(minutes("15 dakika sonra toplantıyı hatırlat"), 15)
        XCTAssertEqual(minutes("Yirmi dakika sonra çamaşırı hatırlat"), 20)
        XCTAssertEqual(TurkishDateParser.parse("Yarım saat sonra çayı hatırlat", now: now)?.task, "Çayı")
    }
}

final class TimerReplyTests: XCTestCase {
    private struct Zero: RandomNumberGenerator { mutating func next() -> UInt64 { .max } }

    func testRepliesSayTheTimeAndLength() {
        var reply = JarvisReply(rng: Zero())
        XCTAssertEqual(reply.reminder(at: "bugün 15:46"), "Not ettim, bugün 15:46 hatırlatırım.")
        XCTAssertEqual(reply.timerFired(label: nil, seconds: 1200), "Patron, 20 dakika doldu.")
        XCTAssertEqual(reply.timerFired(label: "çay", seconds: 600), "Patron, çay için süre doldu.")
        XCTAssertEqual(reply.timerFired(label: nil, seconds: nil), "Patron, alarm çalıyor.")
        XCTAssertEqual(TimerManager.spokenLeft(11 * 60 + 20), "12 dakika")
        XCTAssertEqual(TimerManager.spokenLeft(42), "42 saniye")
    }

    func testClockWording() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 15, minute: 30))!
        let later = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 15, minute: 51))!
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 7))!
        XCTAssertEqual(TimerManager.clock(later, now: now, calendar: calendar), "15:51")
        XCTAssertEqual(TimerManager.clock(later, now: now, sayDay: true, calendar: calendar), "bugün 15:51")
        XCTAssertEqual(TimerManager.clock(tomorrow, now: now, calendar: calendar), "yarın 07:00")
    }
}
