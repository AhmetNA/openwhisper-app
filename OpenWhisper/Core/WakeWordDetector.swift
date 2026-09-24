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

        features.append(try embedding(Array(mel.suffix(Self.melWindow))))
        if features.count > Self.featureMaxFrames { features.removeFirst(features.count - Self.featureMaxFrames) }

        let score = try wakeScore(Array(features.suffix(Self.featureWindow)))
        predictionCount += 1
        return predictionCount <= 5 ? 0 : score
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
