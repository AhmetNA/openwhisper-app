import XCTest
@testable import OpenWhisper

final class SpokenDoneEndpointTests: XCTestCase {
    func testFinalControlWordIsRemoved() {
        XCTAssertEqual(SpokenDoneEndpoint.removingSuffix(from: "Bunu yaz. Done!"), "Bunu yaz.")
        XCTAssertEqual(SpokenDoneEndpoint.removingSuffix(from: "done"), "")
        XCTAssertEqual(SpokenDoneEndpoint.removingSuffix(from: "Mesaj hazır DONE... \n"), "Mesaj hazır")
    }

    func testOtherWordsAndNonfinalMentionsArePreserved() {
        for text in ["done dedikten sonra", "undone", "redone", "done işini anlat", "yapıldı", "done's"] {
            XCTAssertNil(SpokenDoneEndpoint.removingSuffix(from: text), text)
        }
    }
}
