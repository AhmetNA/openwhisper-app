import CDeepFilter
import Foundation

/// Wraps DeepFilterNet 3's native Rust inference engine (libDF, `capi` feature) for real-time
/// noise suppression. Pure Rust + `tract` (ONNX runtime) under the hood — no Python, no torch,
/// no subprocess/IPC. Measured on this hardware: ~0.7ms to process each 10ms/480-sample frame
/// (~14x faster than real-time), so the only cost worth avoiding on the Fn-press path is model
/// load (~170ms) — callers should create one instance at app startup and keep it for the app's
/// lifetime rather than per recording.
final class DeepFilterProcessor {
    /// DeepFilterNet operates at a fixed 48kHz internally regardless of the mic's native rate.
    static let sampleRate: Double = 48_000

    private let state: OpaquePointer
    let frameLength: Int

    private var ringBuffer: [Float] = []
    private let inFrame: UnsafeMutablePointer<Float>
    private let outFrame: UnsafeMutablePointer<Float>

    /// Per-recording counters proving DF3 actually ran, read by AudioEngine after a recording
    /// stops. Plain scalars updated inline in `process()` — no allocation on the audio thread.
    private(set) var processedFrameCount = 0
    private var snrSum: Float = 0

    /// Mean of `df_process_frame`'s per-frame local SNR (dB) across this recording.
    var averageSNR: Float {
        processedFrameCount > 0 ? snrSum / Float(processedFrameCount) : 0
    }

    /// Total audio duration fed through DF3 this recording, derived from frame count.
    var processedDurationMs: Double {
        Double(processedFrameCount * frameLength) / Self.sampleRate * 1000
    }

    init?() {
        guard let modelPath = Bundle.main.path(forResource: "DeepFilterNet3_onnx", ofType: "tar.gz"),
              FileManager.default.fileExists(atPath: modelPath) else {
            owLog("[DeepFilter] Model resource not found; DeepFilterNet unavailable.")
            return nil
        }

        let tCreateStart = Date()
        // df_create panics (aborting the process across the FFI boundary) on a bad path, so the
        // fileExists check above is load-bearing, not just a nicety.
        let createdState: OpaquePointer? = modelPath.withCString { cPath in
            "error".withCString { cLogLevel in
                df_create(cPath, 100.0, cLogLevel)
            }
        }
        guard let createdState else {
            owLog("[DeepFilter] df_create returned NULL; DeepFilterNet unavailable.")
            return nil
        }
        state = createdState
        frameLength = Int(df_get_frame_length(state))
        guard frameLength > 0 else {
            owLog("[DeepFilter] df_get_frame_length returned 0; DeepFilterNet unavailable.")
            df_free(createdState)
            return nil
        }
        inFrame = .allocate(capacity: frameLength)
        outFrame = .allocate(capacity: frameLength)
        ringBuffer.reserveCapacity(frameLength * 8)

        let elapsedMs = Date().timeIntervalSince(tCreateStart) * 1000
        owLog(String(
            format: "[DeepFilter] Model loaded in %.1f ms, frameLength=%d samples (%.1f ms @ 48kHz)",
            elapsedMs, frameLength, Double(frameLength) / Self.sampleRate * 1000
        ))
    }

    deinit {
        df_free(state)
        inFrame.deallocate()
        outFrame.deallocate()
    }

    /// Resets carried-over samples between recordings. The model itself (`state`) stays loaded
    /// and is reused — only ~10ms of audio continuity is lost, which is inaudible.
    func resetStream() {
        ringBuffer.removeAll(keepingCapacity: true)
        processedFrameCount = 0
        snrSum = 0
    }

    /// Feeds `count` 48kHz mono samples starting at `input`, appending every fully processed
    /// denoised frame to `output` (which is not cleared first — callers own that). Leftover
    /// samples smaller than `frameLength` are carried internally to the next call, so callers
    /// may pass arbitrarily sized chunks.
    func process(_ input: UnsafePointer<Float>, count: Int, into output: inout [Float]) {
        guard count > 0 else { return }
        ringBuffer.append(contentsOf: UnsafeBufferPointer(start: input, count: count))

        var consumed = 0
        while ringBuffer.count - consumed >= frameLength {
            ringBuffer.withUnsafeBufferPointer { buffer in
                inFrame.update(from: buffer.baseAddress!.advanced(by: consumed), count: frameLength)
            }
            let snr = df_process_frame(state, inFrame, outFrame)
            snrSum += snr
            processedFrameCount += 1
            output.append(contentsOf: UnsafeBufferPointer(start: outFrame, count: frameLength))
            consumed += frameLength
        }
        if consumed > 0 {
            ringBuffer.removeFirst(consumed)
        }
    }
}
