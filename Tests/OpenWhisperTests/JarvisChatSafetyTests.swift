import XCTest
@testable import OpenWhisper

final class JarvisChatSafetyTests: XCTestCase {
    func testBlocksFabricatedReminderDeletionSuccess() {
        XCTAssertEqual(
            JarvisChat.preventUnsupportedActionClaim(
                "Toplantı hatırlatıcısı silindi.",
                for: "Toplantı hatırlatıcısını sil."
            ),
            "Bu sohbetten o işlemi gerçekleştiremedim."
        )
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
