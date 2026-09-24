import XCTest
@testable import OpenWhisper

/// Parity with the Python openWakeWord reference: the fixtures and their per-block scores were
/// produced by openwakeword 0.6.0 (onnx) feeding the same WAVs in 1280-sample chunks.
final class WakeWordDetectorTests: XCTestCase {
    /// The first ~2.4 s depend on the random feature seed both implementations start from.
    private let settledBlock = 32

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    }

    /// Plain 16-bit PCM WAV written by Python's `wave` (44-byte header). Parsed by hand because
    /// AVAudioFile under-reported this file's length by ~1000 frames.
    private func samples(_ name: String) throws -> [Float] {
        let data = try Data(contentsOf: try fixture(name, "wav"))
        let pcm = data.dropFirst(44)
        return stride(from: pcm.startIndex, to: pcm.endIndex - 1, by: 2).map { i in
            Float(Int16(bitPattern: UInt16(pcm[i]) | UInt16(pcm[i + 1]) << 8))
        }
    }

    private func reference() throws -> [String: [Float]] {
        let data = try Data(contentsOf: try fixture("wake_reference_scores", "json"))
        return try JSONDecoder().decode([String: [Float]].self, from: data)
    }

    private func scores(_ name: String, chunk: Int = 1280) throws -> [Float] {
        let modelDir = try XCTUnwrap(WakeWordDetector.bundledModelDirectory())
        let detector = try WakeWordDetector(modelDirectory: modelDir)
        let audio = try samples(name)
        var out: [Float] = []
        var i = 0
        while i < audio.count {
            out += try detector.process(Array(audio[i..<min(i + chunk, audio.count)]))
            i += chunk
        }
        return out
    }

    func testPositiveMatchesReference() throws {
        let ours = try scores("wake_positive")
        let theirs = try XCTUnwrap(try reference()["wake_positive"])
        XCTAssertEqual(ours.count, theirs.count)
        for i in settledBlock..<min(ours.count, theirs.count) {
            XCTAssertEqual(ours[i], theirs[i], accuracy: 0.02, "block \(i)")
        }
        XCTAssertGreaterThan(ours.max() ?? 0, 0.9)
    }

    func testNegativeMatchesReferenceAndStaysLow() throws {
        let ours = try scores("wake_negative")
        let theirs = try XCTUnwrap(try reference()["wake_negative"])
        for i in settledBlock..<min(ours.count, theirs.count) {
            XCTAssertEqual(ours[i], theirs[i], accuracy: 0.02, "block \(i)")
        }
        XCTAssertLessThan(ours.max() ?? 1, 0.3)
    }

    func testOddChunkSizesGiveSameScores() throws {
        // The audio tap delivers arbitrary buffer sizes; blocking must not depend on them.
        let a = try scores("wake_positive", chunk: 1280)
        let b = try scores("wake_positive", chunk: 777)
        XCTAssertEqual(a.count, b.count)
        for i in settledBlock..<a.count {
            XCTAssertEqual(a[i], b[i], accuracy: 0.02)
        }
    }
}
