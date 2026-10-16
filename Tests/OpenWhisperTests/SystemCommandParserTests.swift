import XCTest
@testable import OpenWhisper

final class SystemCommandParserTests: XCTestCase {
    func testBluetooth() {
        XCTAssertEqual(SystemCommandParser.parse("Bluetooth'u kapat."), .bluetooth(on: false))
        XCTAssertEqual(SystemCommandParser.parse("Bluetooth'u aç"), .bluetooth(on: true))
        XCTAssertEqual(SystemCommandParser.parse("Blututu kapat"), .bluetooth(on: false))
        XCTAssertEqual(SystemCommandParser.parse("Blüttel kapat."), .bluetooth(on: false))
        XCTAssertEqual(SystemCommandParser.parse("Hey Jarvis bluetooth'u açar mısın"), .bluetooth(on: true))
    }

    func testWiFi() {
        XCTAssertEqual(SystemCommandParser.parse("Wi-Fi'yi kapat."), .wifi(on: false))
        XCTAssertEqual(SystemCommandParser.parse("Wifi'ı aç"), .wifi(on: true))
        XCTAssertEqual(SystemCommandParser.parse("İnterneti kapat"), .wifi(on: false))
        XCTAssertEqual(SystemCommandParser.parse("Vayfayı aç"), .wifi(on: true))
    }

    func testHeadset() {
        XCTAssertEqual(SystemCommandParser.parse("Kulaklığın bağlantısını kes."), .headset(connect: false))
        XCTAssertEqual(SystemCommandParser.parse("Kulaklıktan bağlantıyı kes"), .headset(connect: false))
        XCTAssertEqual(SystemCommandParser.parse("Kulaklığı bağla"), .headset(connect: true))
        XCTAssertEqual(SystemCommandParser.parse("Kulaklığı ayır"), .headset(connect: false))
    }

    func testDeveloperMode() {
        XCTAssertEqual(SystemCommandParser.parse("Dev modu aç."), .developerMode)
        XCTAssertEqual(SystemCommandParser.parse("Hey Jarvis, developer modunu aç."), .developerMode)
        XCTAssertEqual(SystemCommandParser.parse("Developer mode'u aç"), .developerMode)
        XCTAssertEqual(SystemCommandParser.parse("Geliştirici modunu başlat"), .developerMode)
        XCTAssertEqual(SystemCommandParser.parse("Developer moduna geç"), .developerMode)
        XCTAssertEqual(SystemCommandParser.parse("Jarvis dev modunu açar mısın?"), .developerMode)
        XCTAssertEqual(SystemCommandParser.parse("Devmodo Aç"), .developerMode)
        XCTAssertEqual(SystemCommandParser.parse("Devmodu aç."), .developerMode)
        XCTAssertEqual(SystemCommandParser.parse("Def modu aç"), .developerMode)
        XCTAssertEqual(SystemCommandParser.parse("Dev mod'u aç"), .developerMode)
        XCTAssertEqual(SystemCommandParser.parse("Dev mod aç"), .developerMode)
        XCTAssertNil(SystemCommandParser.parse("Developer modu açınca ne oluyor"))
        XCTAssertNil(SystemCommandParser.parse("Yarın dev modu açmayı düşünüyorum"))
        XCTAssertNil(SystemCommandParser.parse("Developer modu aç ve sonra bana bir mail yaz"))
        XCTAssertNil(SystemCommandParser.parse("Dev modu"))
        XCTAssertEqual(SystemCommandParser.parse("Karanlık modu aç"), .darkMode(on: true))
    }

    func testNotCommands() {
        XCTAssertNil(SystemCommandParser.parse("Şarkıyı durdur."))
        XCTAssertNil(SystemCommandParser.parse("Bluetooth"))
        XCTAssertNil(SystemCommandParser.parse("Wi-Fi şifresi neydi acaba bir bakar mısın bana söyle lütfen"))
        XCTAssertNil(SystemCommandParser.parse("Dün bluetooth kulaklığımı kapattım ama sonra tekrar açtım"))
    }

    private let apps = ["Safari", "Google Chrome", "Notes", "Visual Studio Code", "Spotify", "Calculator", "WhatsApp", "Terminal"]

