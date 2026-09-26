import XCTest
@testable import OpenWhisper

final class RecordingMediaControllerTests: XCTestCase {
    private final class Transport: RecordingMediaTransport {
        var events: [String] = []
        var nextReceipt: MediaPlaybackSnapshot? = .init(playerID: "Safari/video-1", isPlaying: false)
        var pauseEntered: DispatchSemaphore?
        var releasePause: DispatchSemaphore?
        func pausePlayingItems() -> [MediaPlaybackSnapshot] {
            events.append("pause")
            pauseEntered?.signal()
            releasePause?.wait()
            return nextReceipt.map { [$0] } ?? []
        }
        func resume(_ receipt: MediaPlaybackSnapshot) { events.append("resume:\(receipt.playerID)") }
    }

    func testResumesOnlyOneConfirmedPauseDespiteDuplicateEvents() {
        let transport = Transport()
        let controller = RecordingMediaController(transport: transport, pauseDelay: 0)
        controller.begin()
        controller.begin()
        controller.end()
        controller.end()
        controller.waitUntilIdle()
        XCTAssertEqual(transport.events, ["pause", "resume:Safari/video-1"])
    }

    func testAlreadyPausedOrFailedPauseNeverSendsPlay() {
        let transport = Transport()
        transport.nextReceipt = nil
        let controller = RecordingMediaController(transport: transport, pauseDelay: 0)
        controller.begin()
        controller.end()
        controller.waitUntilIdle()
        XCTAssertEqual(transport.events, ["pause"])
    }

    func testReleaseDuringPendingPauseAndImmediateNewRecordingStayOrdered() {
        let transport = Transport()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        transport.pauseEntered = entered
        transport.releasePause = release
        let controller = RecordingMediaController(transport: transport, pauseDelay: 0)
        controller.begin()
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        controller.end()
        controller.begin()
        controller.end()
        release.signal()
        release.signal()
        controller.waitUntilIdle()
        XCTAssertEqual(transport.events, ["pause", "resume:Safari/video-1", "pause", "resume:Safari/video-1"])
    }

    func testEndWithoutResumingReleasesPausedPlayers() {
        let transport = Transport()
        let controller = RecordingMediaController(transport: transport, pauseDelay: 0)
        controller.begin()
        controller.end(resuming: false)
        controller.begin()
        controller.end()
        controller.waitUntilIdle()
        XCTAssertEqual(transport.events, ["pause", "pause", "resume:Safari/video-1"])
    }

    func testStopWithoutRecordingDoesNotStartMedia() {
        let transport = Transport()
        let controller = RecordingMediaController(transport: transport, pauseDelay: 0)
        controller.end()
        controller.waitUntilIdle()
        XCTAssertTrue(transport.events.isEmpty)
    }

    func testRecordingEndingDuringGracePeriodNeverPausesMedia() {
        let transport = Transport()
        let controller = RecordingMediaController(transport: transport, pauseDelay: 0.05)

        controller.begin()
        controller.end()
        Thread.sleep(forTimeInterval: 0.1)
        controller.waitUntilIdle()

        XCTAssertTrue(transport.events.isEmpty)
    }

    func testRecordingStillActiveAfterGracePeriodPausesAndResumesMedia() {
        let transport = Transport()
        let pauseEntered = DispatchSemaphore(value: 0)
        transport.pauseEntered = pauseEntered
        let controller = RecordingMediaController(transport: transport, pauseDelay: 0.01)

        controller.begin()
        XCTAssertEqual(pauseEntered.wait(timeout: .now() + 1), .success)
        controller.end()
        controller.waitUntilIdle()

        XCTAssertEqual(transport.events, ["pause", "resume:Safari/video-1"])
    }
}
