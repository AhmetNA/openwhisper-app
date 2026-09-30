import XCTest
@testable import OpenWhisper

final class CalendarAndBrowserCommandTests: XCTestCase {
    private let calendar = Calendar.current
    /// Wednesday 30 September 2026, 10:00.
    private lazy var now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 10))!

    private func event(_ text: String) -> CalendarEventParser.Event? {
        guard case .calendarEvent(let event) = SystemCommandParser.parse(text, now: now) else { return nil }
        return event
    }

    private func date(day: Int, hour: Int = 0, minute: Int = 0, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Calendar

    func testMeetingTomorrowAfternoon() {
        let e = event("Yarın saat 3'te Mehmet'le toplantı ekle.")
        XCTAssertEqual(e?.title, "Mehmet'le toplantı")
        XCTAssertEqual(e?.start, date(day: 1, hour: 15, month: 10))
        XCTAssertEqual(e?.allDay, false)
        XCTAssertEqual(e?.minutes, 60)
    }

    func testClockFormsAndPeriods() {
        XCTAssertEqual(event("Hey Jarvis, yarın 15:30'da dişçi randevusu ekle")?.start, date(day: 1, hour: 15, minute: 30, month: 10))
        XCTAssertEqual(event("Yarın sabah 9'da toplantı ekle")?.start, date(day: 1, hour: 9, month: 10))
        XCTAssertEqual(event("Cuma akşam 8'de yemek takvime ekle")?.start, date(day: 2, hour: 20, month: 10))
        XCTAssertEqual(event("Cuma akşam 8'de yemek takvime ekle")?.title, "Yemek")
        XCTAssertEqual(event("Yarın saat üçte toplantı ekle")?.start, date(day: 1, hour: 15, month: 10))
        XCTAssertEqual(event("Yarın 3 buçukta görüşme ayarla")?.start, date(day: 1, hour: 15, minute: 30, month: 10))
        XCTAssertEqual(event("Yarın saat 3’te toplantı ekle")?.start, date(day: 1, hour: 15, month: 10))
    }

    func testTimeWithoutDay() {
        // 15:00 is still ahead today; 09:00 has passed, so it is tomorrow's.
        XCTAssertEqual(event("Saat 3'te toplantı ekle")?.start, date(day: 30, hour: 15))
        XCTAssertEqual(event("Sabah 9'da toplantı ekle")?.start, date(day: 1, hour: 9, month: 10))
    }

    func testAllDayAndLength() {
        let allDay = event("Pazartesi Ayşe'nin doğum günü etkinliği oluştur")
        XCTAssertEqual(allDay?.allDay, true)
        XCTAssertEqual(allDay?.start, date(day: 5, month: 10))
        XCTAssertEqual(allDay?.title, "Ayşe'nin doğum günü")
        // "bugün" without a time stays today even after 09:00.
        XCTAssertEqual(event("Bugün takvime tatil ekle")?.start, date(day: 30))
        XCTAssertEqual(event("Yarın 2'de iki saatlik toplantı ekle")?.minutes, 120)
        XCTAssertEqual(event("Yarın 2'de yarım saatlik görüşme ekle")?.minutes, 30)
        XCTAssertEqual(event("Yarın 2'de yarım saatlik görüşme ekle")?.title, "Görüşme")
        XCTAssertEqual(event("Yarın 3'te toplantıyı takvime koy")?.title, "Toplantı")
    }

    func testNotEvents() {
        // Dictation, reminders and the briefing keep their routes.
        XCTAssertNil(event("Toplantı yarın saat üçte"))
        XCTAssertNil(SystemCommandParser.parse("Yarın toplantıyı hatırlat ekle", now: now))
        XCTAssertNil(event("Yarın saat 3'te toplantıyı bana hatırlat"))
        XCTAssertEqual(SystemCommandParser.parse("Takvimimde ne var", now: now), .briefing(dayOffset: 0))
        XCTAssertNil(event("Takvime toplantı ekle"))
        XCTAssertNil(event("Yarın 3'te toplantı koy"))
        XCTAssertNil(event("Yarın saat 27'de toplantı ekle"))
        XCTAssertNil(event("Yarın saat 3'te toplantı yaz"))
    }

    func testCalendarReply() {
        var reply = JarvisReply()
        reply.addressChance = 0
        let e = event("Yarın saat 3'te Mehmet'le toplantı ekle")!
        XCTAssertEqual(CalendarController.when(e, now: now), "yarın 15:00")
        XCTAssertEqual(reply.system(.calendarEvent(e), status: "Takvime eklendi: Mehmet'le toplantı, yarın 15:00"),
                       "Takvime ekledim: Mehmet'le toplantı, yarın 15:00.")
        XCTAssertEqual(reply.system(.calendarEvent(e), status: "Takvim izni yok"), "Maalesef, takvim izni yok.")
    }

    // MARK: - Safari

    func testSearches() {
        XCTAssertEqual(SystemCommandParser.parse("YouTube'da lofi hip hop ara."), .browser(.search(.youtube, "lofi hip hop")))
        XCTAssertEqual(SystemCommandParser.parse("Hey Jarvis, lofi'yi YouTube'da aç"), .browser(.search(.youtube, "lofi")))
        XCTAssertEqual(SystemCommandParser.parse("Google'da İstanbul hava durumu ara"), .browser(.search(.google, "istanbul hava durumu")))
        XCTAssertEqual(SystemCommandParser.parse("İnternette kara delik nedir diye ara"), .browser(.search(.google, "kara delik nedir")))
        XCTAssertEqual(SystemCommandParser.parse("Kara delik nedir google'la"), .browser(.search(.google, "kara delik nedir")))
        XCTAssertNil(SystemCommandParser.parse("Ahmet'i ara"))
        XCTAssertEqual(
            BrowserController.searchURL(.google, "a&b=c + d")?.absoluteString,
            "https://www.google.com/search?q=a%26b%3Dc%20%2B%20d"
        )
    }

    func testSites() {
        XCTAssertEqual(SystemCommandParser.parse("github.com'u aç"), .browser(.open("https://github.com")))
        XCTAssertEqual(SystemCommandParser.parse("GitHub sitesini aç"), .browser(.open("https://github.com")))
        XCTAssertEqual(SystemCommandParser.parse("Ekşi Sözlük sitesine git"), .browser(.open("https://eksisozluk.com")))
        XCTAssertEqual(SystemCommandParser.parse("Safari'yi kapat", installedApps: ["Safari"]), .quitApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("Safari'yi aç", installedApps: ["Safari"]), .openApp("Safari"))
    }

    func testTabs() {
        XCTAssertEqual(SystemCommandParser.parse("Yeni sekme aç"), .browser(.newTab))
        XCTAssertEqual(SystemCommandParser.parse("Safari'de yeni sekme aç"), .browser(.newTab))
        XCTAssertEqual(SystemCommandParser.parse("Sekmeyi kapat."), .browser(.closeTab))
        XCTAssertEqual(SystemCommandParser.parse("Sayfayı yenile"), .browser(.reload))
        XCTAssertEqual(SystemCommandParser.parse("Geri git"), .browser(.back))
        XCTAssertEqual(SystemCommandParser.parse("Önceki sayfaya dön"), .browser(.back))
        XCTAssertEqual(SystemCommandParser.parse("İleri git"), .browser(.forward))
        XCTAssertEqual(SystemCommandParser.parse("Sonraki sekmeye geç"), .browser(.nextTab))
        XCTAssertEqual(SystemCommandParser.parse("Önceki sekme"), .browser(.previousTab))
        XCTAssertEqual(SystemCommandParser.parse("Bu sayfayı özetle"), .browser(.summarize))
        XCTAssertEqual(SystemCommandParser.parse("Bu makale ne anlatıyor?"), .browser(.summarize))
        XCTAssertEqual(SystemCommandParser.parse("Sayfayı aşağı kaydır"), .scroll(up: false, large: false))
    }

    func testBrowserReply() {
        var reply = JarvisReply()
        reply.addressChance = 0
        let summary = "Sayfa yeni bir telefonu tanıtıyor. Kulaklık girişi yok. Fiyatı 999 dolar. Ekim'de satışa çıkacak."
        XCTAssertEqual(reply.system(.browser(.summarize), status: summary),
                       "Sayfa yeni bir telefonu tanıtıyor. Kulaklık girişi yok. Fiyatı 999 dolar.")
        XCTAssertEqual(reply.system(.browser(.summarize), status: BrowserController.summaryFailed), "Maalesef, sayfa özetlenemedi.")
        XCTAssertTrue(JarvisReply.acks.contains(reply.system(.browser(.search(.google, "yok")), status: "Google'da aranıyor: yok") ?? ""))
    }
}