    func testActions() {
        XCTAssertEqual(SystemCommandParser.parse("Parlaklığı artır."), .brightness(up: true, level: nil))
        XCTAssertEqual(SystemCommandParser.parse("Parlaklığı biraz azalt"), .brightness(up: false, level: nil))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı karart"), .brightness(up: false, level: nil))
        XCTAssertEqual(SystemCommandParser.parse("Parlaklığı yüzde 50 yap"), .brightness(up: true, level: 50))
        XCTAssertEqual(SystemCommandParser.parse("Karanlık modu aç"), .darkMode(on: true))
        XCTAssertEqual(SystemCommandParser.parse("Karanlık modu kapat"), .darkMode(on: false))
        XCTAssertEqual(SystemCommandParser.parse("Aydınlık moda geç"), .darkMode(on: false))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı aşağı kaydır"), .scroll(up: false, large: false))
        XCTAssertEqual(SystemCommandParser.parse("Sayfayı yukarı kaydır"), .scroll(up: true, large: false))
        XCTAssertEqual(SystemCommandParser.parse("Aşağı scroll"), .scroll(up: false, large: false))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı kaydır yukarı"), .scroll(up: true, large: false))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı aşşağı kaydır"), .scroll(up: false, large: false))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı baya bir yukarı kaydır"), .scroll(up: true, large: true))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı baya bir yukarı kaydırır"), .scroll(up: true, large: true))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı baya bir yukarı kaydı"), .scroll(up: true, large: true))
        XCTAssertEqual(SystemCommandParser.parse("Sayfayı çok aşağı kaydır"), .scroll(up: false, large: true))
        XCTAssertEqual(SystemCommandParser.parse("Epey yukarı scroll"), .scroll(up: true, large: true))
        XCTAssertNil(SystemCommandParser.parse("Yukarı kaydı"))
        XCTAssertNil(SystemCommandParser.parse("Ekranı aşağı kaydırmak istiyorum"))
        XCTAssertNil(SystemCommandParser.parse("Aşağıda güzel bir sayfa var"))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı kilitle."), .lockScreen)
        // 26 Sep 2026: Whisper heard "Ekranı kilitle" as "Ekranı kilitli".
        XCTAssertEqual(SystemCommandParser.parse("Ekranı kilitli."), .lockScreen)
        XCTAssertNil(SystemCommandParser.parse("Ekranım kilitli kaldı"))
        XCTAssertEqual(SystemCommandParser.parse("Arlaklığı%70 yapabilir misin?"), .brightness(up: true, level: 70))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı kapat"), .displaySleep)
        XCTAssertEqual(SystemCommandParser.parse("Bilgisayarı uyut"), .sleep)
        XCTAssertEqual(SystemCommandParser.parse("Ekran görüntüsü al"), .screenshot)
        XCTAssertEqual(SystemCommandParser.parse("Ekran koruyucuyu aç"), .screenSaver)
        XCTAssertEqual(SystemCommandParser.parse("Sessize al."), .mute(true))
        XCTAssertEqual(SystemCommandParser.parse("Sessizden çıkar"), .mute(false))
        XCTAssertEqual(SystemCommandParser.parse("Şarj kaç?"), .battery)
        XCTAssertEqual(SystemCommandParser.parse("Pil ne kadar kaldı"), .battery)
        XCTAssertEqual(SystemCommandParser.parse("Saat kaç?"), .time)
    }

    func testApps() {
        XCTAssertEqual(SystemCommandParser.parse("Safari'yi aç.", installedApps: apps), .openApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("Safariyi kapat", installedApps: apps), .quitApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("Chrome'u aç", installedApps: apps), .openApp("Google Chrome"))
        XCTAssertEqual(SystemCommandParser.parse("WhatsApp'ı kapat", installedApps: apps), .quitApp("WhatsApp"))
        XCTAssertEqual(SystemCommandParser.parse("Terminal uygulamasını aç", installedApps: apps), .openApp("Terminal"))
    }

    func testMisheardAppCommands() {
        // Whisper: case ending glued onto the verb, vowels misheard.
        XCTAssertEqual(SystemCommandParser.parse("Saferi Yaç", installedApps: apps), .openApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("Safer iyaç.", installedApps: apps), .openApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("Safari yaç", installedApps: apps), .openApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("Chrome uaç", installedApps: apps), .openApp("Google Chrome"))
        XCTAssertEqual(SystemCommandParser.parse("Saferi ykapat", installedApps: apps), .quitApp("Safari"))
        XCTAssertNil(SystemCommandParser.parse("Kapıyı aç", installedApps: apps))
        XCTAssertNil(SystemCommandParser.parse("Pencere yaç", installedApps: apps))
    }

    func testForceQuitApps() {
        XCTAssertEqual(SystemCommandParser.parse("Chrome'u zorla kapat", installedApps: apps), .forceQuitApp("Google Chrome"))
        XCTAssertEqual(SystemCommandParser.parse("Jarvis Safari'yi öldür", installedApps: apps), .forceQuitApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("WhatsApp'ı sonlandır", installedApps: apps), .forceQuitApp("WhatsApp"))
        XCTAssertEqual(SystemCommandParser.parse("Terminal uygulamasını zorla kapat", installedApps: apps), .forceQuitApp("Terminal"))
        XCTAssertEqual(SystemCommandParser.parse("Safari'yi kill et", installedApps: apps), .forceQuitApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("Safari'yi tamamen kapat", installedApps: apps), .forceQuitApp("Safari"))
        XCTAssertNil(SystemCommandParser.parse("Safari'yi zorla aç", installedApps: apps))
        XCTAssertNil(SystemCommandParser.parse("Spotify'ı öldür", installedApps: apps))
    }

    func testAppLookalikesStayWithOtherHandlers() {
        // Spotify, volume and songs belong to SpotifyManager.
        XCTAssertNil(SystemCommandParser.parse("Spotify'ı aç", installedApps: apps))
        XCTAssertNil(SystemCommandParser.parse("Şarkıyı aç", installedApps: apps))
        XCTAssertNil(SystemCommandParser.parse("Sesi aç", installedApps: apps))
        XCTAssertNil(SystemCommandParser.parse("Müziği kapat", installedApps: apps))
    }

    func testMail() {
        XCTAssertEqual(SystemCommandParser.parse("Kaç mail var?", installedApps: apps), .mailCount)
        XCTAssertEqual(SystemCommandParser.parse("Yeni mail var mı", installedApps: apps), .mailCount)
        XCTAssertEqual(SystemCommandParser.parse("Okunmamış kaç e-posta var", installedApps: apps), .mailCount)
        XCTAssertEqual(SystemCommandParser.parse("Son mail kimden?", installedApps: apps), .mailLatest)
        XCTAssertEqual(SystemCommandParser.parse("Son gelen maili söyle", installedApps: apps), .mailLatest)
        XCTAssertEqual(SystemCommandParser.parse("Maili aç.", installedApps: apps + ["Mail"]), .mailOpen)
        XCTAssertEqual(SystemCommandParser.parse("Son maili aç", installedApps: apps), .mailOpen)
        XCTAssertEqual(SystemCommandParser.parse("Mailleri kontrol et", installedApps: apps), .mailCheck)
        XCTAssertEqual(SystemCommandParser.parse("Okunmamış mailleri oku", installedApps: apps), .mailReadUnread)
        XCTAssertEqual(SystemCommandParser.parse("Tüm mailleri okundu işaretle", installedApps: apps), .mailMarkAllRead)
        XCTAssertEqual(SystemCommandParser.parse("Mail'i kapat", installedApps: apps + ["Mail"]), .quitApp("Mail"))
    }

    func testMailReadLatestAndSender() {
        XCTAssertEqual(SystemCommandParser.parse("Son maili oku", installedApps: apps), .mailReadLatest)
        XCTAssertEqual(SystemCommandParser.parse("Jarvis, son gelen maili okur musun?", installedApps: apps), .mailReadLatest)
        XCTAssertEqual(SystemCommandParser.parse("Son mail ne diyor?", installedApps: apps), .mailReadLatest)
        XCTAssertEqual(SystemCommandParser.parse("Ahmet'ten mail var mı?", installedApps: apps), .mailFrom("Ahmet"))
        XCTAssertEqual(SystemCommandParser.parse("Ayşe Yılmaz'dan gelen e-posta var mı", installedApps: apps), .mailFrom("Ayşe Yılmaz"))
        XCTAssertEqual(SystemCommandParser.parse("İremden mail geldi mi", installedApps: apps), .mailFrom("İrem"))
        XCTAssertEqual(SystemCommandParser.parse("Kimden mail var?", installedApps: apps), .mailLatest)
        XCTAssertEqual(SystemCommandParser.parse("Yeni mail var mı", installedApps: apps), .mailCount)
    }

    func testMailReplyDraft() {
        XCTAssertEqual(SystemCommandParser.parse("Son maile cevap yaz: Yarın saat 3 uygun, teşekkürler.", installedApps: apps),
                       .mailReplyDraft("Yarın saat 3 uygun, teşekkürler"))
        XCTAssertEqual(SystemCommandParser.parse("Jarvis maile kısa bir yanıt yaz tamam bakıyorum", installedApps: apps),
                       .mailReplyDraft("Tamam bakıyorum"))
        XCTAssertEqual(SystemCommandParser.parse("Toplantıya geliyorum diye son maile cevap ver.", installedApps: apps),
                       .mailReplyDraft("Toplantıya geliyorum"))
        XCTAssertEqual(SystemCommandParser.parse("Son maile cevap yaz", installedApps: apps), .mailReplyDraft(""))
        // Dictation that only talks about replying is no command.
        XCTAssertNil(SystemCommandParser.parse("Ona maile cevap yazacağımı söyledim", installedApps: apps))
        // A guessed rewrite must never become a draft.
        XCTAssertNil(CommandRewriter.safeSystemCommand("Son maile cevap yaz tamam", installedApps: apps))
    }

    func testMailSenderMatchAndBody() {
        XCTAssertTrue(MailController.senderMatches("Ahmet Yılmaz <ahmet@example.com>", name: "Ahmet"))
        XCTAssertTrue(MailController.senderMatches("Ayşe Işık <a@example.com>", name: "ayse isik"))
        XCTAssertTrue(MailController.senderMatches("\"YILMAZ, Ahmet\" <ay@example.com>", name: "Ahmet Yılmaz"))
        XCTAssertFalse(MailController.senderMatches("Mehmet Ahmetoğlu <m@example.com>", name: "Ali"))
        XCTAssertFalse(MailController.senderMatches("Ali Veli <ali@example.com>", name: "Ahmet"))
        XCTAssertEqual(MailController.readableBody("Merhaba,\n\nYarın uygun musun?\n\nOn Mon, Ada wrote:\n> eski"),
                       "Merhaba, Yarın uygun musun?")
        XCTAssertEqual(MailController.readableBody("Selam\n--\nİmza"), "Selam")
    }

    func testMailSenderName() {
        XCTAssertEqual(MailController.displayName("Ada Lovelace <ada@example.com>"), "Ada Lovelace")
        XCTAssertEqual(MailController.displayName("<ada@example.com>"), "ada@example.com")
        XCTAssertEqual(MailController.displayName("ada@example.com"), "ada@example.com")
    }

    private let shortcuts = ["Jarvis", "Wi-Fi ile Odak ve Uygulamaları Aç", "Run Shell Script", "Wi-Fi ile Sabah Özeti", "Anımsatıcıları Takvimle Eşitle"]

    func testShortcuts() {
        XCTAssertEqual(SystemCommandParser.parse("Wi-Fi ile Sabah Özeti kısayolunu çalıştır.", shortcuts: shortcuts), .runShortcut("Wi-Fi ile Sabah Özeti"))
        XCTAssertEqual(SystemCommandParser.parse("Wi-Fi ile odak ve uygulamaları aç kısayolunu çalıştır", shortcuts: shortcuts), .runShortcut("Wi-Fi ile Odak ve Uygulamaları Aç"))
        XCTAssertEqual(SystemCommandParser.parse("Anımsatıcıları takvimle eşitle kısayolunu başlat", shortcuts: shortcuts), .runShortcut("Anımsatıcıları Takvimle Eşitle"))
        XCTAssertEqual(SystemCommandParser.parse("Kısayol Run Shell Script'i çalıştır", shortcuts: shortcuts), .runShortcut("Run Shell Script"))
        XCTAssertEqual(SystemCommandParser.parse("Wi-Fi ile Sabah Özeti'ni çalıştır", shortcuts: shortcuts), .runShortcut("Wi-Fi ile Sabah Özeti"))
        // Unknown name: not a shortcut, and still no Wi-Fi command.
        XCTAssertNil(SystemCommandParser.parse("Hava durumu kısayolunu çalıştır", shortcuts: shortcuts))
        XCTAssertEqual(SystemCommandParser.parse("Wi-Fi'yi kapat", shortcuts: shortcuts), .wifi(on: false))
    }

    func testBriefing() {
        XCTAssertEqual(SystemCommandParser.parse("Bugün ne var?"), .briefing(dayOffset: 0))
        XCTAssertEqual(SystemCommandParser.parse("Bugün neyimiz var"), .briefing(dayOffset: 0))
        XCTAssertEqual(SystemCommandParser.parse("Programımız ne?"), .briefing(dayOffset: 0))
        XCTAssertEqual(SystemCommandParser.parse("Bugünkü programım ne"), .briefing(dayOffset: 0))
        XCTAssertEqual(SystemCommandParser.parse("Günün özeti"), .briefing(dayOffset: 0))
        XCTAssertEqual(SystemCommandParser.parse("Yarın neyimiz var?"), .briefing(dayOffset: 1))
        XCTAssertEqual(SystemCommandParser.parse("Yarınki planım ne"), .briefing(dayOffset: 1))
        XCTAssertNil(SystemCommandParser.parse("Bugün hava çok güzel"))
    }

    func testBriefingText() {
        let summary = DailyBriefing.Summary(
            title: "Bugün", events: ["Tüm gün: Tatil", "14:00 Toplantı"], reminders: ["Faturayı öde (gecikmiş)"],
            unreadMailCount: 2, mail: ["Ada: Rapor", "Ali: Selam"]
        )
        XCTAssertEqual(summary.headline, "Bugün: 2 etkinlik · 1 hatırlatıcı · 2 okunmamış mail — ilk: Tüm gün: Tatil")
        XCTAssertEqual(summary.body, "📅 Tüm gün: Tatil\n📅 14:00 Toplantı\n☑️ Faturayı öde (gecikmiş)\n✉️ 2 okunmamış: Ada: Rapor · Ali: Selam")
    }

    func testBrightnessNumberWords() {
        // Heard 25 Sep 2026 and pasted as dictation: Whisper wrote the number in words.
        XCTAssertEqual(SystemCommandParser.parse("parlaklığı yüzde yüz yap."), .brightness(up: true, level: 100))
        XCTAssertEqual(SystemCommandParser.parse("Parlaklığı yüzde elli yap"), .brightness(up: true, level: 50))
        XCTAssertEqual(SystemCommandParser.parse("Parlaklığı yüzde yetmiş beş yap"), .brightness(up: true, level: 75))
    }

    func testLeadingSentence() {
        XCTAssertEqual(AppState.leadingSentence(of: "Şarkıyı durdur. Neden. Var öyle, sulamam gerekiyor."), "Şarkıyı durdur.")
        XCTAssertNil(AppState.leadingSentence(of: "Şarkıyı durdur."))
        XCTAssertNil(AppState.leadingSentence(of: "Tamam. Şarkıyı durdur."))
        XCTAssertEqual(SystemCommandParser.parse(AppState.leadingSentence(of: "Ekranı kilitle. Sonra konuşuruz seninle.") ?? ""), .lockScreen)
    }

    func testBriefingSaysWhenCalendarIsUnreadable() {
        let summary = DailyBriefing.Summary(title: "Yarın", events: [], reminders: [], unreadMailCount: nil, mail: [], missingAccess: ["Takvim"])
        XCTAssertEqual(summary.headline, "Yarın: takvim izni yok")
        XCTAssertTrue(summary.body.contains("İzin yok: Takvim"))
    }
}

