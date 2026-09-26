import Foundation
import OnnxRuntimeBindings

/// Streaming port of openWakeWord's inference path (openwakeword 0.6.0, `utils.AudioFeatures` +
/// `Model.predict`) for its pretrained `hey_jarvis_v0.1` model, run on ONNX Runtime.
///
/// Feed 16 kHz mono samples in int16 scale (-32768…32767, as Float) in any chunk size; every
/// complete 80 ms block (1280 samples) yields one score in 0…1. The steps mirror the Python code
/// exactly so scores match the reference (verified in `WakeWordDetectorTests`):
///   1. melspectrogram model on the last 1280 + 480 raw samples, then `x / 10 + 2`
///   2. embedding model on the last 76 mel frames → one 96-dim feature per block
///   3. wake model on the last 16 features
///   4. the first 5 predictions after start/reset are forced to 0 (feature buffers still warming)
///
/// With `gate` set, blocks the gate calls quiet skip steps 2–3 (the embedding model is ~90% of
/// the cost) and score 0. Their mel windows are kept, so when the gate reopens the last 16
/// features are rebuilt first: every scored block matches the ungated pipeline exactly.
///
/// Model licence note: the pretrained openWakeWord models are CC BY-NC-SA 4.0 (non-commercial).
/// Not thread-safe: call from one serial queue.
final class WakeWordDetector {
    static let blockSize = 1280
    private static let melContext = 160 * 3
    private static let melWindow = 76
    private static let featureWindow = 16
    private static let melMaxFrames = 10 * 97
    private static let featureMaxFrames = 120

    private let melSession: ORTSession
    private let embeddingSession: ORTSession
    private let wakeSession: ORTSession

    private var pending: [Float] = []
    private var raw: [Float] = []
    private var mel: [[Float]] = []
    private var features: [[Float]] = []
    private var predictionCount = 0
    /// Mel windows of the most recent gated-out blocks, oldest first (at most `featureWindow`).
    private var skippedWindows: [[[Float]]] = []
    var gate: WakeWordActivityGate?
    /// Blocks seen / embeddings actually computed (backfill included) — the real cost.
    private(set) var blockCount = 0
    private(set) var embeddingCount = 0
    /// Level of the latest block, for logging next to a detection.
    private(set) var lastLevelDB: Float = 0
    /// Feature history seeded from noise, computed once: `reset()` runs on every listener start.
    private var seedFeatures: [[Float]] = []

