import AVFoundation
import Foundation
import os

/// The mic stream of one recording, echo-cancelled against what the Mac plays. Every mic sample
/// comes back out exactly once, in order: cancelled while paired with the reference, unchanged
/// when the reference is missing or the recording ends while the aligner still holds audio.
/// Not thread-safe; `RecordingEchoCanceller` confines it to one queue.
final class EchoCancelledStream {
    private var aligner = EchoReferenceAligner()
    private var canceller: EchoCanceller
    private(set) var inputSamples = 0
    private(set) var outputSamples = 0
    /// Mic samples that arrived without a host time and bypassed cancellation.
    private(set) var untimedSamples = 0
    /// Mic samples passed through because no reference was arriving.
    private(set) var idleSamples = 0
    private var erle: [Float] = []
    /// The speakers played something audible that the filter worked on.
    var heardPlayback: Bool { !erle.isEmpty }

    init(engine: EchoCancellationEngineKind = EchoCancellationSettings.engine, log: @escaping (String) -> Void = { _ in }) {
        canceller = EchoCanceller(engine: engine)
        canceller.log = log
        if EchoCancellationSettings.recordingSuppressesResidual { canceller.residualGate = ResidualEchoGate() }
    }

    var resyncs: Int { aligner.resyncs }
    private var warm = false
    /// After `adopt`: mic before `lowerBound` was already cancelled on the listener (its output
    /// is gone) and goes out raw; mic in the range is held in the adopted aligner or filter and
    /// dropped here; from `upperBound` on the stream continues the listener's without a seam.
    private var handoffSpan: Range<Int>?

    /// Continues from the wake listener's converged filter, reference history and held mic (see
    /// `EchoStateHandoff`) instead of starting cold. Before the first sample only. Replaying the
    /// wake preroll through the filter instead stepped it back in time and undid its convergence.
    func adopt(_ state: EchoStateHandoff.State) {
        aligner = state.aligner
        _ = state.canceller.takeERLESamples()
        state.canceller.residualGate = canceller.residualGate
        state.canceller.log = canceller.log
        canceller = state.canceller
        // The filter's part block comes out before what the aligner holds.
        handoffSpan = aligner.heldMic.map { ($0.lowerBound - canceller.pendingCount)..<$0.upperBound }
        inputSamples += handoffSpan?.count ?? 0
        warm = true
    }

    /// `startIndex` = host seconds × 16000 of the first sample.
    func appendReference(_ samples: [Float], startIndex: Int) {
        aligner.appendReference(samples, startIndex: startIndex)
    }

    /// 16 kHz mic samples; returns the samples ready now (the aligner may hold up to 0.5 s).
    func process(mic: [Float], hostIndex: Int?) -> [Float] {
        if let span = handoffSpan, let hostIndex {
            let raw = min(max(span.lowerBound - hostIndex, 0), mic.count)
            let resume = max(raw, min(max(span.upperBound - hostIndex, 0), mic.count))
            inputSamples += raw
            let head = emit(Array(mic[0..<raw]))
            guard resume < mic.count else { return head }
            handoffSpan = nil
            return head + process(mic: Array(mic[resume...]), hostIndex: hostIndex + resume)
        }
        handoffSpan = nil
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
        let gate = canceller.residualGate.map { String(format: ", residual gate muted %d/%d echo blocks", $0.mutedBlocks, $0.activeBlocks) } ?? ""
        return String(format: "%@engine %@, paired with reference %.0f%%, ERLE median %.1f dB over %d blocks, resyncs %d, untimed %d, no reference %.1f s, in %d / out %d samples",
                      warm ? "warm start from the wake listener, " : "", canceller.activeEngine.rawValue, paired, median, erle.count, resyncs,
                      untimedSamples, Double(idleSamples) / Double(EchoCanceller.sampleRate),
                      inputSamples, outputSamples) + gate
    }
}