/// TEST-HATALARI 2026-09-27 #1: "toplantı" matched the "plan" root and read tomorrow's briefing.
final class BriefingParserRegressionTests: XCTestCase {
    private func parse(_ text: String) -> SystemCommand? {
        SystemCommandParser.parse(text, installedApps: [], shortcuts: [])
    }

    func testStatementsAboutTheDayAreNotBriefings() {
        for text in ["Toplantı yarın saat üçte başlıyor", "Toplantı yarın saat 3'te başlıyor",
                     "Yarın programcıyla görüşeceğim", "Bugün planlama yaptık", "Yarın takvimli bir iş var"] {
            XCTAssertNil(parse(text), text)
        }
    }

    func testDayQuestionsAreBriefings() {
        XCTAssertEqual(parse("Yarın planım ne"), .briefing(dayOffset: 1))
        XCTAssertEqual(parse("Bugün programımız ne"), .briefing(dayOffset: 0))
        XCTAssertEqual(parse("Yarın neyimiz var"), .briefing(dayOffset: 1))
    }
}

final class AppSwitchParserTests: XCTestCase {
    private let apps = ["Safari", "Spotify", "Claude", "Google Chrome", "Xcode", "Notes", "Music"]

    func testSwitchToInstalledApp() {
        XCTAssertEqual(SystemCommandParser.parse("Safari'ye geç", installedApps: apps), .switchToApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("Safariye geç.", installedApps: apps), .switchToApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("Hey Jarvis, Chrome'a geç", installedApps: apps), .switchToApp("Google Chrome"))
        XCTAssertEqual(SystemCommandParser.parse("Xcode uygulamasına geç", installedApps: apps), .switchToApp("Xcode"))
        XCTAssertEqual(SystemCommandParser.parse("Safari'ye geçer misin", installedApps: apps), .switchToApp("Safari"))
        XCTAssertEqual(SystemCommandParser.parse("Safari'ye dön", installedApps: apps), .switchToApp("Safari"))
        // "Spotify'ı aç" belongs to SpotifyManager; switching to its window does not.
        XCTAssertEqual(SystemCommandParser.parse("Spotify'a geç", installedApps: apps), .switchToApp("Spotify"))
    }

