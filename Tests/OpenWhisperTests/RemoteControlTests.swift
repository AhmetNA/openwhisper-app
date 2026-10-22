import XCTest
@testable import OpenWhisper

/// Remote control by voice: waking the display, the unlock request, and what may run while
/// the Mac is locked.
@MainActor
final class RemoteControlTests: XCTestCase {
    private func route(_ text: String) -> VoiceRouter.Route {
        VoiceRouter.route(text, facts: VoiceRouter.Facts(
            isVoiceCommand: true, acceptsCommands: true, focus: .unknown, hasTargetApp: true,
            commandContext: { CommandRegistry.Context(installedApps: ["Safari", "Spotify", "WhatsApp"]) }))
    }

    private func command(_ text: String) -> VoiceCommand? {
        if case .command(let command) = route(text) { return command }
        return nil
    }

    func testWakeDisplayPhrases() {
        for text in ["Ekranı aç", "Ekranı aç.", "Ekranı uyandır", "Jarvis ekranı aç", "Ekranı açar mısın?",
                     "Ekranı uyandırır mısın", "Monitörü aç", "Ekranı aç lütfen"] {
            XCTAssertEqual(command(text), .system(.displayWake), text)
        }
        XCTAssertEqual(command("Ekranı kapat"), .system(.displaySleep))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı aydınlat"), .brightness(up: true, level: nil))
        XCTAssertEqual(SystemCommandParser.parse("Ekranı kilitle"), .lockScreen)
        XCTAssertNil(SystemCommandParser.parse("Ekranı açınca ne oluyor"))
        XCTAssertNotEqual(command("Yarın 7'de beni uyandır"), .system(.displayWake))
    }

    func testUnlockIsAnsweredNeverDone() {
        for text in ["Kilidi aç", "Ekranın kilidini aç", "Bilgisayarın kilidini aç", "Mac'in kilidini aç", "Şifremi gir"] {
            XCTAssertEqual(command(text), .system(.unlockRequest), text)
        }
        var reply = JarvisReply()
        let spoken = reply.system(.unlockRequest, status: RemoteControl.unlockAnswer)
        XCTAssertTrue(spoken?.contains("Apple Watch") == true, spoken ?? "nil")
    }

    func testWakeDisplayIsAcknowledged() {
        var reply = JarvisReply()
        XCTAssertNotNil(reply.system(.displayWake, status: "Ekran açıldı"))
        XCTAssertTrue(reply.system(.displayWake, status: "Ekran açılamadı")?.hasPrefix("Maalesef") == true)
    }

    func testWhatNeedsTheScreenUnlocked() {
        // Typed into an app or done on screen.
        XCTAssertTrue(RemoteControl.needsUnlockedScreen(.typed("merhaba")))
        XCTAssertTrue(RemoteControl.needsUnlockedScreen(.command(.system(.switchToApp("Safari")))))
        XCTAssertTrue(RemoteControl.needsUnlockedScreen(.command(.system(.browser(.newTab)))))
        XCTAssertTrue(RemoteControl.needsUnlockedScreen(.command(.system(.scroll(up: false, large: false)))))
        // Work without the screen: answers, Spotify, timers, WhatsApp reading, the display.
        XCTAssertFalse(RemoteControl.needsUnlockedScreen(.command(.system(.time))))
        XCTAssertFalse(RemoteControl.needsUnlockedScreen(.command(.system(.whatsAppUnread))))
        XCTAssertFalse(RemoteControl.needsUnlockedScreen(.command(.system(.displayWake))))
        XCTAssertFalse(RemoteControl.needsUnlockedScreen(.command(.system(.unlockRequest))))
        XCTAssertFalse(RemoteControl.needsUnlockedScreen(.command(.spotify("şarkıyı durdur"))))
        XCTAssertFalse(RemoteControl.needsUnlockedScreen(.command(.system(.browser(.summarize)))))
        XCTAssertFalse(RemoteControl.needsUnlockedScreen(route("10 dakikalık zamanlayıcı kur")))
        XCTAssertFalse(RemoteControl.needsUnlockedScreen(route("Saat kaç")))
    }
}