/// Echo cancellation for a dictation / wake-session recording: runs `EchoCancelledStream` on its
/// own serial queue (the canceller allocates, so it stays off the real-time input thread) and
/// feeds it the system output from its own `SystemOutputReference`, or from the wake listener's
/// when the recording continues its mic stream (`EchoStateHandoff`). DeepFilterNet, when on,
/// runs here after the canceller (`PostEchoDenoiser`): the linear filter cannot follow a
/// denoiser's changing gain, so cancelling its output left the speakers' sound in the recording.
final class RecordingEchoCanceller: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.openwhisper.recording-aec", qos: .userInitiated)
    /// Queue-confined.
    private let stream = EchoCancelledStream(log: { owLog($0) })
    /// Queue-confined.
    private let denoiser: PostEchoDenoiser?
    /// Queue-confined: false once the recording ends, so late reference buffers are dropped.
    private var acceptsReference = true
    /// Set once in `start()`, before any recording audio reaches the queue.
    private var reference: SystemOutputReference?
    private let handoff: EchoStateHandoff?
    /// Set once the recording hears playback; the session reads it per batch.
    private let playbackHeard: OSAllocatedUnfairLock<Bool>?
    /// Queue-confined: the handoff's filter state was taken (or given up on).
    private var handoffResolved = false
    /// Set when the recording ends; a start still in flight then stops the stream it opened.
    private let finished = OSAllocatedUnfairLock(initialState: false)

    init(handoff: EchoStateHandoff? = nil, denoiser: PostEchoDenoiser? = nil, playbackHeard: OSAllocatedUnfairLock<Bool>? = nil) {
        self.handoff = handoff
        self.denoiser = denoiser
        self.playbackHeard = playbackHeard
        handoffResolved = handoff == nil
    }

    /// Never blocks the caller: the aligner releases the mic unpaired until the reference arrives.
    func start() {
        let sink: SystemOutputReference.Handler = { [weak self] samples, pts in
            guard let self else { return }
            self.queue.async { self.ingestReference(samples, pts: pts) }
        }
        if let handoff {
            reference = handoff.reference
            handoff.attach(sink)
            owLog("[AEC] Recording continues the wake listener's reference stream")
            return
        }
        let reference = SystemOutputReference(handler: sink)
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
        resolveHandoff()
        stream.appendReference(samples, startIndex: Int((pts * Double(EchoCanceller.sampleRate)).rounded()))
    }

    /// Queue: the listener hands its filter over on its own queue, normally long before the
    /// first recording sample; wait briefly rather than start cold.
    private func resolveHandoff() {
        guard !handoffResolved, let handoff else { return }
        handoffResolved = true
        let t0 = Date()
        let state = handoff.waitForState(timeout: 0.15)
        let waited = Date().timeIntervalSince(t0) * 1000
        if let state {
            stream.adopt(state)
            owLog(String(format: "[AEC] Recording continues the wake listener's converged echo filter (waited %.0f ms)", waited))
        } else {
            owLog(String(format: "[AEC] Wake listener had no echo filter to hand over (waited %.0f ms) — starting cold", waited))
        }
    }

    /// Queue only.
    func process(mic: [Float], hostIndex: Int?) -> [Float] {
        resolveHandoff()
        let cleaned = stream.process(mic: mic, hostIndex: hostIndex)
        if let playbackHeard, stream.heardPlayback { playbackHeard.withLock { $0 = true } }
        return denoiser?.process(cleaned) ?? cleaned
    }

    /// Queue only. Stops the reference and returns the held tail.
    func finish() -> [Float] {
        acceptsReference = false
        finished.withLock { $0 = true }
        resolveHandoff()
        var tail = stream.finish()
        if let denoiser { tail = denoiser.process(tail) + denoiser.finish() }
        owLog("[AEC] Recording summary: " + stream.summary())
        if let reference { Task { await reference.stop() } }
        return tail
    }
}

/// The wake listener's running echo reference and converged canceller, passed to the recording
/// that continues its mic stream. Restarting both for every recording (new ScreenCaptureKit
/// stream, filter from zero) left 2.5–3.6 dB of cancellation over a whole command, against ~13 dB
/// on the listener (15 Oct 2026). Thread-safe: the listener queue delivers the state, the
/// reference queue delivers buffers, the recording queue takes both.
final class EchoStateHandoff: @unchecked Sendable {
    struct State {
        var aligner: EchoReferenceAligner
        let canceller: EchoCanceller
    }

    let reference: SystemOutputReference
    private let lock = NSCondition()
    private var delivered = false
    private var state: State?
    private var buffered: [([Float], Double)] = []
    private var sink: SystemOutputReference.Handler?
    private var released = false

    /// Redirects the stream's buffers here at once; they wait until `attach`.
    init(reference: SystemOutputReference) {
        self.reference = reference
        reference.setHandler { [weak self] samples, pts in self?.appendReference(samples, pts: pts) }
    }

