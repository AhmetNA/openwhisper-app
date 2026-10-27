import XCTest
@testable import OpenWhisper

@MainActor
final class DisableWakeWordTests: XCTestCase {
    func testExplicitStopListeningPhrases() {
        for text in ["Jarvis beni dinlemeyi bırak", "Hey Jarvis dinlemeyi kapat",
                     "mikrofonu kapat", "sesle uyandırmayı kapatır mısın", "mikrofonu kapatır mısın", "Beni dinleme", "Dinlemeyi durdur",
                     "sesle uyandırmayı kapat", "sesle başlatmayı kapat",
                     "Lütfen mikrofonu kapat", "Jarvis, beni dinlemeyi bırak lütfen."] {
            XCTAssertEqual(SystemCommandParser.parseMac(text), .disableWakeWord, text)
            let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true,
                focus: .notEditable, hasTargetApp: false, pendingDeletion: false)
            guard case .command(.system(.disableWakeWord)) = VoiceRouter.route(text, facts: facts) else {
                XCTFail("Not routed as stop listening: \(text)")
                continue
            }
        }
    }

    func testMentionsNegationsAndOtherMicrophonesDoNotDisableWake() {
        for text in ["mikrofonu kapatma", "beni dinlemeyi bırakma", "mikrofonu kapat diye yaz",
                     "mikrofonu kapatınca ne oluyor", "Zoom mikrofonunu kapat", "dinlemeyi kapat komutu ekleyelim"] {
            XCTAssertNotEqual(SystemCommandParser.parseMac(text), .disableWakeWord, text)
        }
        XCTAssertNil(CommandRewriter.safeSystemCommand("mikrofonu kapat", installedApps: []))
        XCTAssertTrue(VoiceCommand.system(.disableWakeWord).endsSession)
    }

    func testCommandDisablesAndPersistsWakeSetting() async {
        let app = AppState()
        let previous = app.wakeWordEnabled
        defer { app.wakeWordEnabled = previous }
        app.wakeWordEnabled = true
        let status = await SystemController.perform(.disableWakeWord) { app.wakeWordEnabled = false }
        XCTAssertFalse(app.wakeWordEnabled)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "wakeWordEnabled"))
        XCTAssertTrue(status.contains("kapattım"))
        var reply = JarvisReply()
        let spoken = reply.system(.disableWakeWord, status: status)
        XCTAssertNotNil(spoken)
        XCTAssertNotNil(spoken.flatMap(ReplyTranslator.fixedEnglish))
        XCTAssertTrue(spoken.map(JarvisVoice.isCacheable) ?? false)
    }
}
