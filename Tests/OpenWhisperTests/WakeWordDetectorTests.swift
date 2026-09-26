import XCTest
import FluidAudio
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
        try scores(of: try samples(name), chunk: chunk)
    }

    private func scores(of audio: [Float], chunk: Int = 1280, gate: WakeWordActivityGate? = nil) throws -> [Float] {
        let modelDir = try XCTUnwrap(WakeWordDetector.bundledModelDirectory())
        let detector = try WakeWordDetector(modelDirectory: modelDir)
        detector.gate = gate
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

    // MARK: - Activity gate

    /// The fixture's speech sits ~45 dB above its noise; the raw mic in real use gives 17–37 dB.
    /// Scale the speech down by `attenuationDB`, lay it over steady noise at the fixture's own
    /// floor (~31 dB) and precede it with `leadSeconds` of that noise alone.
    private func realistic(_ name: String, attenuationDB: Float, leadSeconds: Int = 6) throws -> [Float] {
        var rng = SystemRandomNumberGenerator()
        let gain = pow(10, -attenuationDB / 20)
        let speech = try samples(name).map { $0 * gain }
        let noise = { Float(Int.random(in: -60...60, using: &rng)) }
        return (0..<(16000 * leadSeconds)).map { _ in noise() } + speech.map { $0 + noise() }
    }

    func testGateScoresMatchUngatedForQuietSpeech() throws {
        for attenuation: Float in [20, 30] {
            let audio = try realistic("wake_positive", attenuationDB: attenuation)
            let plain = try scores(of: audio)
            let gated = try scores(of: audio, gate: WakeWordActivityGate())
            XCTAssertEqual(plain.count, gated.count)
            XCTAssertEqual(gated.max() ?? 0, plain.max() ?? 0, accuracy: 0.001, "attenuation \(attenuation) dB")
            // Every block the gate let through must score exactly as without the gate.
            for i in plain.indices where gated[i] > 0 {
                XCTAssertEqual(gated[i], plain[i], accuracy: 0.001, "block \(i)")
            }
        }
    }

    func testGateStillDetectsModeratelyQuietSpeech() throws {
        let audio = try realistic("wake_positive", attenuationDB: 20)
        XCTAssertGreaterThan(try scores(of: audio, gate: WakeWordActivityGate()).max() ?? 0, 0.5)
    }

    func testGateSkipsMostEmbeddingsInQuietRoom() throws {
        let modelDir = try XCTUnwrap(WakeWordDetector.bundledModelDirectory())
        let detector = try WakeWordDetector(modelDirectory: modelDir)
        detector.gate = WakeWordActivityGate()
        let quiet = (0..<(16000 * 10)).map { _ in Float(Int.random(in: -60...60)) }
        let scores = try detector.process(quiet)
        XCTAssertEqual(scores.max() ?? 1, 0)
        XCTAssertLessThan(detector.embeddingCount, detector.blockCount / 10)
    }

    func testGateFloorOnlyFallsWhileMediaPlays() {
        var gate = WakeWordActivityGate()
        for _ in 0..<50 { _ = gate.isActive(levelDB: 30) }   // quiet room learned
        gate.mediaPlaying = true
        for _ in 0..<2000 { XCTAssertTrue(gate.isActive(levelDB: 60)) }   // speaker music keeps it open
        XCTAssertEqual(gate.floor ?? 0, 30, accuracy: 0.01)
        gate.mediaPlaying = false
        XCTAssertTrue(gate.isActive(levelDB: 60))
    }

    func testGateLearnsFloorDuringMediaAndOnlyLowersIt() {
        var gate = WakeWordActivityGate()
        gate.mediaPlaying = true
        _ = gate.isActive(levelDB: 60)   // started mid-song
        for _ in 0..<50 { _ = gate.isActive(levelDB: 35) }   // quiet passage
        XCTAssertTrue(gate.isActive(levelDB: 60))
        XCTAssertEqual(gate.floor ?? 0, 35, accuracy: 0.01)
    }

    func testDigitalSilenceNeverTeachesFloor() {
        var gate = WakeWordActivityGate()
        for _ in 0..<20 { XCTAssertFalse(gate.isActive(levelDB: 0)) }
        XCTAssertNil(gate.floor)
        for _ in 0..<50 { _ = gate.isActive(levelDB: 20) }
        XCTAssertFalse(gate.isActive(levelDB: 22))
        XCTAssertTrue(gate.isActive(levelDB: 30))
    }

    func testWarmupBlocksDoNotTeachFloor() {
        var gate = WakeWordActivityGate()
        gate.warmupBlocks = 6
        for _ in 0..<6 { XCTAssertTrue(gate.isActive(levelDB: 12)) }   // mic ramping up
        XCTAssertNil(gate.floor)
        _ = gate.isActive(levelDB: 25)
        XCTAssertEqual(gate.floor ?? 0, 25, accuracy: 0.01)
    }

    func testGateClosesOnSteadyRoomNoiseWithoutAudibleMedia() {
        var gate = WakeWordActivityGate()
        _ = gate.isActive(levelDB: 25)   // floor learned in a quiet moment
        // A fan starts: 20 dB above the floor. With no audible media the floor climbs to it.
        let open = (0..<600).map { _ in gate.isActive(levelDB: 45) }
        XCTAssertTrue(open.first ?? false)
        XCTAssertFalse(open.last ?? true)
        XCTAssertEqual(gate.floor ?? 0, 45, accuracy: 0.1)
    }

    func testReferenceAudibilityHoldsThenExpires() {
        var audibility = ReferenceAudibility()
        let silent = [Float](repeating: 0, count: 480)
        let quietUI = [Float](repeating: 0.0005, count: 480)   // ~-66 dBFS
        let music = (0..<480).map { 0.1 * sin(Float($0) * 0.3) }
        audibility.add(silent, at: 0)
        audibility.add(quietUI, at: 0.1)
        XCTAssertFalse(audibility.isAudible(at: 0.2))
        audibility.add(music, at: 1)
        XCTAssertTrue(audibility.isAudible(at: 1))
        XCTAssertTrue(audibility.isAudible(at: 3.9))   // gap between songs
        audibility.add(silent, at: 2)
        XCTAssertFalse(audibility.isAudible(at: 4.1))
    }

    // MARK: - Voice (Silero VAD) in front of the gate

    func testGateNeedsVoiceWhenVADSaysNoSpeech() {
        var gate = WakeWordActivityGate()
        _ = gate.isActive(levelDB: 25)
        gate.voice = false
        XCTAssertFalse(gate.isActive(levelDB: 50))   // a loud click, no speech
        gate.voice = true
        XCTAssertTrue(gate.isActive(levelDB: 50))
        gate.voice = false
        XCTAssertTrue(gate.isActive(levelDB: 25))    // hangover from the voiced block still runs
    }

    func testGateWithoutVADBehavesAsBefore() {
        var gate = WakeWordActivityGate()
        _ = gate.isActive(levelDB: 25)
        XCTAssertNil(gate.voice)
        XCTAssertTrue(gate.isActive(levelDB: 50))
    }

    private var vadModelInstalled: Bool {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/silero-vad-coreml")
        return FileManager.default.fileExists(atPath: dir.path)
    }

    /// Runs the detector with the gate fed Silero's verdict the way the listener does: a chunk's
    /// verdict becomes known only after the chunk ends plus ~50 ms of inference, then is held.
    private func vadGatedRun(_ audio: [Float]) async throws -> (maxScore: Float, embeddingShare: Double, speechChunks: Int) {
        let vad = try await VadManager(config: VadConfig(defaultThreshold: WakeVoiceActivity.threshold))
        let lifted = audio.map { min(max($0 / 32767 * 4, -1), 1) }   // listener gain ×4, int16 → -1…1
        let probabilities = try await vad.process(lifted).map(\.probability)
        let chunk = VadManager.chunkSize, lag = 800, hold = Int(WakeVoiceActivity.holdSeconds * 16000)
        let speechKnownAt = probabilities.enumerated()
            .filter { $0.element >= WakeVoiceActivity.threshold }
            .map { ($0.offset + 1) * chunk + lag }

        let detector = try WakeWordDetector(modelDirectory: try XCTUnwrap(WakeWordDetector.bundledModelDirectory()))
        detector.gate = WakeWordActivityGate()
        var maxScore: Float = 0
        var start = 0
        while start + WakeWordDetector.blockSize <= audio.count {
            let end = start + WakeWordDetector.blockSize
            let firstVerdictAt = chunk + lag
            detector.gate?.voice = end < firstVerdictAt ? nil : speechKnownAt.contains { $0 <= end && end - $0 <= hold }
            maxScore = max(maxScore, try detector.process(Array(audio[start..<end])).max() ?? 0)
            start = end
        }
        return (maxScore, Double(detector.embeddingCount) / Double(max(detector.blockCount, 1)), speechKnownAt.count)
    }

    func testSileroGateStillWakesOnRealJarvis() async throws {
        try XCTSkipUnless(vadModelInstalled, "Silero VAD model not downloaded")
        for attenuation: Float in [20, 30] {
            let audio = try realistic("wake_positive", attenuationDB: attenuation)
            let plain = try scores(of: audio, gate: WakeWordActivityGate()).max() ?? 0
            let run = try await vadGatedRun(audio)
            print(String(format: "[vad-test] Jarvis -%.0f dB: gated %.3f, energy-only %.3f, speech chunks %d", attenuation, run.maxScore, plain, run.speechChunks))
            XCTAssertGreaterThan(run.speechChunks, 0, "attenuation \(attenuation) dB")
            XCTAssertEqual(run.maxScore, plain, accuracy: 0.05, "attenuation \(attenuation) dB")
        }
    }

    func testSileroGateKeepsTypingFromRunningTheModel() async throws {
        try XCTSkipUnless(vadModelInstalled, "Silero VAD model not downloaded")
        // 10 s of keyboard: a 6 ms broadband click about every 140 ms over the room noise.
        var rng = SystemRandomNumberGenerator()
        var audio = (0..<(16000 * 10)).map { _ in Float(Int.random(in: -60...60, using: &rng)) }
        var at = 16000
        while at + 96 < audio.count {
            for i in 0..<96 { audio[at + i] += Float(Int.random(in: -6000...6000, using: &rng)) * Float(96 - i) / 96 }
            at += Int.random(in: 1800...2800, using: &rng)
        }
        let energyDetector = try WakeWordDetector(modelDirectory: try XCTUnwrap(WakeWordDetector.bundledModelDirectory()))
        energyDetector.gate = WakeWordActivityGate()
        _ = try energyDetector.process(audio)
        let energyShare = Double(energyDetector.embeddingCount) / Double(energyDetector.blockCount)

        let run = try await vadGatedRun(audio)
        print(String(format: "[vad-test] typing: embeddings energy-only %.0f%%, with VAD %.0f%%, speech chunks %d", energyShare * 100, run.embeddingShare * 100, run.speechChunks))
        XCTAssertGreaterThan(energyShare, 0.5, "the clicks should open the energy-only gate")
        XCTAssertLessThan(run.embeddingShare, 0.15, "energy-only share was \(energyShare)")
    }
}
