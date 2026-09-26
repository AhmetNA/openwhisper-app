import XCTest
@testable import OpenWhisper

final class JarvisAddresseeTests: XCTestCase {

    func testLeadingTypeOverride() {
        XCTAssertEqual(JarvisAddressee.leadingTypeCommand("Buraya yaz: yarın toplantıya geç kalacağım"),
                       "yarın toplantıya geç kalacağım")
        XCTAssertEqual(JarvisAddressee.leadingTypeCommand("İmlece şunu yaz merhaba dünya"), "merhaba dünya")
        XCTAssertEqual(JarvisAddressee.leadingTypeCommand("Alana bunu yazar mısın? selam"), "selam")
        XCTAssertNil(JarvisAddressee.leadingTypeCommand("yaz bana bir şiir"))
        XCTAssertNil(JarvisAddressee.leadingTypeCommand("buraya yazı yazmak zor"))
    }

    func testExplicitChatOverride() {
        XCTAssertEqual(JarvisAddressee.explicitChatCommand("Bana cevap ver: sence bu mantıklı mı?"),
                       "sence bu mantıklı mı?")
        XCTAssertEqual(JarvisAddressee.explicitChatCommand("Jarvis'e sor yarın hava nasıl"), "yarın hava nasıl")
        XCTAssertEqual(JarvisAddressee.explicitChatCommand("Seninle konuşuyorum, neden böyle oldu?"),
                       "neden böyle oldu?")
        XCTAssertNil(JarvisAddressee.explicitChatCommand("Bana yarın cevap ver"))
    }

    func testTrailingYazVariants() {
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Bluetooth'u kapat yaz"), "Bluetooth'u kapat")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Akşam geliyorum, bunu yaz."), "Akşam geliyorum")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("toplantı üçte yaz bunu"), "toplantı üçte")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Tamam hocam hallederim yazsana"), "Tamam hocam hallederim")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Yarın gelirim yazar mısın?"), "Yarın gelirim")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("selam naber ve yaz!"), "selam naber")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Selam naber. Yaz."), "Selam naber")
    }

    func testSeasonYazIsNotACommand() {
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("Tatile gideceğiz bu yaz"))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("çok sıcaktı geçen yaz."))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("Taşınacağız gelecek yaz"))
    }

    func testNoTrailingYaz() {
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("şarkının sözlerini yazdım"))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("yaz bana bir şiir"))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("kara deliği anlat"))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("yaz"))
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("Bu Ayaz"))
    }

    func testParseScore() {
        XCTAssertEqual(JarvisAddressee.parseScore(#"{"score": 85}"#), 85)
        XCTAssertEqual(JarvisAddressee.parseScore(#"{"score": "40"}"#), 40)
        XCTAssertEqual(JarvisAddressee.parseScore(" 72 "), 72)
        XCTAssertEqual(JarvisAddressee.parseScore(#"{"score": 140}"#), 100)
        XCTAssertNil(JarvisAddressee.parseScore("evet"))
        XCTAssertNil(JarvisAddressee.parseScore(#"{"answer": 3}"#))
    }

    func testDecisionFavoursTyping() {
        XCTAssertTrue(JarvisAddressee.isForJarvis(score: 80, minScore: 70))
        XCTAssertTrue(JarvisAddressee.isForJarvis(score: 70, minScore: 70))
        XCTAssertFalse(JarvisAddressee.isForJarvis(score: 50, minScore: 70))
        XCTAssertFalse(JarvisAddressee.isForJarvis(score: nil, minScore: 70))
    }

    func testKnownEditableFocusAlwaysTypesWithoutSemanticGuessing() {
        XCTAssertEqual(
            JarvisAddressee.defaultRoute(
                focusStatus: .editable,
                score: 100,
                minScore: 70
            ),
            .type
        )
    }

    func testKnownNonEditableFocusAlwaysChatsWithoutSemanticGuessing() {
        XCTAssertEqual(
            JarvisAddressee.defaultRoute(
                focusStatus: .notEditable,
                score: 0,
                minScore: 70
            ),
            .chat
        )
    }

    func testUnknownFocusUsesScoreFallback() {
        XCTAssertEqual(
            JarvisAddressee.defaultRoute(
                focusStatus: .unknown,
                score: 80,
                minScore: 70
            ),
            .chat
        )
        XCTAssertEqual(
            JarvisAddressee.defaultRoute(
                focusStatus: .unknown,
                score: nil,
                minScore: 70
            ),
            .type
        )
    }

    func testOllamaResponseSchemaRequiresBoundedIntegerScore() throws {
        let schema = JarvisAddressee.ollamaResponseSchema
        XCTAssertTrue(JSONSerialization.isValidJSONObject(schema))
        XCTAssertEqual(schema["required"] as? [String], ["score"])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let score = try XCTUnwrap(properties["score"] as? [String: Any])
        XCTAssertEqual(score["type"] as? String, "integer")
        XCTAssertEqual(score["minimum"] as? Int, 0)
        XCTAssertEqual(score["maximum"] as? Int, 100)
    }
}
