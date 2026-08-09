import XCTest
@testable import OpenWhisper

final class LaughterRandomizerTests: XCTestCase {
    func testRepeatedHaBecomesAnEightToTenCharacterKeyboardSmash() {
        let result = LaughterRandomizer.transform("ha ha ha ha")

        XCTAssertTrue(result.didTransform)
        XCTAssertTrue((8...10).contains(result.text.count))
        XCTAssertTrue(result.text.allSatisfy { "asdfghjklş".contains($0) })
    }

    func testInlineLaughterPreservesTheSurroundingText() {
        let result = LaughterRandomizer.transform("Bu çok komik haha gerçekten")

        XCTAssertTrue(result.didTransform)
        XCTAssertTrue(result.text.hasPrefix("Bu çok komik "))
        XCTAssertTrue(result.text.hasSuffix(" gerçekten"))
        XCTAssertEqual(result.text.split(separator: " ").count, 5)
    }

    func testStandaloneTurkishLaughterMarkerIsTransformed() {
        let result = LaughterRandomizer.transform("[Gülüyor]")

        XCTAssertTrue(result.didTransform)
        XCTAssertTrue((8...10).contains(result.text.count))
    }

    func testOtherSpokenLaughterStylesAreTransformed() {
        XCTAssertTrue(LaughterRandomizer.transform("hehehe").didTransform)
        XCTAssertTrue(LaughterRandomizer.transform("hi hi hi").didTransform)
    }

    func testOrdinaryHaWordsAreUnchanged() {
        let result = LaughterRandomizer.transform("Haber hakkında konuşalım")

        XCTAssertEqual(result, .init(text: "Haber hakkında konuşalım", didTransform: false))
    }
}
