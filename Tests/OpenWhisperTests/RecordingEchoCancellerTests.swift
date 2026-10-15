import Accelerate
import XCTest
@testable import OpenWhisper

/// `EchoCancelledStream` is the recording path's canceller: it may hold and reshape audio, but
/// must never drop, duplicate or reorder a dictation sample.
final class RecordingEchoCancellerTests: XCTestCase {
    private let chunk = 320 // 20 ms, a typical 16 kHz buffer after conversion
    private let t0 = 1_000_000

    private func noise(_ count: Int, seed: UInt64, amplitude: Float) -> [Float] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { _ in Float.random(in: -amplitude...amplitude, using: &rng) }
    }

    private func energy(_ x: ArraySlice<Float>) -> Float {
        var e: Float = 0
        Array(x).withUnsafeBufferPointer { vDSP_svesq($0.baseAddress!, 1, &e, vDSP_Length($0.count)) }
        return e
    }

    /// Feeds `mic` in chunks with host-clock indices; `reference` (same clock) is delivered
    /// `referenceLead` samples ahead of the mic, as ScreenCaptureKit would.
    private func run(mic: [Float], reference: [Float]?, referenceLead: Int = 3_200,
                     referenceStopsAt: Int = .max, untimed: Range<Int> = 0..<0,
                     held: ((Int, Int) -> Void)? = nil) -> [Float] {
        let stream = EchoCancelledStream(engine: .linear)
        var out: [Float] = []
        var referenceSent = 0
        var offset = 0
        while offset < mic.count {
            if let reference, offset < referenceStopsAt {
                let target = min(reference.count, offset + chunk + referenceLead)
                if target > referenceSent {
                    stream.appendReference(Array(reference[referenceSent..<target]), startIndex: t0 + referenceSent)
                    referenceSent = target
                }
            }
            let end = min(offset + chunk, mic.count)
            let hostIndex = untimed.contains(offset) ? nil : t0 + offset
            out += stream.process(mic: Array(mic[offset..<end]), hostIndex: hostIndex)
            offset = end
            held?(offset, offset - out.count)
        }
        out += stream.finish()
        XCTAssertEqual(stream.inputSamples, stream.outputSamples)
        return out
    }

    func testWithoutReferenceEverySampleComesBackUnchanged() {
        let mic = noise(16_000 * 3 + 123, seed: 1, amplitude: 0.2)
        let out = run(mic: mic, reference: nil)
        XCTAssertEqual(out.count, mic.count)
        for (a, b) in zip(out, mic) where abs(a - b) > 1e-4 {
            XCTFail("sample changed: \(a) vs \(b)")
            return
        }
    }

    func testUntimedBuffersKeepOrderAndCount() {
        let mic = noise(16_000 * 2, seed: 2, amplitude: 0.2)
        let reference = noise(mic.count + 8_000, seed: 3, amplitude: 0.2)
        let out = run(mic: mic, reference: reference, untimed: 9_600..<12_800)
        XCTAssertEqual(out.count, mic.count)
        // The untimed stretch bypasses the filter, so it comes back as it went in.
        let lo = 9_600, hi = 12_800
        for i in lo..<hi where abs(out[i] - mic[i]) > 1e-4 {
            XCTFail("untimed sample \(i) moved or changed")
            return
        }
    }

    func testNoReferenceMeansNoHold() {
        let mic = noise(16_000 * 2, seed: 5, amplitude: 0.2)
        var maxHeld = 0
        let out = run(mic: mic, reference: nil, held: { _, h in maxHeld = max(maxHeld, h) })
        XCTAssertEqual(out.count, mic.count)
        XCTAssertLessThanOrEqual(maxHeld, 256, "mic held with no reference running")
    }

    /// The recording pauses the music: ScreenCaptureKit stops sending, and the rest of the
    /// recording must not stay half a second behind.
    func testStoppedReferenceReleasesTheMic() {
        let mic = noise(16_000 * 6, seed: 6, amplitude: 0.2)
        let reference = noise(mic.count + 8_000, seed: 7, amplitude: 0.2)
        let stop = 16_000 * 2
        var lateHeld = 0
        let out = run(mic: mic, reference: reference, referenceStopsAt: stop, held: { offset, h in
            if offset > stop + 16_000 { lateHeld = max(lateHeld, h) }
        })
        XCTAssertEqual(out.count, mic.count)
        XCTAssertLessThanOrEqual(lateHeld, 256, "mic still held 1 s after the reference stopped")
    }

    func testEchoIsRemovedAndLengthPreserved() {
        let seconds = 10
        let reference = noise(16_000 * seconds + 8_000, seed: 4, amplitude: 0.3)
        // The mic hears the speakers 30 ms late at half level.
        let delay = 480
        var mic = [Float](repeating: 0, count: 16_000 * seconds)
        for i in delay..<mic.count { mic[i] = 0.5 * reference[i - delay] }
        let out = run(mic: mic, reference: reference)
        XCTAssertEqual(out.count, mic.count)
        let tail = (mic.count - 32_000)..<(mic.count - 4_000)
        let erle = 10 * log10(energy(mic[tail]) / max(energy(out[tail]), 1e-12))
        XCTAssertGreaterThan(erle, 10, "echo suppression after convergence: \(erle) dB")
    }

    /// A recording that continues the wake listener's stream adopts its converged filter,
    /// reference history and held mic: every sample comes out once, in order, and the echo is
    /// cancelled from the first block instead of after several seconds.
    func testWarmHandoffCancelsFromTheStartAndPairsThePreroll() {
        warmHandoff(engine: .linear, minimumERLE: 20)
    }

    /// The user's engine; same seam, measured with AEC3's linear output.
    func testWarmHandoffWithAEC3() {
        warmHandoff(engine: .aec3, minimumERLE: 10)
    }

    private func warmHandoff(engine: EchoCancellationEngineKind, minimumERLE: Float) {
        let delay = 480
        let total = 16_000 * 12
        let reference = noise(total + 8_000, seed: 8, amplitude: 0.3)
        var mic = [Float](repeating: 0, count: total)
        for i in delay..<total { mic[i] = 0.5 * reference[i - delay] }
        // ScreenCaptureKit's buffers carry timestamps ~75 ms behind the mic's, so the aligner
        // holds the newest mic (plus its 100 ms lookahead) until the reference catches up.
        let lag = 1_200
        let handoffAt = 16_000 * 8
        let prerollStart = handoffAt - 3_200 // the wake preroll replays 200 ms

        // The wake listener: its own aligner and canceller over the first 8 s.
        var aligner = EchoReferenceAligner()
        let listener = EchoCanceller(engine: engine)
        var offset = 0
        while offset < handoffAt {
            let referenceStart = max(0, offset - lag), referenceEnd = offset + chunk - lag
            if referenceEnd > referenceStart {
                aligner.appendReference(Array(reference[referenceStart..<referenceEnd]), startIndex: t0 + referenceStart)
            }
            if let pair = aligner.appendMic(Array(mic[offset..<offset + chunk]), startIndex: t0 + offset) {
                _ = listener.process(mic: pair.mic, reference: pair.reference)
            }
            offset += chunk
        }

        let stream = EchoCancelledStream(engine: engine)
        stream.adopt(.init(aligner: aligner, canceller: listener))
        var out: [Float] = []
        var sent = handoffAt - lag
        var at = prerollStart
        while at < total {
            let target = min(reference.count, max(sent, at + 3_200 + chunk - lag))
            if target > sent {
                stream.appendReference(Array(reference[sent..<target]), startIndex: t0 + sent)
                sent = target
            }
            out += stream.process(mic: Array(mic[at..<at + chunk]), hostIndex: t0 + at)
            at += chunk
        }
        out += stream.finish()
        XCTAssertEqual(stream.inputSamples, stream.outputSamples)
        XCTAssertEqual(out.count, total - prerollStart)
        XCTAssertEqual(stream.idleSamples, 0, "preroll released without its reference")
        // The raw overlap (listener-cancelled, its output gone) is at most the aligner's hold.
        let overlap = (handoffAt - lag - EchoCanceller.lookahead) - prerollStart
        XCTAssertLessThan(overlap, 1_000)
        let firstSecond = (overlap + 256)..<16_000
        let micFirst = mic[(prerollStart + firstSecond.lowerBound)..<(prerollStart + firstSecond.upperBound)]
        let warmERLE = 10 * log10(energy(micFirst) / max(energy(out[firstSecond]), 1e-12))
        XCTAssertGreaterThan(warmERLE, minimumERLE, "\(engine) warm start, first second: \(warmERLE) dB")
    }
    /// Reference buffers that arrive between the handoff and the recording's attach are kept
    /// and delivered first; an unclaimed handoff stops forwarding.
    func testEchoStateHandoffBuffersUntilAttachedAndWaitsForState() {
        let handoff = EchoStateHandoff(reference: SystemOutputReference { _, _ in })
        XCTAssertNil(handoff.waitForState(timeout: 0.01), "nothing delivered yet")
        handoff.appendReference([1], pts: 1)
        handoff.appendReference([2], pts: 2)
        handoff.deliver(.init(aligner: EchoReferenceAligner(), canceller: EchoCanceller(engine: .linear)))
        XCTAssertNotNil(handoff.waitForState(timeout: 0))
        XCTAssertNil(handoff.waitForState(timeout: 0), "state is handed out once")
        var received: [Float] = []
        handoff.attach { samples, _ in received += samples }
        handoff.appendReference([3], pts: 3)
        XCTAssertEqual(received, [1, 2, 3])
        handoff.release() // attached: no-op
        handoff.appendReference([4], pts: 4)
        XCTAssertEqual(received, [1, 2, 3, 4])
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