    /// Listener queue: its filter, or nil when it wasn't cancelling (silent reference).
    func deliver(_ state: State?) {
        lock.lock()
        self.state = state
        delivered = true
        lock.broadcast()
        lock.unlock()
    }

    /// Reference queue (via the stream's handler).
    func appendReference(_ samples: [Float], pts: Double) {
        lock.lock()
        let sink = self.sink
        if sink == nil, !released { buffered.append((samples, pts)) }
        lock.unlock()
        sink?(samples, pts)
    }

    /// The recording takes the stream: buffers held so far, then live ones, go to `sink`.
    func attach(_ sink: @escaping SystemOutputReference.Handler) {
        lock.lock()
        let held = buffered
        buffered = []
        self.sink = sink
        lock.unlock()
        for (samples, pts) in held { sink(samples, pts) }
    }

    func waitForState(timeout: TimeInterval) -> State? {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !delivered, lock.wait(until: deadline) {}
        defer { state = nil }
        return state
    }

    /// Nobody took it (no echo cancellation for this recording, or setup failed): stop the stream.
    func release() {
        lock.lock()
        guard sink == nil, !released else { lock.unlock(); return }
        released = true
        buffered = []
        lock.unlock()
        reference.setHandler { _, _ in }
        Task { await reference.stop() }
    }
}

/// DeepFilterNet on the echo-cancelled 16 kHz stream: up to its 48 kHz, through the model, and
/// back. Queue-confined to `RecordingEchoCanceller`; the real-time path skips DeepFilterNet for
/// these recordings, so the processor has a single user.
final class PostEchoDenoiser {
    private let processor: DeepFilterProcessor
    private let up: AVAudioConverter
    private let down: AVAudioConverter
    private let lowFormat: AVAudioFormat
    private let highFormat: AVAudioFormat
    private var scratch: [Float] = []

    init?(processor: DeepFilterProcessor) {
        guard let low = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(EchoCanceller.sampleRate), channels: 1, interleaved: false),
              let high = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: DeepFilterProcessor.sampleRate, channels: 1, interleaved: false),
              let up = AVAudioConverter(from: low, to: high),
              let down = AVAudioConverter(from: high, to: low) else { return nil }
        self.processor = processor
        self.up = up
        self.down = down
        lowFormat = low
        highFormat = high
    }

    func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let high = Self.convert(samples, with: up, from: lowFormat, to: highFormat, end: false)
        scratch.removeAll(keepingCapacity: true)
        high.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            processor.process(base, count: buffer.count, into: &scratch)
        }
        return Self.convert(scratch, with: down, from: highFormat, to: lowFormat, end: false)
    }

    /// The converters' delayed tail (DeepFilterNet's own partial frame, under 10 ms, is dropped).
    func finish() -> [Float] {
        let high = Self.convert([], with: up, from: lowFormat, to: highFormat, end: true)
        scratch.removeAll(keepingCapacity: true)
        high.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
            processor.process(base, count: buffer.count, into: &scratch)
        }
        let tail = Self.convert(scratch, with: down, from: highFormat, to: lowFormat, end: false)
            + Self.convert([], with: down, from: highFormat, to: lowFormat, end: true)
        if processor.processedFrameCount > 0 {
            owLog(String(format: "[DeepFilter] Recording summary (after echo cancellation): frames=%d processedMs=%.1f avgSNR=%.2fdB",
                         processor.processedFrameCount, processor.processedDurationMs, processor.averageSNR))
        }
        return tail
    }

    private static func convert(_ samples: [Float], with converter: AVAudioConverter,
                                from source: AVAudioFormat, to target: AVAudioFormat, end: Bool) -> [Float] {
        var input: AVAudioPCMBuffer?
        if !samples.isEmpty {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            input = buffer
        }
        let capacity = AVAudioFrameCount(Double(samples.count) * target.sampleRate / source.sampleRate) + 1024
        var out: [Float] = []
        var supplied = false
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
                if supplied || input == nil {
                    inputStatus.pointee = end ? .endOfStream : .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if error != nil { break }
            if let data = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                out += UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))
            }
            // .haveData with a full buffer may hold more; anything else means drained.
            if status != .haveData || buffer.frameLength < capacity { break }
        }
        return out
    }
}
