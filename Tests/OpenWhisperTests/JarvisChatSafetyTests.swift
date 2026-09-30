import XCTest
@testable import OpenWhisper

final class JarvisChatSafetyTests: XCTestCase {
    func testBlocksFabricatedReminderDeletionSuccess() {
        XCTAssertEqual(
            JarvisChat.preventUnsupportedActionClaim(
                "Toplantı hatırlatıcısı silindi.",
                for: "Toplantı hatırlatıcısını sil."
            ),
            JarvisChat.unrecognizedCommandReply
        )
    }

    func testRecognisesModelRefusalWordings() {
        XCTAssertTrue(JarvisChat.isCapabilityRefusal("Bu sohbet üzerinden müzik çalma işlemini gerçekleştiremedim."))
        XCTAssertTrue(JarvisChat.isCapabilityRefusal("Üzgünüm, bu sohbet üzerinden günlük özet veya kısayol oluşturma yeteneğim bulunmuyor."))
        XCTAssertTrue(JarvisChat.isCapabilityRefusal("Üzgünüm patron, bu sohbetten herhangi bir işlemi gerçekleştiremiyorum."))
        XCTAssertFalse(JarvisChat.isCapabilityRefusal("Kara delikler ışığı bile kaçırmaz."))
        XCTAssertFalse(JarvisChat.isCapabilityRefusal("Bu sohbet çok keyifliydi patron."))
    }

    func testLeavesOrdinaryConversationUntouched() {
        XCTAssertEqual(
            JarvisChat.preventUnsupportedActionClaim(
                "Dosya dün silindi.",
                for: "Dosya neden yok?"
            ),
            "Dosya dün silindi."
        )
    }

    func testLeavesNonSuccessFailureReplyUntouched() {
        XCTAssertEqual(
            JarvisChat.preventUnsupportedActionClaim(
                "Bu sohbetten o işlemi yapamam.",
                for: "Dosyayı sil."
            ),
            "Bu sohbetten o işlemi yapamam."
        )
    }
}
