import XCTest
@testable import OpenWhisper

final class JarvisChatSafetyTests: XCTestCase {
    func testCloudPayloadCarriesCapabilitiesAndExecutionLimits() {
        for language: ReplyLanguage in [.turkish, .english] {
            let prompt = JarvisChat.systemPrompt(now: Date(), language: language)
            let request = LLMChatRequest(model: "test", messages: [
                ["role": "system", "content": prompt],
                ["role": "user", "content": "YouTube önerilerini okuyabiliyor musun?"]
            ], timeout: 10, temperature: 0.6, maxTokens: 110)
            let messages = CloudChatClient.chatBody(request)["messages"] as? [[String: String]]
            XCTAssertEqual(messages?.first?["role"], "system")
            let sent = messages?.first?["content"] ?? ""
            for service in ["Spotify", "Safari", "YouTube", "Claude Code", "Codex", "ChatGPT"] {
                XCTAssertTrue(sent.contains(service), service)
            }
            XCTAssertTrue(sent.contains("burada araç çağrısı veya işlem çalıştırma yoktur"))
            XCTAssertTrue(sent.contains("Servis tanımı bir işlem sonucu değildir"))
            XCTAssertTrue(sent.contains("YouTube'da neler var?"))
            XCTAssertFalse(sent.contains("İnternete, hava durumuna ve haberlere erişimin yok"))
        }
    }

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

    func testAnswersThatAskBackOpenTheFollowUpWindow() {
        XCTAssertTrue(JarvisChat.awaitsAnswer(JarvisChat.unrecognizedCommandReply))
        XCTAssertTrue(JarvisChat.awaitsAnswer("Hangi şarkıyı açayım patron?"))
        XCTAssertTrue(JarvisChat.awaitsAnswer("Üzgünüm, bunu anlayamadım."))
        XCTAssertTrue(JarvisChat.awaitsAnswer("I'm sorry, I didn't catch that."))
        XCTAssertFalse(JarvisChat.awaitsAnswer("Kara delikler ışığı bile kaçırmaz."))
        XCTAssertFalse(JarvisChat.awaitsAnswer("Tamamdır, efendim."))
        XCTAssertFalse(JarvisChat.awaitsAnswer("  "))
    }

    func testNotUnderstoodWordingsAreRecognised() {
        XCTAssertTrue(JarvisChat.saysNotUnderstood("Sanırım ne demek istediğinizi tam anlayamadım efendim."))
        XCTAssertTrue(JarvisChat.saysNotUnderstood("Bunu anlamadım."))
        XCTAssertFalse(JarvisChat.saysNotUnderstood("Daha açık bir ifade kullanabilir misiniz?"))
        XCTAssertTrue(JarvisChat.awaitsAnswer(JarvisChat.notUnderstoodReply))
    }
}
