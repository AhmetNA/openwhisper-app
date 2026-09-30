import XCTest
@testable import OpenWhisper

@MainActor
final class WakeClipLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wakeclips-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWritesClipAndOneRecordWithEveryCheck() throws {
        let log = WakeClipLog(directory: directory)
        let id = try XCTUnwrap(log.begin(audio: Array(repeating: 0.5, count: 32_000), wakeScore: 0.38, kind: "direct"))
        log.update(id) {
            $0.speakerScore = 0.419
            $0.speakerThreshold = 0.4
            $0.wordCheck = "rejected: no wake word"
        }
        log.update(id) { $0.ownVoiceScores.append(0.13) }
        log.update(id) { $0.filterDecisions.append("accepted") }
        log.finish(id, outcome: "discarded", transcript: "Allah'a da arttır")
        // A late update after finishing is ignored, and finishing twice writes nothing more.
        log.update(id) { $0.speakerScore = 0.9 }
        log.finish(id, outcome: "transcribed")
        waitForDisk()

        let wav = try Data(contentsOf: directory.appendingPathComponent("\(id.uuidString).wav"))
        XCTAssertEqual(wav.count, 44 + 32_000 * 2)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")

        let lines = try String(contentsOf: directory.appendingPathComponent("wake_clips.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(WakeClipLog.Record.self, from: Data(lines[0].utf8))
        XCTAssertEqual(record.id, id.uuidString)
        XCTAssertEqual(record.wakeScore, 0.38, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(record.speakerScore), 0.419, accuracy: 0.0001)
        XCTAssertEqual(record.wordCheck, "rejected: no wake word")
        XCTAssertEqual(record.ownVoiceScores, [0.13])
        XCTAssertEqual(record.filterDecisions, ["accepted"])
        XCTAssertEqual(record.outcome, "discarded")
        XCTAssertEqual(record.transcript, "Allah'a da arttır")
    }

    func testNilIDIsIgnored() {
        let log = WakeClipLog(directory: directory)
        log.update(nil) { $0.speakerScore = 1 }
        log.finish(nil, outcome: "transcribed")
        waitForDisk()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("wake_clips.jsonl").path))
    }

    /// The log writes on its own serial queue; give it a moment to drain.
    private func waitForDisk() {
        let done = expectation(description: "disk")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { done.fulfill() }
        wait(for: [done], timeout: 2)
    }
}