    init(modelDirectory: URL) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        func session(_ name: String) throws -> ORTSession {
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            return try ORTSession(
                env: env,
                modelPath: modelDirectory.appendingPathComponent(name).path,
                sessionOptions: options
            )
        }
        melSession = try session("melspectrogram.onnx")
        embeddingSession = try session("embedding_model.onnx")
        wakeSession = try session("hey_jarvis_v0.1.onnx")
        try reset()
    }

    /// The bundled models, or nil if the resource bundle doesn't carry them.
    static func bundledModelDirectory() -> URL? {
        guard let url = Bundle.module.url(forResource: "hey_jarvis_v0.1", withExtension: "onnx", subdirectory: "WakeWord")
            ?? Bundle.module.url(forResource: "hey_jarvis_v0.1", withExtension: "onnx") else { return nil }
        return url.deletingLastPathComponent()
    }

    func reset() throws {
        pending = []
        raw = []
        mel = Array(repeating: Array(repeating: 1, count: 32), count: Self.melWindow)
        predictionCount = 0
        skippedWindows = []
        if seedFeatures.isEmpty {
            // Python seeds the feature history with embeddings of 4 s of random noise in ±1000.
            let noise = (0..<(16000 * 4)).map { _ in Float(Int.random(in: -1000..<1000)) }
            let noiseMel = try melFrames(noise)
            var start = 0
            while start + Self.melWindow <= noiseMel.count {
                seedFeatures.append(try embedding(Array(noiseMel[start..<start + Self.melWindow])))
                start += 8
            }
        }
        features = seedFeatures
    }

    /// Returns one score per completed 80 ms block (usually zero or one).
    func process(_ samples: [Float]) throws -> [Float] {
        pending.append(contentsOf: samples)
        var scores: [Float] = []
        while pending.count >= Self.blockSize {
            let block = Array(pending.prefix(Self.blockSize))
            pending.removeFirst(Self.blockSize)
            scores.append(try processBlock(block))
        }
        return scores
    }

    private func processBlock(_ block: [Float]) throws -> Float {
        raw.append(contentsOf: block)
        let keep = Self.blockSize + Self.melContext
        if raw.count > keep { raw.removeFirst(raw.count - keep) }

        mel.append(contentsOf: try melFrames(raw))
        if mel.count > Self.melMaxFrames { mel.removeFirst(mel.count - Self.melMaxFrames) }

        let window = Array(mel.suffix(Self.melWindow))
        predictionCount += 1
        blockCount += 1
        lastLevelDB = Self.levelDB(block)
        if var gate {
            let active = gate.isActive(levelDB: lastLevelDB)
            self.gate = gate
            guard active else {
                skippedWindows.append(window)
                if skippedWindows.count > Self.featureWindow { skippedWindows.removeFirst() }
                return 0
            }
        }
        for skipped in skippedWindows { try appendFeature(skipped) }
        skippedWindows.removeAll()
        try appendFeature(window)

        let score = try wakeScore(Array(features.suffix(Self.featureWindow)))
        return predictionCount <= 5 ? 0 : score
    }

    private func appendFeature(_ melWindow: [[Float]]) throws {
        features.append(try embedding(melWindow))
        embeddingCount += 1
        if features.count > Self.featureMaxFrames { features.removeFirst(features.count - Self.featureMaxFrames) }
    }

    /// Block RMS in dB (int16 scale, so absolute values only matter relative to each other).
    private static func levelDB(_ block: [Float]) -> Float {
        var sum: Float = 0
        for x in block { sum += x * x }
        return 10 * log10(max(sum / Float(block.count), 1))
    }

    // MARK: - Models

    private func melFrames(_ samples: [Float]) throws -> [[Float]] {
        let input = try tensor(samples, shape: [1, samples.count])
        let output = try run(melSession, input: "input", value: input, output: "output")
        let bins = 32
        return stride(from: 0, to: output.count - bins + 1, by: bins).map { start in
            output[start..<start + bins].map { $0 / 10 + 2 }
        }
    }

    private func embedding(_ window: [[Float]]) throws -> [Float] {
        let input = try tensor(window.flatMap { $0 }, shape: [1, Self.melWindow, 32, 1])
        return try run(embeddingSession, input: "input_1", value: input, output: "conv2d_19")
    }

    private func wakeScore(_ window: [[Float]]) throws -> Float {
        let input = try tensor(window.flatMap { $0 }, shape: [1, Self.featureWindow, 96])
        return try run(wakeSession, input: "x.1", value: input, output: "53").first ?? 0
    }

    private func tensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * 4) }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    private func run(_ session: ORTSession, input: String, value: ORTValue, output: String) throws -> [Float] {
        let outputs = try session.run(withInputs: [input: value], outputNames: [output], runOptions: nil)
        guard let data = try outputs[output]?.tensorData() else { return [] }
        let count = data.length / 4
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.getBytes(buffer.baseAddress!, length: count * 4)
            initialized = count
        }
    }
}

/// Decides per 80 ms block whether anything louder than the room is going on. The noise floor
/// follows quiet stretches down at once and creeps up ~1 dB/s, so a fan or AC is learned within
/// seconds. While media plays the floor may only fall: speaker music then stays above the floor
/// (its quietest moment at worst), so the gate stays open and nothing is lost, while silently-open
/// output (Safari, visualizers) or headphone listening still lets a quiet room be gated.
/// Digital silence (the engine's first buffers, a muted mic) never teaches the floor: learning
/// 0 dB from it would hold the gate open for good.
struct WakeWordActivityGate {
    /// dB above the floor that counts as sound. Real triggers ran 20–30 dB above the floor.
    var margin: Float = 6
    var floorRisePerBlock: Float = 0.08
    /// Blocks kept open after the last loud one (~1 s); the score peaks at the end of the word.
    var hangoverBlocks = 13
    var mediaPlaying = false
    /// Silero VAD's verdict (`WakeVoiceActivity`): false keeps loud blocks without speech
    /// (typing, trackpad clicks, a door) from opening the gate. nil = no VAD, energy alone.
    var voice: Bool?

    private(set) var floor: Float?
    private var hangover = 0

    /// Below this a block is digital zeros, not a room (the quietest real mic reads ~16 dB).
    static let digitalSilenceDB: Float = 10
    /// Blocks passed through without touching the floor, set when the mic (re)starts: its first
    /// buffers ramp up from near-silence and would teach a floor no room has.
    var warmupBlocks = 0

    mutating func isActive(levelDB: Float) -> Bool {
        if warmupBlocks > 0 {
            warmupBlocks -= 1
            return true
        }
        guard levelDB > Self.digitalSilenceDB else { return false }
        if let current = floor {
            floor = min(levelDB, current + (mediaPlaying ? 0 : floorRisePerBlock))
        } else {
            floor = levelDB
        }
        guard let floor else { return true }
        if levelDB >= floor + margin, voice != false {
            hangover = hangoverBlocks
            return true
        }
        guard hangover > 0 else { return false }
        hangover -= 1
        return true
    }
}
