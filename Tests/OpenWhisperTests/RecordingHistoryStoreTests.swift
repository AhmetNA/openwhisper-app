import Foundation
import XCTest
@testable import OpenWhisper

final class RecordingHistoryStoreTests: XCTestCase {
    func testSevenNewestRecordingsSurviveRestartAndReplayAudio() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingHistoryStore(directory: directory)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for number in 0..<8 {
            let samples = [Float](repeating: Float(number) / 10, count: 6_400)
            try await store.append(
                CompletedAudioSegment(samples: samples, overlapSampleCount: 0),
                sessionID: UInt64(number),
                startedAt: start.addingTimeInterval(Double(number))
            )
            _ = try await store.finish(sessionID: UInt64(number), keep: true)
        }

        let reopened = RecordingHistoryStore(directory: directory)
        let items = await reopened.items()
        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(items.first?.createdAt, start.addingTimeInterval(7))
        XCTAssertEqual(items.last?.createdAt, start.addingTimeInterval(1))
        let replay = try await reopened.segment(id: items[0].id, startingAt: 0)
        XCTAssertEqual(replay?.0.samples.count, 6_400)
        XCTAssertEqual(replay?.0.samples[0] ?? 0, 0.7, accuracy: 0.0001)
    }

    func testCancelledRecordingDoesNotReplaceSavedHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingHistoryStore(directory: directory)
        try await store.append(
            CompletedAudioSegment(samples: [Float](repeating: 0.2, count: 6_400), overlapSampleCount: 0),
            sessionID: 1,
            startedAt: Date()
        )
        _ = try await store.finish(sessionID: 1, keep: false)
        let items = await store.items()
        XCTAssertTrue(items.isEmpty)
    }

    func testReplayStopsAfterFinalOverlappingSegment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingHistoryStore(directory: directory)
        let sampleCount = 180 * 16_000 + 8_000
        try await store.append(
            CompletedAudioSegment(samples: [Float](repeating: 0.1, count: sampleCount), overlapSampleCount: 0),
            sessionID: 1,
            startedAt: Date()
        )
        let items = try await store.finish(sessionID: 1, keep: true)
        var frame: Int64 = 0
        var segmentCount = 0
        while let (_, nextFrame) = try await store.segment(id: items[0].id, startingAt: frame) {
            XCTAssertGreaterThan(nextFrame, frame)
            frame = nextFrame
            segmentCount += 1
            XCTAssertLessThan(segmentCount, 4, "Replay must stop after the last new audio frame")
        }
        // AVAudioFile may report a short partial tail that it cannot read back;
        // replay must finish rather than feeding the preceding overlap forever.
        XCTAssertGreaterThanOrEqual(frame, Int64(sampleCount - 1_024))
        XCTAssertEqual(segmentCount, 2)
    }

    func testPreviewUpdatesKeepAudioAndSurviveRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordingHistoryStore(directory: directory)
        try await store.append(
            CompletedAudioSegment(samples: [Float](repeating: 0.15, count: 16_000), overlapSampleCount: 0),
            sessionID: 1,
            startedAt: Date()
        )
        let initial = try await store.finish(sessionID: 1, keep: true)
        XCTAssertNil(initial.first?.previewText)

        let updated = try await store.updatePreview(id: initial[0].id, text: "Merhaba   bugün\n hava güzel")
        XCTAssertEqual(updated[0].previewText, "Merhaba bugün hava güzel")
        XCTAssertEqual(updated[0].menuLabel, "0:01 · Merhaba bugün hava güzel")

        let reopened = RecordingHistoryStore(directory: directory)
        let saved = await reopened.items()
        XCTAssertEqual(saved.first?.previewText, "Merhaba bugün hava güzel")
        let segment = try await reopened.segment(id: initial[0].id, startingAt: 0)
        XCTAssertGreaterThan(segment?.0.samples.count ?? 0, 15_000)
        XCTAssertEqual(segment?.0.samples.first ?? 0, 0.15, accuracy: 0.0001)
    }

    func testOlderIndexWithoutPreviewStillDecodes() throws {
        let oldJSON = """
        {"id":"00000000-0000-0000-0000-000000000001","createdAt":0,"sampleCount":16000}
        """
        let decoded = try JSONDecoder().decode(SavedRecording.self, from: Data(oldJSON.utf8))
        XCTAssertNil(decoded.previewText)
        XCTAssertEqual(decoded.menuLabel, "0:01 · Önizleme hazırlanıyor…")
    }
}
