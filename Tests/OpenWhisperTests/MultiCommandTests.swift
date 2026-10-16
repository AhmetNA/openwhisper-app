import XCTest
@testable import OpenWhisper

final class MultiCommandTests: XCTestCase {
    private let context = CommandRegistry.Context(installedApps: ["Safari", "Notes", "Spotify"])

    private func plan(_ text: String) -> [VoiceCommand]? {
        CommandRegistry.plan(text, context: context)?.map(\.command)
    }

    private func texts(_ text: String) -> [String]? {
        CommandRegistry.plan(text, context: context)?.map(\.text)
    }

    func testTwoSystemCommandsJoinedByVe() {
        XCTAssertEqual(plan("Bluetooth'u kapat ve Wi-Fi'yi aç"), [.system(.bluetooth(on: false)), .system(.wifi(on: true))])
    }

    func testCommaSonraAndSentenceBreaks() {
        XCTAssertEqual(texts("Wi-Fi'yi aç, sonra Bluetooth'u kapat"), ["Wi-Fi'yi aç", "Bluetooth'u kapat"])
        XCTAssertEqual(texts("Wi-Fi'yi aç. Ardından Bluetooth'u kapat."), ["Wi-Fi'yi aç", "Bluetooth'u kapat"])
        XCTAssertEqual(texts("Wi-Fi'yi aç ve sonra da Bluetooth'u kapat"), ["Wi-Fi'yi aç", "Bluetooth'u kapat"])
    }

    func testThreeCommandsAcrossParsers() {
        let steps = plan("Bluetooth'u kapat, 10 dakikalık alarm kur ve şarkıyı durdur")
        XCTAssertEqual(steps?.count, 3)
        XCTAssertEqual(steps?[0], .system(.bluetooth(on: false)))
        XCTAssertEqual(steps?[1], .timer(.start(seconds: 600, label: nil)))
        guard case .spotify = steps?[2] else { return XCTFail("third step: \(String(describing: steps?[2]))") }
    }

    func testTimeSonraStaysWithTheTimer() {
        let steps = plan("10 dakika sonra beni uyar ve Bluetooth'u kapat")
        XCTAssertEqual(steps, [.timer(.start(seconds: 600, label: nil)), .system(.bluetooth(on: false))])
    }

    func testDecimalCommaIsNotACut() {
        XCTAssertEqual(texts("1,5 saatlik alarm kur ve Wi-Fi'yi kapat")?.first, "1,5 saatlik alarm kur")
    }

    func testLeadingWakeWordIsDropped() {
        XCTAssertEqual(plan("Hey Jarvis, Bluetooth'u kapat ve Wi-Fi'yi aç")?.count, 2)
    }

    func testSingleCommandsTakeTheUsualRoute() {
        XCTAssertNil(plan("Bluetooth'u kapat"))
        XCTAssertNil(plan("10 dakika sonra beni uyar"))
    }

    func testAnyNonCommandPartFallsBack() {
        // Chatter after a command, or a list that only reads as one with a shared verb.
        XCTAssertNil(plan("Şarkıyı durdur. Neden. Var öyle"))
        XCTAssertNil(plan("Bluetooth'u kapat ve bana bir fıkra anlat"))
        XCTAssertNil(plan("Ekmek ve süt almayı unutma"))
    }

    func testNothingRunsAfterLocking() {
        XCTAssertNil(plan("Ekranı kilitle ve Wi-Fi'yi kapat"))
        XCTAssertEqual(plan("Wi-Fi'yi kapat ve ekranı kilitle")?.last, .system(.lockScreen))
    }

    // MARK: - One verb for several objects

    func testHemHemSharesTheVerb() {
        XCTAssertEqual(plan("Hem Wi-Fi hem Bluetooth'u aç."), [.system(.wifi(on: true)), .system(.bluetooth(on: true))])
        XCTAssertEqual(plan("Hem wifi hem bluetooth aç."), [.system(.wifi(on: true)), .system(.bluetooth(on: true))])
        XCTAssertEqual(texts("Hem Wi-Fi hem Bluetooth'u aç"), ["Wi-Fi aç", "Bluetooth'u aç"])
    }

    func testVeSharesTheVerb() {
        XCTAssertEqual(plan("Wi-Fi'yi ve Bluetooth'u kapat"), [.system(.wifi(on: false)), .system(.bluetooth(on: false))])
        XCTAssertEqual(plan("Safari'yi ve Notes'u kapat"), [.system(.quitApp("Safari")), .system(.quitApp("Notes"))])
    }

    func testFreeTextNeverBorrowsTheVerb() {
        // One search, not two; a song list is Spotify's to read.
        XCTAssertNil(plan("Tarkan ve Sezen Aksu çal"))
        XCTAssertNil(plan("Ekmek ve süt al"))
    }

    func testWhisperSpacedWiFi() {
        // "Wi -Fi aç ve müziği başlat" went to Spotify as one search for "wi -fi ve".
        let steps = plan("Wi -Fi aç ve müziği başlat.")
        XCTAssertEqual(steps?.first, .system(.wifi(on: true)))
        guard case .spotify = steps?.last else { return XCTFail("second step: \(String(describing: steps))") }
    }

    // MARK: - Registry

    func testAgentDictationIsNeverCutIntoSteps() {
        XCTAssertNil(plan("Claude Code'a yaz Wi-Fi'yi aç ve Bluetooth'u kapat"))
        guard case .agent? = CommandRegistry.match("Claude Code'a yaz Wi-Fi'yi aç ve Bluetooth'u kapat", context: context)
        else { return XCTFail("agent first") }
    }

    func testMailReplyIsNeverCutIntoSteps() {
        let reply = "Son maile cevap yaz: Wi-Fi'yi açtım ve Bluetooth'u kapattım"
        XCTAssertNil(plan(reply))
        guard case .system(.mailReplyDraft)? = CommandRegistry.match(reply, context: context)
        else { return XCTFail("mail reply: \(String(describing: CommandRegistry.match(reply, context: context)))") }
    }

    func testDeveloperModeIsNeverAStep() {
        XCTAssertNil(plan("Developer modu aç ve Wi-Fi'yi kapat"))
    }

    func testRegistryOrderMatchesTheSystemParser() {
        // A timer before the calendar, a browser search before Spotify.
        guard case .timer? = CommandRegistry.match("Yarın saat 7'de beni uyandır", context: context)
        else { return XCTFail("timer first") }
        XCTAssertEqual(CommandRegistry.match("YouTube'da lofi ara", context: context), .system(.browser(.search(.youtube, "lofi"))))
        XCTAssertEqual(SystemCommandParser.parse("Videoyu durdur"), .video(.pause))
    }

    func testCombinedReplyFoldsAcks() {
        var reply = JarvisReply()
        reply.addressChance = 0
        XCTAssertEqual(reply.combined(["Tamam.", "Hallettim, patron."]).map(JarvisReply.isAck), true)
        XCTAssertEqual(reply.combined(["Tamam.", "Saat 10:30.", "Maalesef, olmadı."]), "Saat 10:30. Maalesef, olmadı.")
        XCTAssertNil(reply.combined([nil, nil]))
    }
}
