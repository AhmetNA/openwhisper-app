import XCTest
@testable import OpenWhisper

final class SystemMediaActivityMonitorTests: XCTestCase {
    func testPlaybackAtLaunchActivatesAndStopsAfterQuietGracePeriod() {
        var state = MediaActivityDebouncer()
        XCTAssertNil(state.update(hasOutput: true, at: 0))
        XCTAssertEqual(state.update(hasOutput: true, at: 1), true)
        XCTAssertNil(state.update(hasOutput: true, at: 2))
        XCTAssertNil(state.update(hasOutput: false, at: 3))
        XCTAssertNil(state.update(hasOutput: false, at: 5))
        XCTAssertEqual(state.update(hasOutput: false, at: 6), false)
    }

    func testNotificationDoesNotActivateAndPlaybackGapDoesNotDeactivate() {
        var state = MediaActivityDebouncer()
        XCTAssertNil(state.update(hasOutput: true, at: 0))
        XCTAssertNil(state.update(hasOutput: false, at: 0.5))
        XCTAssertFalse(state.isPlaying)
        XCTAssertNil(state.update(hasOutput: true, at: 2))
        XCTAssertEqual(state.update(hasOutput: true, at: 3), true)
        XCTAssertNil(state.update(hasOutput: false, at: 4))
        XCTAssertNil(state.update(hasOutput: true, at: 6))
        XCTAssertNil(state.update(hasOutput: false, at: 7))
        XCTAssertNil(state.update(hasOutput: false, at: 8))
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.update(hasOutput: false, at: 10), false)
    }
}
