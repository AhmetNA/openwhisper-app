import FluidAudio
import Foundation
import os

/// Silero VAD (FluidAudio's Core ML build, 256 ms chunks) in front of the wake-word model:
/// `WakeWordActivityGate` opens only for loud blocks that are also speech, so typing, trackpad
/// clicks and other bumps no longer run the embedding model.
///
/// Inference runs off the listener queue, so its verdict trails the audio by one chunk plus
/// inference (~300 ms). That stays well inside the gate's 16-block (1.28 s) backfill: when the
/// gate opens late, the skipped start of "Jarvis" is rebuilt before it is scored.
///
/// Fails open: while the model is loading, has failed, or has not answered for `staleSeconds`,
/// `voice(at:)` returns nil and the gate falls back to energy alone. A deaf Jarvis is worse
/// than a few wasted embeddings.
final class WakeVoiceActivity: @unchecked Sendable {
    /// Speech probability counted as voice. Low on purpose: a false "speech" costs a little CPU,
    /// a false "no speech" loses a wake. Override: `defaults write com.openwhisper.app wakeWordVadThreshold 0.5`
    static var threshold: Float {
        let stored = UserDefaults.standard.float(forKey: "wakeWordVadThreshold")
        return stored > 0 ? stored : 0.3
    }
    /// Voice is held this long after the last speech chunk (pauses between words, the end of "Jarvis").
    static let holdSeconds: TimeInterval = 1.0
    /// No verdict for this long while audio flows → the VAD is stalled; fall back to energy.
    static let staleSeconds: TimeInterval = 1.0
    /// `defaults write com.openwhisper.app wakeWordVadEnabled -bool NO` turns it off.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "wakeWordVadEnabled") as? Bool ?? true
    }

    private enum Item {
        case chunk([Float])
        case reset
    }

    private struct Status {
        var loaded = false
        var failed = false
        var lastResultAt: TimeInterval?
        var lastSpeechAt: TimeInterval?
        var chunks = 0
        var speechChunks = 0
        var errors = 0
    }

    private let status = OSAllocatedUnfairLock(initialState: Status())
    private let continuation: AsyncStream<Item>.Continuation
    private var consumer: Task<Void, Never>?
    /// Listener queue only: samples waiting to fill a 256 ms chunk.
    private var pending: [Float] = []

    init() {
        // Only the newest chunks matter; while the model loads, older ones are dropped.
        let (stream, continuation) = AsyncStream<Item>.makeStream(bufferingPolicy: .bufferingNewest(4))
        self.continuation = continuation
        let status = status
        let threshold = Self.threshold
        consumer = Task.detached(priority: .utility) {
            let manager: VadManager
            let t0 = Date()
            do {
                manager = try await VadManager(config: VadConfig(defaultThreshold: threshold, computeUnits: .cpuAndNeuralEngine))
            } catch {
                status.withLock { $0.failed = true }
                owLog("[WakeVAD] Model load failed, energy gate only: \(error)")
                return
            }
            status.withLock { $0.loaded = true }
            owLog(String(format: "[WakeVAD] Silero VAD loaded in %.0f ms, threshold %.2f", Date().timeIntervalSince(t0) * 1000, threshold))
            var state = await manager.makeStreamState()
            for await item in stream {
                switch item {
                case .reset:
                    state = await manager.makeStreamState()
                case .chunk(let samples):
                    do {
                        let result = try await manager.processStreamingChunk(samples, state: state)
                        state = result.state
                        let now = ProcessInfo.processInfo.systemUptime
                        let speech = result.probability >= threshold
                        status.withLock {
                            $0.lastResultAt = now
                            $0.chunks += 1
                            if speech {
                                $0.lastSpeechAt = now
                                $0.speechChunks += 1
                            }
                        }
                    } catch {
                        // Keep going: the stale check fails open meanwhile.
                        let first = status.withLock { s -> Bool in s.errors += 1; return s.errors == 1 }
                        if first { owLog("[WakeVAD] Inference failed (further errors counted only): \(error)") }
                        state = await manager.makeStreamState()
                    }
                }
            }
        }
    }

    deinit {
        continuation.finish()
        consumer?.cancel()
    }

    /// Listener queue. `samples` are 16 kHz mono in -1…1, already lifted by the listener's gain.
    func feed(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        while pending.count >= VadManager.chunkSize {
            continuation.yield(.chunk(Array(pending.prefix(VadManager.chunkSize))))
            pending.removeFirst(VadManager.chunkSize)
        }
    }

    /// Listener queue: the mic (re)started, so the model's memory of the old stream is dropped.
    func reset() {
        pending.removeAll(keepingCapacity: true)
        continuation.yield(.reset)
    }

    /// true = speech within the hold, false = no speech, nil = no reliable verdict (fail open).
    func voice(at now: TimeInterval) -> Bool? {
        status.withLock { s in
            guard s.loaded, !s.failed, let last = s.lastResultAt, now - last <= Self.staleSeconds else { return nil }
            guard let speech = s.lastSpeechAt else { return false }
            return now - speech <= Self.holdSeconds
        }
    }

    /// For the 10 s log line: "speech 3/39 chunks" since the last call, or why it is not gating.
    func takeSummary(at now: TimeInterval) -> String {
        status.withLock { s in
            defer { s.chunks = 0; s.speechChunks = 0 }
            if s.failed { return "failed" }
            if !s.loaded { return "loading" }
            let stale = s.lastResultAt.map { now - $0 > Self.staleSeconds } ?? true
            return "speech \(s.speechChunks)/\(s.chunks) chunks\(stale ? " (stale, not gating)" : "")"
        }
    }
}
