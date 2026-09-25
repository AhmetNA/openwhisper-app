import XCTest
@testable import OpenWhisper

final class SystemCommandParserTests: XCTestCase {
    func testBluetooth() {
        XCTAssertEqual(SystemCommandParser.parse("Bluetooth'u kapat."), .bluetooth(on: false))
        XCTAssertEqual(SystemCommandParser.parse("Bluetooth'u aç"), .bluetooth(on: true))
        XCTAssertEqual(SystemCommandParser.parse("Blututu kapat"), .bluetooth(on: false))
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
        XCTAssertEqual(SystemCommandParser.parse("Ekranı kilitle."), .lockScreen)
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
}