    func testSwitchToAgentApp() {
        XCTAssertEqual(SystemCommandParser.parse("Claude Code'a geç", installedApps: apps), .switchToAgent(.claudeCode))
        XCTAssertEqual(SystemCommandParser.parse("Cloud koda geç", installedApps: apps), .switchToAgent(.claudeCode))
        XCTAssertEqual(SystemCommandParser.parse("ChatGPT'ye geç", installedApps: apps), .switchToAgent(.chatGPT))
        XCTAssertEqual(SystemCommandParser.parse("Codex'e geç", installedApps: apps), .switchToAgent(.codex))
        // Whisper's glued spellings from the 2026-10-15 voice test.
        XCTAssertEqual(SystemCommandParser.parse("Cloud Codecage", installedApps: apps), .switchToAgent(.claudeCode))
        XCTAssertEqual(SystemCommandParser.parse("Safariyege", installedApps: apps), .switchToApp("Safari"))
        XCTAssertNil(SystemCommandParser.parse("Garage", installedApps: apps))
        XCTAssertNil(SystemCommandParser.parse("Bir dakika bekle", installedApps: apps))
    }

    func testOtherGeçCommandsKeepTheirRoutes() {
        for text in ["Şarkıyı geç", "Şarkıya geç", "Bu kısmı geç", "Eve dön", "Geri dön"] {
            XCTAssertNil(SystemCommandParser.parse(text, installedApps: apps), text)
        }
        XCTAssertEqual(SystemCommandParser.parse("Sonraki sekmeye geç", installedApps: apps), .browser(.nextTab))
        XCTAssertEqual(SystemCommandParser.parse("Sonraki videoya geç", installedApps: apps), .video(.next))
        XCTAssertEqual(SystemCommandParser.parse("Developer moduna geç", installedApps: apps), .developerMode)
        XCTAssertNotEqual(SpotifyManager.explicitIntent(in: "sonraki şarkıya geç"), nil)
    }

    func testSwitchChains() {
        let plan = MultiCommandStep.plan("Safari'ye geç ve videoyu başlat", ringing: false, active: false,
                                         installedApps: apps, shortcuts: { [] })
        XCTAssertEqual(plan?.map(\.command), [.system(.switchToApp("Safari")), .system(.video(.play))])
        let music = MultiCommandStep.plan("Safari'ye geç ve müziği başlat", ringing: false, active: false,
                                          installedApps: apps, shortcuts: { [] })
        XCTAssertEqual(music?.first?.command, .system(.switchToApp("Safari")))
        XCTAssertEqual(music?.count, 2)
        if case .spotify = music?.last?.command {} else { XCTFail("müziği başlat → Spotify: \(String(describing: music))") }
    }
}
