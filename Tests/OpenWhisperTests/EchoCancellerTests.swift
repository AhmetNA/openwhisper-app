import Accelerate
import AVFoundation
import XCTest
@testable import OpenWhisper

final class EchoCancellerTests: XCTestCase {
    private let rate = EchoCanceller.sampleRate

    // MARK: Signals

    /// 16 kHz mono of the project's test song (`Test3.mp3`, next to `app/`), else seeded noise.
    private func music(seconds: Int) throws -> [Float] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Test3.mp3")
        guard FileManager.default.fileExists(atPath: url.path) else {
            var rng = SeededGenerator(seed: 7)
            return (0..<(seconds * rate)).map { _ in Float.random(in: -0.3...0.3, using: &rng) }
        }
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
        let skip = AVAudioFramePosition(file.processingFormat.sampleRate * 3) // past the fade-in (the song is 36 s)
        file.framePosition = min(skip, file.length / 2)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate) * AVAudioFrameCount(seconds + 1)))
        try file.read(into: input)
        // The converter hands back a chunk per call; keep pulling until it reports the end.
        var fed = false
        var samples: [Float] = []
        while samples.count < seconds * rate {
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384))
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true
                status.pointee = .haveData
                return input
            }
            XCTAssertNil(error)
            samples += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
            if status == .endOfStream || status == .error || output.frameLength == 0 { break }
        }
        return Array(samples.prefix(seconds * rate))
    }

    /// A small room: direct path after `delay` samples, then a decaying random tail.
    private func roomEcho(_ x: [Float], delay: Int, gain: Float) -> [Float] {
        var rng = SeededGenerator(seed: 3)
        var h = [Float](repeating: 0, count: delay + 1600)
        h[delay] = 1
        for i in (delay + 1)..<h.count {
            h[i] = Float.random(in: -0.4...0.4, using: &rng) * exp(-Float(i - delay) / 300)
        }
        // y[n] = Σ h[k] x[n − k], via vDSP_conv over the zero-padded input and reversed taps.
        let padded = [Float](repeating: 0, count: h.count - 1) + x
        var y = [Float](repeating: 0, count: x.count)
        h.withUnsafeBufferPointer { taps in
            vDSP_conv(padded, 1, taps.baseAddress! + h.count - 1, -1, &y, 1,
                      vDSP_Length(x.count), vDSP_Length(h.count))
        }
        return y.map { $0 * gain }
    }

    /// Runs the canceller the way the listener does: the paired reference is the raw reference
    /// shifted `lookahead` samples ahead of the mic.
    private func cancel(mic: [Float], reference: [Float], chunk: Int = 480) -> [Float] {
        let ahead = Array(reference.dropFirst(EchoCanceller.lookahead)) + [Float](repeating: 0, count: EchoCanceller.lookahead)
        let canceller = EchoCanceller()
        canceller.log = { print($0) }
        var out: [Float] = []
        var i = 0
        while i < mic.count {
            let end = min(i + chunk, mic.count)
            out += canceller.process(mic: Array(mic[i..<end]), reference: Array(ahead[i..<end]))
            i = end
        }
        return out
    }

    private func energy(_ x: ArraySlice<Float>) -> Float { x.reduce(0) { $0 + $1 * $1 } }

    // MARK: Tests

    func testCancelsMusicEcho() throws {
        let ref = try music(seconds: 12)
        let echo = roomEcho(ref, delay: 640, gain: 0.3)
        let out = cancel(mic: echo, reference: ref)
        let tail = (8 * rate)..<(out.count)
        let erle = 10 * log10(energy(echo[tail]) / max(energy(out[tail]), 1e-12))
        print(String(format: "ERLE on music echo: %.1f dB", erle))
        XCTAssertGreaterThan(erle, 15)
    }

    func testDelayEstimatorFindsLag() throws {
        let ref = try music(seconds: 3)
        let lag = 1_600 + 720
        let micWindow = Array(roomEcho(ref, delay: lag, gain: 0.2)[(2 * rate - 16_000)..<(2 * rate)])
        let refWindow = Array(ref[(2 * rate - 16_000 - EchoCanceller.maxDelay)..<(2 * rate)])
        let estimate = try XCTUnwrap(EchoDelayEstimator.estimate(mic: micWindow, reference: refWindow,
                                                                 maxDelay: EchoCanceller.maxDelay))
        XCTAssertEqual(estimate.delay, lag, accuracy: 4)
        XCTAssertGreaterThan(estimate.confidence, 8)
    }

    func testAlignerPairsByTimestampAndFillsGapsWithSilence() {
        var aligner = EchoReferenceAligner()
        let start = 1_000_000
        // Reference from start+lookahead covers 1000 samples, then a gap, then more.
        aligner.appendReference((0..<1000).map { Float($0) }, startIndex: start + EchoCanceller.lookahead)
        let first = aligner.appendMic([Float](repeating: 0, count: 600), startIndex: start)
        XCTAssertEqual(first?.reference.first, 0)
        XCTAssertEqual(first?.reference.last, 599)
        // Mic runs past the reference: held back, not paired with made-up samples.
        let second = aligner.appendMic([Float](repeating: 0, count: 600), startIndex: start + 600)
        XCTAssertEqual(second?.mic.count, 400)
        aligner.appendReference([5, 5], startIndex: start + EchoCanceller.lookahead + 1100)
        let third = aligner.appendMic([Float](repeating: 0, count: 10), startIndex: start + 1200)
        // Indices 1000..<1100 were never sent: silence; 1100 and 1101 are the new buffer.
        XCTAssertEqual(third?.reference[0], 0)
        XCTAssertEqual(third?.reference[100], 5)
    }

    func testAlignerReleasesMicWhenReferenceStops() {
        var aligner = EchoReferenceAligner()
        var released = 0
        for k in 0..<40 {
            released += aligner.appendMic([Float](repeating: 1, count: 480), startIndex: k * 480)?.mic.count ?? 0
        }
        XCTAssertEqual(released, 40 * 480 - EchoReferenceAligner.maxHold)
    }

    func testAlignerResyncKeepsHeldAudio() {
        var aligner = EchoReferenceAligner()
        XCTAssertNil(aligner.appendMic([Float](repeating: 1, count: 600), startIndex: 0))
        // The mic clock jumps: the 600 held samples still come out, unpaired, ahead of the rest.
        let out = aligner.appendMic([Float](repeating: 2, count: 10), startIndex: 50_000)
        XCTAssertEqual(out?.mic.count, 600)
        XCTAssertEqual(out?.reference.allSatisfy { $0 == 0 }, true)
        XCTAssertEqual(aligner.resyncs, 1)
    }

    /// The point of the whole thing: "Jarvis" under loud speaker music.
    func testRestoresWakeScoreUnderMusic() throws {
        let wake = try wakePositive()
        let lead = 8 * rate // time for the filter to converge before the word
        let ref = try music(seconds: (lead + wake.count) / rate + 2)
        // Echo about as loud as the voice: the level where calls get missed.
        var echo = roomEcho(ref, delay: 900, gain: 1)
        let voiceRMS = (energy(wake[...]) / Float(wake.count)).squareRoot()
        let echoRMS = (energy(echo[lead...]) / Float(echo.count - lead)).squareRoot()
        // Music 12 dB over the voice: without cancelling, the word scores ~0.05.
        echo = echo.map { $0 * voiceRMS / echoRMS * pow(10, 12 / 20) }

        var mic = echo
        for (i, v) in wake.enumerated() { mic[lead + i] += v }
        let cleaned = cancel(mic: mic, reference: ref)

        func peak(_ audio: [Float]) throws -> Float {
            let slice = Array(audio[(lead - 2 * rate)..<min(audio.count, lead + wake.count)])
            return try scores(slice.map { $0 * 32767 }).max() ?? 0
        }
        let clean = try scores(wake.map { $0 * 32767 }).max() ?? 0
        let noisy = try peak(mic)
        let fixed = try peak(cleaned)
        print(String(format: "Wake peak — clean %.2f, music %.2f, music + AEC %.2f", clean, noisy, fixed))
        XCTAssertGreaterThan(fixed, noisy + 0.2)
        XCTAssertGreaterThan(fixed, 0.5)
    }

    /// Talking over the music for seconds must not wreck the filter for the next call.
    func testSurvivesLongTalkOverMusic() throws {
        let wake = try wakePositive()
        let ref = try music(seconds: 24)
        var echo = roomEcho(ref, delay: 900, gain: 1)
        let voiceRMS = (energy(wake[...]) / Float(wake.count)).squareRoot()
        let echoRMS = (energy(echo[...]) / Float(echo.count)).squareRoot()
        echo = echo.map { $0 * voiceRMS / echoRMS * pow(10, 12 / 20) }
        var mic = echo
        // The fixture is 5.4 s: talk over the music from 8 s, then the call at 16 s.
        for (i, v) in wake.enumerated() { mic[8 * rate + i] += 1.5 * v }
        let callAt = 16 * rate
        for (i, v) in wake.enumerated() { mic[callAt + i] += v }
        let out = cancel(mic: mic, reference: ref)
        let slice = Array(out[(callAt - 2 * rate)..<(callAt + wake.count)])
        let peak = try scores(slice.map { $0 * 32767 }).max() ?? 0
        print(String(format: "Call after talking over the music: peak %.2f", peak))
        XCTAssertGreaterThan(peak, 0.5)
    }

    /// Live recordings from the app (`wakeWordEchoDump`): skipped unless
    /// `AEC_DUMP_DIR=~/Library/Logs/OpenWhisper/aec-… swift test --filter testRecordedDump`.
    func testRecordedDump() throws {
        guard let dir = ProcessInfo.processInfo.environment["AEC_DUMP_DIR"] else {
            throw XCTSkip("AEC_DUMP_DIR not set")
        }
        func track(_ name: String) throws -> [Float] {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(name).wav"))
            return data.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let mic = try track("mic"), ref = try track("reference")
        let count = min(mic.count, ref.count)
        // Already paired by the app: feed as is (the reference is `lookahead` ahead).
        let canceller = EchoCanceller()
        canceller.log = { print($0) }
        var out: [Float] = []
        var i = 0
        while i < count {
            let end = min(i + 480, count)
            out += canceller.process(mic: Array(mic[i..<end]), reference: Array(ref[i..<end]))
            i = end
        }
        for second in stride(from: 0, to: out.count / rate, by: 5) {
            let r = (second * rate)..<min((second + 5) * rate, out.count)
            print(String(format: "%3d s: ERLE %.1f dB", second, 10 * log10(energy(mic[r]) / max(energy(out[r]), 1e-12))))
        }
        func peaks(_ audio: [Float]) throws -> [Float] {
            try scores(audio.map { min(max($0 * 32767 * 4, -32768), 32767) })
        }
        let before = try peaks(Array(mic.prefix(out.count))), after = try peaks(out)
        // Per 2 s window, like the listener's gain; the spots where a call would land.
        for w in stride(from: 0, to: min(before.count, after.count), by: 25) {
            let b = before[w..<min(w + 25, before.count)].max() ?? 0
            let a = after[w..<min(w + 25, after.count)].max() ?? 0
            if max(a, b) >= 0.1 {
                print(String(format: "%5.1f s: wake peak %.2f → %.2f", Double(w) * 0.08, b, a))
            }
        }
    }

    /// Shares the listener's queue with the wake-word model: must stay far below real time.
    func testRunsWellBelowRealTime() throws {
        let ref = try music(seconds: 30)
        let mic = roomEcho(ref, delay: 900, gain: 0.3)
        let start = Date()
        _ = cancel(mic: mic, reference: ref)
        let factor = Date().timeIntervalSince(start) / 30
        print(String(format: "Real-time factor: %.3f", factor))
        XCTAssertLessThan(factor, 0.1)
    }

    /// With no reference the canceller must hand the mic through untouched.
    func testSilentReferenceIsPassThrough() throws {
        let wake = try wakePositive()
        let out = cancel(mic: wake, reference: [Float](repeating: 0, count: wake.count))
        for i in 0..<out.count { XCTAssertEqual(out[i], wake[i], accuracy: 1e-6) }
    }

    // MARK: Wake word helpers

    private func wakePositive() throws -> [Float] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "wake_positive", withExtension: "wav", subdirectory: "Fixtures"))
        let pcm = try Data(contentsOf: url).dropFirst(44)
        return stride(from: pcm.startIndex, to: pcm.endIndex - 1, by: 2).map { i in
            Float(Int16(bitPattern: UInt16(pcm[i]) | UInt16(pcm[i + 1]) << 8)) / 32767
        }
    }

    private func scores(_ audio: [Float]) throws -> [Float] {
        let detector = try WakeWordDetector(modelDirectory: try XCTUnwrap(WakeWordDetector.bundledModelDirectory()))
        var out: [Float] = []
        var i = 0
        while i < audio.count {
            out += try detector.process(Array(audio[i..<min(i + 1280, audio.count)]))
            i += 1280
        }
        return out
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
