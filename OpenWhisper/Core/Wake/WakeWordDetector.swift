import Foundation
import OnnxRuntimeBindings

/// "Hey Jarvis" detector on LiveKit's pretrained streaming model (livekit-wakeword v2.1.1,
/// `hey_jarvis.onnx`, Apache 2.0, see `Resources/WakeWord/LiveKit-NOTICE.txt`), run on ONNX Runtime.
///
/// Feed 16 kHz mono samples in int16 scale (-32768…32767, as Float) in any chunk size; every
/// complete 80 ms block (1280 samples) yields one score in 0…1. The model is a single graph that
/// takes one block plus its own state and returns the score and the next state. The state starts
/// from 2 s of silence, as in LiveKit's runtimes; scores match their Python client (verified in
/// `WakeWordDetectorTests`).
///
/// With `gate` set, blocks the gate calls quiet are not run and score 0. They are kept, and run
/// first when the gate reopens. After a long close only the last 3 s are run, from the silent
/// state: on 60 real calls that kept the peak within 0.04 of an ungated run.
///
/// Not thread-safe: call from one serial queue.
final class WakeWordDetector {
    static let blockSize = 1280
    private static let modelName = "hey_jarvis"
    private static let warmupBlocks = 25
    private static let replayBlocks = 38
    /// The model's state inputs and shapes (ONNX Runtime's Objective-C API cannot read them).
    private static let stateInputs: [(name: String, shape: [Int], int64: Bool)] = [
        ("audio", [1, 352], false),
        ("sub0", [1, 1, 40, 1], false),
        ("sub1", [1, 64, 20, 1], false),
        ("sub2", [1, 64, 10, 1], false),
        ("k", [4, 1, 4, 32, 36], false),
        ("v", [4, 1, 4, 32, 36], false),
        ("conv", [4, 1, 144, 14], false),
        ("ctx", [1, 15, 96], false),
        ("step", [1], true),
    ]

    private let session: ORTSession
    private var state: [String: ORTValue] = [:]
    private var silentState: [String: ORTValue] = [:]
    private var pending: [Float] = []
    /// Blocks the gate skipped since the model last ran, oldest first (at most `replayBlocks`).
    private var skipped: [[Float]] = []
    /// More blocks were skipped than kept: the state no longer follows the audio.
    private var skippedOverflow = false
    var gate: WakeWordActivityGate?
    /// Blocks seen / model runs (replays included) — the real cost.
    private(set) var blockCount = 0
    private(set) var modelRuns = 0
    /// Level of the latest block, for logging next to a detection.
    private(set) var lastLevelDB: Float = 0

    init(modelDirectory: URL) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(
            env: env,
            modelPath: modelDirectory.appendingPathComponent("\(Self.modelName).onnx").path,
            sessionOptions: options
        )
        for input in Self.stateInputs {
            let count = input.shape.reduce(1, *)
            state[input.name] = try ORTValue(
                tensorData: NSMutableData(length: count * (input.int64 ? 8 : 4))!,
                elementType: input.int64 ? .int64 : .float,
                shape: input.shape.map { NSNumber(value: $0) })
        }
        let silence = [Float](repeating: 0, count: Self.blockSize)
        for _ in 0..<Self.warmupBlocks { _ = try run(silence) }
        silentState = state
        modelRuns = 0
        try reset()
    }

    /// The bundled model's directory, or nil if the resource bundle doesn't carry it.
    static func bundledModelDirectory() -> URL? {
        guard let url = Bundle.module.url(forResource: modelName, withExtension: "onnx", subdirectory: "WakeWord")
            ?? Bundle.module.url(forResource: modelName, withExtension: "onnx") else { return nil }
        return url.deletingLastPathComponent()
    }

    func reset() throws {
        pending = []
        skipped = []
        skippedOverflow = false
        state = silentState
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
        blockCount += 1
        lastLevelDB = Self.levelDB(block)
        if var gate {
            let active = gate.isActive(levelDB: lastLevelDB)
            self.gate = gate
            guard active else {
                skipped.append(block)
                if skipped.count > Self.replayBlocks {
                    skipped.removeFirst()
                    skippedOverflow = true
                }
                return 0
            }
        }
        if !skipped.isEmpty {
            if skippedOverflow { state = silentState }
            for old in skipped { _ = try run(old) }
            skipped = []
            skippedOverflow = false
        }
        return try run(block)
    }

    /// Block RMS in dB (int16 scale, so absolute values only matter relative to each other).
    static func levelDB(_ block: [Float]) -> Float {
        var sum: Float = 0
        for x in block { sum += x * x }
        return 10 * log10(max(sum / Float(block.count), 1))
    }

    // MARK: - Model

    /// One 80 ms step: int16-scale block in, score out, state advanced.
    private func run(_ block: [Float]) throws -> Float {
        modelRuns += 1
        let scaled = block.map { $0 / 32768 }
        var inputs = state
        inputs["chunk"] = try ORTValue(
            tensorData: scaled.withUnsafeBufferPointer { NSMutableData(bytes: $0.baseAddress, length: $0.count * 4) },
            elementType: .float, shape: [1, NSNumber(value: Self.blockSize)])
        let outputNames = Set(["score"] + Self.stateInputs.map { $0.name + "_out" })
        let outputs = try session.run(withInputs: inputs, outputNames: outputNames, runOptions: nil)
        for input in Self.stateInputs {
            guard let next = outputs[input.name + "_out"] else { throw DetectorError.missingOutput(input.name) }
            state[input.name] = next
        }
        guard let data = try outputs["score"]?.tensorData(), data.length >= 4 else {
            throw DetectorError.missingOutput("score")
        }
        var score: Float = 0
        data.getBytes(&score, length: 4)
        return score
    }

    enum DetectorError: Error {
        case missingOutput(String)
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
