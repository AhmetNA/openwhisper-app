import XCTest
@testable import OpenWhisper

final class FocusStatusTests: XCTestCase {
    private func isOn(_ json: String) -> Bool {
        FocusStatus.isOn(assertions: Data(json.utf8))
    }

    func testAssertionRecordMeansFocusIsOn() {
        XCTAssertTrue(isOn(#"{"data":[{"storeAssertionRecords":[{}],"storeInvalidationRecords":[]}],"header":{}}"#))
    }

    func testNoAssertionRecordsMeansFocusIsOff() {
        // What macOS writes after a Focus is turned off: the key is gone, invalidations stay.
        XCTAssertFalse(isOn(#"{"data":[{"storeInvalidationRecords":[{}],"storeInvalidationRequestRecords":[]}],"header":{}}"#))
        XCTAssertFalse(isOn(#"{"data":[{"storeAssertionRecords":[]}]}"#))
    }

    func testUnknownContentMeansFocusIsOff() {
        XCTAssertFalse(isOn("not json"))
        XCTAssertFalse(isOn("{}"))
    }
}
