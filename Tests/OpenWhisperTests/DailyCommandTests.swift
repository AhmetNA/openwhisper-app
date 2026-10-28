import XCTest
@testable import OpenWhisper

final class DailyCommandTests: XCTestCase {
    private let apps = ["Safari", "Claude", "Notes", "Google Chrome", "WhatsApp", "Finder"]
    private let scenes = ["Developer modu", "Çalışma modu", "Akşam"]

    private func parse(_ text: String, paused: Bool = false, justCut: Bool = false) -> SystemCommand? {
        SystemCommandParser.parse(text, installedApps: apps, scenes: scenes, readingPaused: paused || justCut, readingJustCut: justCut)
    }

    // MARK: - Files

    func testFiles() {
        XCTAssertEqual(parse("İndirilenlerdeki son PDF'i aç."), .openFile(FileQuery(folder: .downloads, kind: .pdf)))
        XCTAssertEqual(parse("Son indirdiğim dosyayı aç"), .openFile(FileQuery(folder: .downloads)))
        XCTAssertEqual(parse("Son düzenlediğim dosyayı aç"), .openFile(FileQuery()))
        XCTAssertEqual(parse("Geçen hafta düzenlediğim raporu aç"), .openFile(FileQuery(name: "rapor", period: .lastWeek)))
        XCTAssertEqual(parse("Masaüstündeki son ekran görüntüsünü aç"), .openFile(FileQuery(folder: .desktop, kind: .image)))
        XCTAssertEqual(parse("Dün indirdiğim faturayı aç"), .openFile(FileQuery(folder: .downloads, name: "fatura", period: .yesterday)))
        XCTAssertEqual(parse("Bütçe adlı Excel dosyasını aç"), .openFile(FileQuery(kind: .spreadsheet, name: "bütçe")))
    }

    func testFilesLeaveOtherCommandsAlone() {
        XCTAssertNil(parse("Raporu aç"))
        XCTAssertEqual(parse("Safari'yi aç"), .openApp("Safari"))
        XCTAssertEqual(parse("Ekran görüntüsü al"), .screenshot)
        XCTAssertEqual(parse("Maili aç"), .mailOpen)
    }

    func testFilePeriods() {
        // Thursday 29 October 2026, 15:00.
        let now = ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z")!
        let lastWeek = FileFinder.period(of: .lastWeek, now: now)
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertEqual(calendar.component(.weekday, from: lastWeek.lowerBound), 2)
        XCTAssertEqual(lastWeek.upperBound.timeIntervalSince(lastWeek.lowerBound), 7 * 86400, accuracy: 3600)
        XCTAssertTrue(FileFinder.period(of: .today, now: now).contains(now))
    }

    // MARK: - Windows

    func testWindows() {
        XCTAssertEqual(parse("Safari sola"), .window(WindowAction(app: "Safari", position: .left)))
        XCTAssertEqual(parse("Claude'u sağa al"), .window(WindowAction(app: "Claude", position: .right)))
        XCTAssertEqual(parse("Bunu diğer ekrana at"), .window(WindowAction(app: nil, position: .nextScreen)))
        XCTAssertEqual(parse("Pencereyi büyüt"), .window(WindowAction(app: nil, position: .maximize)))
        XCTAssertEqual(parse("Chrome'u öbür ekrana taşı"), .window(WindowAction(app: "Google Chrome", position: .nextScreen)))
        XCTAssertNil(parse("Biraz sola"))
    }

    func testSideBySideIsTwoCommands() {
        let context = CommandRegistry.Context(installedApps: apps)
        XCTAssertEqual(CommandRegistry.plan("Safari sola, Claude sağa", context: context)?.map(\.command), [
            .system(.window(WindowAction(app: "Safari", position: .left))),
            .system(.window(WindowAction(app: "Claude", position: .right))),
        ])
    }

    func testFullscreenTarget() {
        XCTAssertEqual(DailyCommandParser.fullscreenTarget("Claude'u tam ekran yap", installedApps: apps), "Claude")
        XCTAssertNil(DailyCommandParser.fullscreenTarget("Tam ekran yap", installedApps: apps))
        XCTAssertNil(DailyCommandParser.fullscreenTarget("Videoyu tam ekran yap", installedApps: apps))
        // Still the video's parse; whether a video is in front is decided when it runs.
        XCTAssertEqual(parse("Tam ekran yap"), .video(.fullscreen))
    }

    // MARK: - Scenes

