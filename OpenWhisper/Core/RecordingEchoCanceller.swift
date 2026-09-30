import Foundation
import os

/// The mic stream of one recording, echo-cancelled against what the Mac plays. Every mic sample
/// comes back out exactly once, in order: cancelled while paired with the reference, unchanged
/// when the reference is missing or the recording ends while the aligner still holds audio.
/// Not thread-safe; `RecordingEchoCanceller` confines it to one queue.
final class EchoCancelledStream {
    private var aligner = EchoReferenceAligner()
    private let canceller: EchoCanceller
    private(set) var inputSamples = 0
    private(set) var outputSamples = 0
    /// Mic samples that arrived without a host time and bypassed cancellation.
    private(set) var untimedSamples = 0
    /// Mic samples passed through because no reference was arriving.
    private(set) var idleSamples = 0
    private var erle: [Float] = []

    init(engine: EchoCancellationEngineKind = EchoCancellationSettings.engine, log: @escaping (String) -> Void = { _ in }) {
        canceller = EchoCanceller(engine: engine)
        canceller.log = log
    }

    var resyncs: Int { aligner.resyncs }

    /// `startIndex` = host seconds × 16000 of the first sample.
    func appendReference(_ samples: [Float], startIndex: Int) {
        aligner.appendReference(samples, startIndex: startIndex)
    }

    /// 16 kHz mic samples; returns the samples ready now (the aligner may hold up to 0.5 s).
    func process(mic: [Float], hostIndex: Int?) -> [Float] {
        inputSamples += mic.count
        guard let hostIndex else {
            // Without timestamps nothing can be paired: release what is held, then pass through.
            untimedSamples += mic.count
            return emit(release() + mic)
        }
        // ScreenCaptureKit sends nothing while the output is idle (the recording paused the music,
        // or the reference hasn't started). Waiting would keep the whole recording 0.5 s late
        // with nothing to cancel, so pass through; the next reference buffer resumes pairing.
        // Normal delivery runs 0.1–0.3 s behind the mic, well inside `maxHold`.
        guard let referenceEnd = aligner.referenceEnd,
              hostIndex - referenceEnd <= EchoReferenceAligner.maxHold else {
            idleSamples += mic.count
            return emit(release() + mic)
        }
        guard let pair = aligner.appendMic(mic, startIndex: hostIndex) else { return [] }
        let cleaned = canceller.process(mic: pair.mic, reference: pair.reference)
        erle += canceller.takeERLESamples()
        return emit(cleaned)
    }

    /// End of the recording: everything still held, unchanged.
    func finish() -> [Float] {
        emit(release())
    }

    /// Canceller remainder first: it was released by the aligner before what the aligner holds.
    private func release() -> [Float] {
        canceller.flushPending() + aligner.drain()
    }

    private func emit(_ samples: [Float]) -> [Float] {
        outputSamples += samples.count
        return samples
    }

    /// One line for the log: how much was paired and removed.
    func summary() -> String {
        let paired = aligner.takePairedPercent() ?? .nan
        let sorted = erle.sorted()
        let median = sorted.isEmpty ? Float.nan : sorted[sorted.count / 2]
        return String(format: "engine %@, paired with reference %.0f%%, ERLE median %.1f dB over %d blocks, resyncs %d, untimed %d, no reference %.1f s, in %d / out %d samples",
                      canceller.activeEngine.rawValue, paired, median, erle.count, resyncs,
                      untimedSamples, Double(idleSamples) / Double(EchoCanceller.sampleRate),
                      inputSamples, outputSamples)
    }
}

/// Echo cancellation for a dictation / wake-session recording: runs `EchoCancelledStream` on its
/// own serial queue (the canceller allocates, so it stays off the real-time input thread) and
/// feeds it the system output from its own `SystemOutputReference`.
final class RecordingEchoCanceller: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.openwhisper.recording-aec", qos: .userInitiated)
    /// Queue-confined.
    private let stream = EchoCancelledStream(log: { owLog($0) })
    /// Queue-confined: false once the recording ends, so late reference buffers are dropped.
    private var acceptsReference = true
    /// Set once in `start()`, before any recording audio reaches the queue.
    private var reference: SystemOutputReference?
    /// Set when the recording ends; a start still in flight then stops the stream it opened.
    private let finished = OSAllocatedUnfairLock(initialState: false)

    /// Never blocks the caller: the aligner releases the mic unpaired until the reference arrives.
    func start() {
        let reference = SystemOutputReference { [weak self] samples, pts in
            guard let self else { return }
            self.queue.async { self.ingestReference(samples, pts: pts) }
        }
        self.reference = reference
        Task {
            do {
                try await reference.start()
                if self.finished.withLock({ $0 }) { await reference.stop() }
            } catch {
                owLog("[AEC] Recording reference capture failed: \(error.localizedDescription) — recording without cancellation")
            }
        }
    }

    private func ingestReference(_ samples: [Float], pts: Double) {
        guard acceptsReference else { return }
        stream.appendReference(samples, startIndex: Int((pts * Double(EchoCanceller.sampleRate)).rounded()))
    }

    /// Queue only.
    func process(mic: [Float], hostIndex: Int?) -> [Float] {
        stream.process(mic: mic, hostIndex: hostIndex)
    }

    /// Queue only. Stops the reference and returns the held tail.
    func finish() -> [Float] {
        acceptsReference = false
        finished.withLock { $0 = true }
        let tail = stream.finish()
        owLog("[AEC] Recording summary: " + stream.summary())
        if let reference { Task { await reference.stop() } }
        return tail
    }
}
