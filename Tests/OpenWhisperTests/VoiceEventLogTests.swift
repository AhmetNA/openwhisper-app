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