    func testScenes() {
        XCTAssertEqual(parse("Çalışma modu"), .scene("Çalışma modu"))
        XCTAssertEqual(parse("Hey Jarvis, çalışma modunu aç."), .scene("Çalışma modu"))
        XCTAssertEqual(parse("Çalışma moduna geç"), .scene("Çalışma modu"))
        XCTAssertEqual(parse("Akşam sahnesini başlat"), .scene("Akşam"))
        XCTAssertEqual(parse("Dev modu aç"), .scene("Developer modu"))
        XCTAssertNil(parse("Çalışma modunda ne var"))
    }

    func testSceneIsNeverAStep() {
        let context = CommandRegistry.Context(installedApps: apps, scenes: scenes)
        XCTAssertNil(CommandRegistry.plan("Çalışma modunu aç ve Wi-Fi'yi kapat", context: context))
    }

    func testSceneFile() {
        let scenes = SceneStore.parse("""
            # yorum
            Çalışma modu: Safari sola; Claude sağa ;Odak kısayolunu çalıştır
            # Akşam: ışıkları kapat
            Boş:
            """)
        XCTAssertEqual(scenes, [SceneStore.Scene(name: "Çalışma modu", steps: ["Safari sola", "Claude sağa", "Odak kısayolunu çalıştır"])])
        XCTAssertEqual(SceneStore.parse(SceneStore.initialContents).map(\.name), ["Developer modu"])
    }

    func testDeveloperSceneStepsAreCommands() {
        let context = CommandRegistry.Context(installedApps: apps + ["ChatGPT"])
        let steps = SceneStore.parse(SceneStore.initialContents)[0].steps
        let commands = steps.map { CommandRegistry.match($0, context: context) }
        XCTAssertFalse(commands.contains(nil), "\(zip(steps, commands).filter { $0.1 == nil }.map(\.0))")
        XCTAssertEqual(commands.last, .agent(AgentDictation(target: .claudeCode, body: "", send: false, session: .new)))
    }

    // MARK: - Clipboard

    func testClipboard() {
        XCTAssertEqual(parse("Panodaki son linki aç"), .clipboard(.openLink))
        XCTAssertEqual(parse("Kopyaladığım linki aç"), .clipboard(.openLink))
        XCTAssertEqual(parse("Az önce kopyaladığımı WhatsApp'tan Ali'ye at"), .clipboard(.sendWhatsApp("Ali")))
        XCTAssertEqual(parse("Panodakini anneme gönder"), .clipboard(.sendWhatsApp("Annem")))
        XCTAssertEqual(parse("Kopyaladığımı Aliye yolla"), .clipboard(.sendWhatsApp("Ali")))
        XCTAssertEqual(parse("Son kopyaladığımı Ayşe'ye ilet"), .clipboard(.sendWhatsApp("Ayşe")))
    }

    func testClipboardSendIsStandalone() {
        XCTAssertTrue(VoiceCommand.system(.clipboard(.sendWhatsApp("Ali"))).isStandalone)
        XCTAssertFalse(VoiceCommand.system(.clipboard(.openLink)).isStandalone)
    }

    func testLinkInCopiedText() {
        XCTAssertEqual(ClipboardHistory.link(in: "şuna bak https://example.com/a?b=1 güzel")?.host, "example.com")
        XCTAssertNil(ClipboardHistory.link(in: "link yok burada"))
    }

    // MARK: - Reading

    func testReading() {
        XCTAssertEqual(parse("Bu makaleyi oku"), .reading(.start))
        XCTAssertEqual(parse("Sayfayı sesli oku"), .reading(.start))
        XCTAssertEqual(parse("Okumaya devam et"), .reading(.resume))
        XCTAssertEqual(parse("Devam et", paused: true), .reading(.resume))
        XCTAssertEqual(parse("Dur", justCut: true), .reading(.stop))
        // Without a cut-short reading these are the music's; "durdur" a while after it too.
        XCTAssertNil(parse("Devam et"))
        XCTAssertNil(parse("Dur"))
        XCTAssertNil(parse("Durdur", paused: true))
        XCTAssertEqual(parse("Son maili oku"), .mailReadLatest)
        XCTAssertEqual(parse("Bu sayfayı özetle"), .browser(.summarize))
    }

    func testSentences() {
        let text = "Birinci cümle. İkinci cümle mi? Evet!\nBaşlık\n" + String(repeating: "uzun kelime, ", count: 40) + "son."
        let parts = ArticleReader.sentences(in: text)
        XCTAssertEqual(Array(parts.prefix(4)), ["Birinci cümle.", "İkinci cümle mi?", "Evet!", "Başlık"])
        XCTAssertTrue(parts.dropFirst(4).allSatisfy { $0.count <= 220 })
        XCTAssertGreaterThan(parts.count, 5)
    }
}
