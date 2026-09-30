import Foundation
import XCTest
@testable import OpenWhisper

final class VoiceEventLogTests: XCTestCase {
    private var directory: URL!
    private var log: VoiceEventLog!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        log = VoiceEventLog(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTraceHasHeaderThenTimedLines() {
        let id = UUID()
        log.begin(id, header: ["Recording \(id.uuidString)", "Source: hotkey"])
        log.append(id, "[Route] spotify")
        log.append(id, "[Result] Spotify command handled")
        let lines = log.read(id)?.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "# Recording \(id.uuidString)")
        XCTAssertEqual(lines[1], "# Source: hotkey")
        XCTAssertTrue(lines[2].hasSuffix("ms] [Route] spotify"), lines[2])
        XCTAssertTrue(lines[3].hasSuffix("[Result] Spotify command handled"), lines[3])
    }

    func testAppendWithoutBeginWritesNothing() {
        let id = UUID()
        log.append(id, "orphan line")
        log.flush()
        XCTAssertNil(log.read(id))
    }

    func testCurrentTraceFollowsTaskAndChildTasksOnly() async {
        let id = UUID()
        log.begin(id, header: ["Recording"])
        log.appendToCurrent("before binding")
        await VoiceTrace.$current.withValue(id) {
            log.appendToCurrent("inside")
            // Unstructured tasks inherit task-locals: the async cleanup path relies on this.
            await Task { self.log.appendToCurrent("child task") }.value
            // Detached tasks do not.
            await Task.detached { self.log.appendToCurrent("detached") }.value
        }
        log.appendToCurrent("after binding")
        let text = log.read(id) ?? ""
        XCTAssertTrue(text.contains("inside"))
        XCTAssertTrue(text.contains("child task"))
        XCTAssertFalse(text.contains("before binding"))
        XCTAssertFalse(text.contains("detached"))
        XCTAssertFalse(text.contains("after binding"))
    }

    func testTracesOfDifferentRecordingsStaySeparate() async {
        let a = UUID(), b = UUID()
        log.begin(a, header: ["A"])
        log.begin(b, header: ["B"])
        async let first: Void = VoiceTrace.$current.withValue(a) { log.appendToCurrent("from A") }
        async let second: Void = VoiceTrace.$current.withValue(b) { log.appendToCurrent("from B") }
        _ = await (first, second)
        XCTAssertTrue(log.read(a)?.contains("from A") ?? false)
        XCTAssertFalse(log.read(a)?.contains("from B") ?? true)
        XCTAssertTrue(log.read(b)?.contains("from B") ?? false)
        XCTAssertFalse(log.read(b)?.contains("from A") ?? true)
    }
}

final class VoiceLatencyTrackerTests: XCTestCase {
    func testSummaryReportsStagesCriticalTimeAndBottleneck() {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var value: TimeInterval = 10
            func now() -> TimeInterval { lock.withLock { value } }
            func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
        }

        let clock = Clock()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = VoiceEventLog(directory: directory)
        let id = UUID()
        log.begin(id, header: ["Latency"])
        let tracker = VoiceLatencyTracker(
            now: { clock.now() },
            logger: { log.append(id, $0) }
        )
        clock.advance(2)
        tracker.markRecordingStopped()
        let transcription = tracker.timestamp()
        clock.advance(0.8)
        tracker.record(.transcription, since: transcription)
        tracker.beginDecision()
        clock.advance(0.2)
        tracker.finishDecision(route: "dikte")
        let paste = tracker.timestamp()
        clock.advance(0.1)
        tracker.record(.paste, since: paste)

        tracker.markOutput("pastedVerified")
        log.flush()
        let text = log.read(id) ?? ""
        XCTAssertTrue(text.contains("Transkripsiyon hattı: 800 ms"), text)
        XCTAssertTrue(text.contains("Karar / yönlendirme: 200 ms"), text)
        XCTAssertTrue(text.contains("Mikrofon durdu → sonuç: 1.10 sn"), text)
        XCTAssertTrue(text.contains("Darboğaz: Transkripsiyon hattı 800 ms"), text)
        try? FileManager.default.removeItem(at: directory)
    }
}
