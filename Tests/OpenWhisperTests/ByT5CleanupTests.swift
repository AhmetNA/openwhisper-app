import XCTest
@testable import OpenWhisper

final class ByT5CleanupTests: XCTestCase {
    func testInstalledByT5EndToEndWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["OPENWHISPER_RUN_BYT5_INTEGRATION"] == "1" else {
            throw XCTSkip("ByT5 integration runtime is optional")
        }

        let cleanup = LLMCleanup(model: LLMCleanup.byT5ModelID)
        let first = await cleanup.cleanup(text: "şey sicil belgmi alcam")
        XCTAssertEqual(first, "Sicil belgimi alacağım")

        let protected = await cleanup.cleanup(
            text: "yarın ChatGPT ile 42 kayıt için https://example.com/API adresine bakcam"
        )
        XCTAssertTrue(protected.contains("ChatGPT"))
        XCTAssertTrue(protected.contains("42"))
        XCTAssertTrue(protected.contains("https://example.com/API"))
    }

    func testByT5FillerRemovalOnlyRemovesStandaloneWords() {
        XCTAssertEqual(
            LLMCleanup.removingStandaloneFillers(from: "Yani, şey bugün başlayalım."),
            "bugün başlayalım."
        )
        XCTAssertEqual(
            LLMCleanup.removingStandaloneFillers(from: "Şeyma bugün geliyor."),
            "Şeyma bugün geliyor."
        )
    }

    func testByT5RestoresProtectedTechnicalTermsAndCasing() {
        let restored = LLMCleanup.restoringProtectedTerms(
            in: "chatgpt ile https://example.com/api adresini dene.",
            from: "ChatGPT ile https://example.com/API adresini dene.",
            glossaryTerms: ["ChatGPT"]
        )
        XCTAssertEqual(restored, "ChatGPT ile https://example.com/API adresini dene.")
    }

    func testByT5AcceptsTurkishNormalization() {
        XCTAssertTrue(LLMCleanup.isSafeByT5Normalization(
            original: "sicil belgmi alcam",
            normalized: "Sicil belgimi alacağım",
            glossaryTerms: nil
        ))
    }

    func testByT5RejectsDroppedProtectedContent() {
        XCTAssertFalse(LLMCleanup.isSafeByT5Normalization(
            original: "ChatGPT ile 42 kayıt için https://example.com/API adresine bak",
            normalized: "Sistem kayıtları için adrese bak.",
            glossaryTerms: ["ChatGPT"]
        ))
    }

    func testByT5RejectsNonLatinHallucination() {
        XCTAssertFalse(LLMCleanup.isSafeByT5Normalization(
            original: "Bugün toplantıya gideceğim.",
            normalized: "今天 toplantıya gideceğim.",
            glossaryTerms: nil
        ))
    }
}
