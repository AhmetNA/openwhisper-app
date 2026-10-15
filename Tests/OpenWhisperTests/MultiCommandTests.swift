import XCTest
@testable import OpenWhisper

final class MultiCommandTests: XCTestCase {
    private func plan(_ text: String, ringing: Bool = false, active: Bool = false) -> [MultiCommandStep]? {
        MultiCommandStep.plan(text, ringing: ringing, active: active,
                              installedApps: ["Safari", "Notes", "Spotify"], shortcuts: { [] })?.map(\.command)
    }

    private func texts(_ text: String) -> [String]? {
        MultiCommandStep.plan(text, ringing: false, active: false,
                              installedApps: ["Safari", "Notes", "Spotify"], shortcuts: { [] })?.map(\.text)
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

    func testCombinedReplyFoldsAcks() {
        var reply = JarvisReply()
        reply.addressChance = 0
        XCTAssertEqual(reply.combined(["Tamam.", "Hallettim, patron."]).map(JarvisReply.isAck), true)
        XCTAssertEqual(reply.combined(["Tamam.", "Saat 10:30.", "Maalesef, olmadı."]), "Saat 10:30. Maalesef, olmadı.")
        XCTAssertNil(reply.combined([nil, nil]))
    }
}
