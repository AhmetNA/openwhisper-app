import Accelerate
import Foundation

/// Removes the Mac's own output (music on the speakers) from the wake-word microphone, using
/// what the Mac is playing (`SystemOutputReference`) as the echo reference.
///
/// Voice processing (VPIO) would do this too, but it ducks the music and drops the input to
/// silence for seconds at a time (see `WakeWordListener`); this canceller never changes the
/// output and never mutes the input. Linear only: no residual-echo suppression, whose
/// artifacts could cost openWakeWord more score than the echo it removes.
///
/// Toggle: `defaults write com.openwhisper.app wakeWordEchoCancellation -bool NO`
enum EchoCancellationSettings {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "wakeWordEchoCancellation") as? Bool ?? true
    }
    /// Writes the paired mic / reference WAVs of each music session for offline tuning.
    /// `defaults write com.openwhisper.app wakeWordEchoDump -bool YES`
    static var dumpsAudio: Bool {
        UserDefaults.standard.bool(forKey: "wakeWordEchoDump")
    }
}

// MARK: - Adaptive filter

/// Partitioned-block frequency-domain adaptive filter (overlap-save, constrained gradient):
/// `blockSize * partitions` taps of echo path, normalized per bin by the reference power.
/// All buffers are allocated once and the spectral math is vDSP: it shares the listener's
/// queue with the wake-word model, in a debug build.
final class PartitionedEchoFilter {
    let blockSize: Int
    let partitions: Int
    private let n: Int
    private let forward: vDSP_DFT_Setup
    private let inverse: vDSP_DFT_Setup
    /// 1.0 measured best on the test song (≈14 dB after 3 s, 22 dB after 4 s; 0.5 took twice
    /// as long, 1.5 plateaued lower).
    private let stepSize: Float

    /// Filter spectra and reference spectra (ring, newest at `head`), `partitions × n` each.
    private let w: Spectrum
    private let x: Spectrum
    private var head = 0
    private let previousReference: UnsafeMutablePointer<Float>
    // Scratch.
    private let time: UnsafeMutablePointer<Float>
    private let zeros: UnsafeMutablePointer<Float>
    private let spare: UnsafeMutablePointer<Float>
    private let y: Spectrum
    private let e: Spectrum
    private let g: Spectrum
    private let power: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>

    /// Split-complex storage for `count` spectra of `n` bins.
    private final class Spectrum {
        let real: UnsafeMutablePointer<Float>
        let imag: UnsafeMutablePointer<Float>
        let n: Int
        init(n: Int, count: Int = 1) {
            self.n = n
            real = .allocate(capacity: n * count); real.initialize(repeating: 0, count: n * count)
            imag = .allocate(capacity: n * count); imag.initialize(repeating: 0, count: n * count)
        }
        deinit { real.deallocate(); imag.deallocate() }
        func at(_ index: Int) -> DSPSplitComplex {
            DSPSplitComplex(realp: real + index * n, imagp: imag + index * n)
        }
        func clear(count: Int = 1) {
            real.update(repeating: 0, count: n * count)
            imag.update(repeating: 0, count: n * count)
        }
    }

    init(blockSize: Int = 256, partitions: Int = 16, stepSize: Float = 1.0) {
        self.stepSize = stepSize
        self.blockSize = blockSize
        self.partitions = partitions
        n = blockSize * 2
        forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
        inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE)!
        w = Spectrum(n: n, count: partitions)
        x = Spectrum(n: n, count: partitions)
        y = Spectrum(n: n); e = Spectrum(n: n); g = Spectrum(n: n)
        func buffer(_ count: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: 0, count: count)
            return p
        }
        previousReference = buffer(blockSize)
        time = buffer(n); zeros = buffer(n); spare = buffer(n)
        power = buffer(n); magnitudes = buffer(n)
    }

    deinit {
        vDSP_DFT_DestroySetup(forward)
        vDSP_DFT_DestroySetup(inverse)
        for p in [previousReference, time, zeros, spare, power, magnitudes] { p.deallocate() }
    }

    func reset() {
        w.clear(count: partitions)
        x.clear(count: partitions)
        previousReference.update(repeating: 0, count: blockSize)
        head = 0
    }

    /// One block: `mic` and `reference` are `blockSize` long. Returns `mic` minus the echo
    /// estimate; adapts toward it scaled by `rate` (0 freezes adaptation).
    func process(mic: [Float], reference: [Float], rate: Float) -> [Float] {
        let len = vDSP_Length(n)
        // Newest reference spectrum over [previous block, this block].
        head = (head + partitions - 1) % partitions
        time.update(from: previousReference, count: blockSize)
        reference.withUnsafeBufferPointer { (time + blockSize).update(from: $0.baseAddress!, count: blockSize) }
        previousReference.update(from: time + blockSize, count: blockSize)
        let newest = x.at(head)
        vDSP_DFT_Execute(forward, time, zeros, newest.realp, newest.imagp)

        // Echo estimate: sum of filter × delayed reference, last half of the inverse transform.
        y.clear()
        var ySplit = y.at(0)
        for p in 0..<partitions {
            var wp = w.at(p), xk = x.at((head + p) % partitions)
            vDSP_zvma(&wp, 1, &xk, 1, &ySplit, 1, &ySplit, 1, len)
        }
        vDSP_DFT_Execute(inverse, y.real, y.imag, time, spare)
        var inverseScale = 1 / Float(n)
        vDSP_vsmul(time + blockSize, 1, &inverseScale, time + blockSize, 1, vDSP_Length(blockSize))
        var output = [Float](repeating: 0, count: blockSize)
        vDSP_vsub(time + blockSize, 1, mic, 1, &output, 1, vDSP_Length(blockSize))

        guard rate > 0 else { return output }
        // Per-bin normalization by the reference power across all partitions, regularized
        // relative to its mean so bins the music leaves empty don't blow up.
        power.update(repeating: 0, count: n)
        for k in 0..<partitions {
            var xk = x.at(k)
            vDSP_zvmags(&xk, 1, magnitudes, 1, len)
            vDSP_vadd(power, 1, magnitudes, 1, power, 1, len)
        }
        var meanPower: Float = 0
        vDSP_meanv(power, 1, &meanPower, len)
        guard meanPower > 1e-10 else { return output }
        var regularization = max(meanPower * 0.01, 1e-10)
        vDSP_vsadd(power, 1, &regularization, power, 1, len)
        var step = stepSize * rate
        vDSP_svdiv(&step, power, 1, power, 1, len) // power now holds the per-bin step

        // Error spectrum of [zeros, output], scaled by the step.
        time.update(repeating: 0, count: blockSize)
        output.withUnsafeBufferPointer { (time + blockSize).update(from: $0.baseAddress!, count: blockSize) }
        vDSP_DFT_Execute(forward, time, zeros, e.real, e.imag)
        vDSP_vmul(e.real, 1, power, 1, e.real, 1, len)
        vDSP_vmul(e.imag, 1, power, 1, e.imag, 1, len)

        var eSplit = e.at(0), gSplit = g.at(0)
        for p in 0..<partitions {
            // Gradient conj(X) · E, constrained to a causal blockSize-tap partition.
            var xk = x.at((head + p) % partitions)
            g.clear()
            vDSP_zvcma(&xk, 1, &eSplit, 1, &gSplit, 1, &gSplit, 1, len)
            vDSP_DFT_Execute(inverse, g.real, g.imag, time, spare)
            vDSP_vsmul(time, 1, &inverseScale, time, 1, vDSP_Length(blockSize))
            (time + blockSize).update(repeating: 0, count: blockSize)
            vDSP_DFT_Execute(forward, time, zeros, g.real, g.imag)
            let wp = w.at(p)
            vDSP_vadd(wp.realp, 1, g.real, 1, wp.realp, 1, len)
            vDSP_vadd(wp.imagp, 1, g.imag, 1, wp.imagp, 1, len)
        }
        return output
    }
}

// MARK: - Bulk delay

/// GCC-PHAT between mic and reference: how many samples the echo trails the reference.
enum EchoDelayEstimator {
    struct Estimate: Equatable {
        let delay: Int
        /// Peak over the mean magnitude in the searched range; a real echo gives a sharp peak.
        let confidence: Float
    }

    /// `mic` is the window to explain; `reference` covers the same span plus `maxDelay`
    /// samples before it (`reference.count == mic.count + maxDelay`). Nil when either is silent.
    static func estimate(mic: [Float], reference: [Float], maxDelay: Int) -> Estimate? {
        guard reference.count == mic.count + maxDelay, !mic.isEmpty else { return nil }
        var micEnergy: Float = 0, refEnergy: Float = 0
        vDSP_svesq(mic, 1, &micEnergy, vDSP_Length(mic.count))
        vDSP_svesq(reference, 1, &refEnergy, vDSP_Length(reference.count))
        guard micEnergy > 1e-6, refEnergy > 1e-6 else { return nil }

        var n = 1024
        while n < reference.count + mic.count { n *= 2 }
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD),
              let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE) else { return nil }
        defer { vDSP_DFT_DestroySetup(forward); vDSP_DFT_DestroySetup(inverse) }

        func transform(_ x: [Float]) -> ([Float], [Float]) {
            let real = x + [Float](repeating: 0, count: n - x.count)
            let imag = [Float](repeating: 0, count: n)
            var r = [Float](repeating: 0, count: n), i = [Float](repeating: 0, count: n)
            vDSP_DFT_Execute(forward, real, imag, &r, &i)
            return (r, i)
        }
        let (mr, mi) = transform(mic)
        let (rr, ri) = transform(reference)
        // corr[s] = Σ mic[t] · reference[t + s]  ⇒  conj(M) · R, whitened (PHAT).
        var cr = [Float](repeating: 0, count: n), ci = [Float](repeating: 0, count: n)
        for b in 0..<n {
            let re = mr[b] * rr[b] + mi[b] * ri[b]
            let im = mr[b] * ri[b] - mi[b] * rr[b]
            let magnitude = max((re * re + im * im).squareRoot(), 1e-12)
            cr[b] = re / magnitude
            ci[b] = im / magnitude
        }
        var outR = [Float](repeating: 0, count: n), outI = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(inverse, cr, ci, &outR, &outI)

        // The echo at mic[t] is reference[t + maxDelay - delay] ⇒ peak at s = maxDelay - delay.
        var best = -Float.infinity, bestShift = 0, sum: Float = 0
        for s in 0...maxDelay {
            let v = outR[s]
            sum += abs(v)
            if v > best { best = v; bestShift = s }
        }
        let mean = sum / Float(maxDelay + 1)
        guard mean > 0 else { return nil }
        return Estimate(delay: maxDelay - bestShift, confidence: best / mean)
    }
}

// MARK: - Aligned stream

/// Cancels echo on a mic stream paired sample-for-sample with a reference stream that already
/// runs `EchoCanceller.lookahead` samples ahead of the mic's timestamps (so an echo that
/// appears "early" is still within reach). Finds the bulk delay itself.
final class EchoCanceller {
    static let sampleRate = 16_000
    /// How far the paired reference runs ahead of the mic's own timestamps.
    static let lookahead = 1_600
    /// Largest paired delay searched: lookahead + 500 ms of real latency.
    static let maxDelay = lookahead + 8_000
    /// The filter starts this far before the estimated delay (the echo builds up before its peak).
    private static let delayMargin = 480

    private let filter = PartitionedEchoFilter()
    private var blockSize: Int { filter.blockSize }
    private var micPending: [Float] = []
    private var refPending: [Float] = []
    /// Reference history, enough for the largest delay plus one block.
    private var referenceHistory: [Float]
    /// Paired samples the filter currently reads the reference behind the mic.
    private(set) var filterDelay: Int
    private var delayCandidate: Int?

    private var estimatorMic: [Float] = []
    private var estimatorRef: [Float] = []
    private var samplesSinceEstimate = 0
    private static let estimatorWindow = 16_000
    private static let estimateEvery = 32_000

    private var micPower: Float = 0
    private var errorPower: Float = 0
    private var divergentBlocks = 0
    /// Per-block ERLE while the reference plays, for the periodic log.
    private(set) var erleSamples: [Float] = []
    var log: (String) -> Void = { _ in }

    init() {
        filterDelay = Self.lookahead - Self.delayMargin
        referenceHistory = [Float](repeating: 0, count: Self.maxDelay + 2 * 256)
    }

    func reset() {
        filter.reset()
        micPending.removeAll(); refPending.removeAll()
        referenceHistory = [Float](repeating: 0, count: referenceHistory.count)
        estimatorMic.removeAll(); estimatorRef.removeAll()
        samplesSinceEstimate = 0
        micPower = 0; errorPower = 0; divergentBlocks = 0
        erleSamples.removeAll()
    }

    /// Same-length chunks; returns the cleaned samples available so far (whole blocks only,
    /// so output may lag input by up to one block).
    func process(mic: [Float], reference: [Float]) -> [Float] {
        precondition(mic.count == reference.count)
        micPending += mic
        refPending += reference
        collectForEstimate(mic: mic, reference: reference)
        var out: [Float] = []
        while micPending.count >= blockSize {
            let micBlock = Array(micPending.prefix(blockSize))
            let refBlock = Array(refPending.prefix(blockSize))
            micPending.removeFirst(blockSize)
            refPending.removeFirst(blockSize)
            out += processBlock(mic: micBlock, reference: refBlock)
        }
        return out
    }

    func takeERLESamples() -> [Float] {
        defer { erleSamples.removeAll(keepingCapacity: true) }
        return erleSamples
    }

    private func processBlock(mic: [Float], reference: [Float]) -> [Float] {
        referenceHistory.removeFirst(blockSize)
        referenceHistory += reference
        // The block of reference `filterDelay` samples behind this mic block.
        let end = referenceHistory.count - filterDelay
        let delayed = Array(referenceHistory[(end - blockSize)..<end])

        var refEnergy: Float = 0, micEnergy: Float = 0
        vDSP_svesq(delayed, 1, &refEnergy, vDSP_Length(blockSize))
        vDSP_svesq(mic, 1, &micEnergy, vDSP_Length(blockSize))
        let referenceActive = refEnergy > 1e-7

        // No double-talk detector: measured on music, one froze adaptation on every new note
        // (ERLE 8 dB vs 22 dB without) and never helped the wake score, even after 5 s of talking
        // over the music. The per-bin normalization keeps the voice's pull on the filter in
        // proportion to how loud the music is, which is exactly when cancelling matters.
        let output = filter.process(mic: mic, reference: delayed, rate: referenceActive ? 1 : 0)
        var errorEnergy: Float = 0
        vDSP_svesq(output, 1, &errorEnergy, vDSP_Length(blockSize))
        let a: Float = 0.9
        micPower = a * micPower + (1 - a) * micEnergy
        errorPower = a * errorPower + (1 - a) * errorEnergy

        if referenceActive, micEnergy > 1e-9 {
            erleSamples.append(10 * log10(micEnergy / max(errorEnergy, 1e-12)))
        }
        // Never make the mic worse: a filter that adds energy for ~0.5 s has diverged.
        if errorPower > 2 * micPower, micPower > 1e-9 {
            divergentBlocks += 1
            if divergentBlocks > 30 {
                log("[AEC] Filter diverged — reset")
                filter.reset()
                errorPower = micPower
                divergentBlocks = 0
            }
        } else {
            divergentBlocks = 0
        }
        return errorPower > 2 * micPower ? mic : output
    }

    private func collectForEstimate(mic: [Float], reference: [Float]) {
        let keep = Self.estimatorWindow + Self.maxDelay
        estimatorMic += mic
        estimatorRef += reference
        if estimatorMic.count > keep { estimatorMic.removeFirst(estimatorMic.count - keep) }
        if estimatorRef.count > keep { estimatorRef.removeFirst(estimatorRef.count - keep) }
        samplesSinceEstimate += mic.count
        guard samplesSinceEstimate >= Self.estimateEvery, estimatorMic.count == keep else { return }
        samplesSinceEstimate = 0
        let micWindow = Array(estimatorMic.suffix(Self.estimatorWindow))
        guard let estimate = EchoDelayEstimator.estimate(mic: micWindow, reference: estimatorRef,
                                                         maxDelay: Self.maxDelay) else { return }
        let latencyMs = Double(estimate.delay - Self.lookahead) / 16
        log(String(format: "[AEC] Delay estimate %.1f ms (confidence %.1f)", latencyMs, estimate.confidence))
        guard estimate.confidence >= 8 else { return }
        // Two agreeing estimates in a row before moving the filter.
        defer { delayCandidate = estimate.delay }
        guard let previous = delayCandidate, abs(previous - estimate.delay) <= 48 else { return }
        // Resetting throws away seconds of adaptation: only move when the direct path is about
        // to fall outside the filter, or leaves it less than half its length for the tail.
        let target = max(0, estimate.delay - Self.delayMargin)
        let taps = filter.blockSize * filter.partitions
        let covered = (filterDelay + 160)...(filterDelay + taps / 2)
        if !covered.contains(estimate.delay) {
            log(String(format: "[AEC] Filter delay %.1f → %.1f ms (reset)",
                       Double(filterDelay - Self.lookahead) / 16, Double(target - Self.lookahead) / 16))
            filterDelay = target
            filter.reset()
            errorPower = micPower
        }
    }
}

// MARK: - Timestamp pairing

/// Pairs mic samples with the reference by host-clock sample index, holding the mic back
/// until the reference for that span (plus `EchoCanceller.lookahead`) has arrived.
struct EchoReferenceAligner {
    /// Longest the mic waits for the reference; past this, the missing reference is silence
    /// (the output stopped, and ScreenCaptureKit stops sending buffers with it).
    static let maxHold = 8_000
    private static let capacity = 16_000 * 4

    private var ring = [Float](repeating: 0, count: capacity)
    /// One past the newest reference index written; nil before the first buffer.
    private(set) var referenceEnd: Int?
    private var micPending: [Float] = []
    private var micPendingStart = 0
    private var micNext: Int?
    private(set) var resyncs = 0
    /// Released mic samples, and how many of them had arrived reference (the rest got
    /// silence): a low share means the clocks disagree or the reference stalls.
    private(set) var releasedSamples = 0
    private(set) var pairedSamples = 0
    private var unpaired: [Float] = []

    /// `startIndex` = host seconds × 16000 of the first sample.
    mutating func appendReference(_ samples: [Float], startIndex: Int) {
        let cap = Self.capacity
        let end = startIndex + samples.count
        if let current = referenceEnd, startIndex > current {
            // A gap (playback paused): silence, not stale samples from the last lap.
            for i in current..<min(startIndex, current + cap) { ring[((i % cap) + cap) % cap] = 0 }
        }
        for (k, v) in samples.enumerated() { ring[(((startIndex + k) % cap) + cap) % cap] = v }
        referenceEnd = max(referenceEnd ?? end, end)
    }

    /// Adds mic samples and returns the (mic, reference) pairs now ready.
    mutating func appendMic(_ samples: [Float], startIndex: Int) -> (mic: [Float], reference: [Float])? {
        // Follow the resampler's own count; resync only when the clock says we've slipped.
        if let next = micNext, abs(startIndex - next) <= 320 {
            // keep continuous indexing
        } else {
            if micNext != nil { resyncs += 1 }
            // The held audio still goes out (unpaired): it may hold the "Jarvis".
            unpaired += micPending
            micPending.removeAll()
            micPendingStart = startIndex
            micNext = startIndex
        }
        micPending += samples
        micNext! += samples.count

        let needEnd = micPendingStart + micPending.count + EchoCanceller.lookahead
        // Before any reference, nothing is "available": the mic goes out after `maxHold`.
        let available = referenceEnd ?? (micPendingStart + EchoCanceller.lookahead)
        var releaseCount = max(0, min(micPending.count, available - EchoCanceller.lookahead - micPendingStart))
        if available >= needEnd {
            releaseCount = micPending.count
        } else if micPending.count - releaseCount > Self.maxHold {
            releaseCount = micPending.count - Self.maxHold
        }
        guard releaseCount > 0 || !unpaired.isEmpty else { return nil }
        let mic = Array(micPending.prefix(releaseCount))
        let cap = Self.capacity
        var reference = [Float](repeating: 0, count: releaseCount)
        for k in 0..<releaseCount {
            let index = micPendingStart + k + EchoCanceller.lookahead
            // Only indices the ring still holds and that have arrived.
            if index < available, index >= available - cap {
                reference[k] = ring[((index % cap) + cap) % cap]
                pairedSamples += 1
            }
        }
        releasedSamples += releaseCount
        micPending.removeFirst(releaseCount)
        micPendingStart += releaseCount
        defer { unpaired.removeAll() }
        return (unpaired + mic, [Float](repeating: 0, count: unpaired.count) + reference)
    }

    /// Everything still held, as plain mic (used when cancellation switches off).
    mutating func drain() -> [Float] {
        defer { micPending.removeAll(); unpaired.removeAll(); micNext = nil }
        return unpaired + micPending
    }

    /// The paired share since the last call, in percent (nil when nothing was released).
    mutating func takePairedPercent() -> Double? {
        defer { releasedSamples = 0; pairedSamples = 0 }
        return releasedSamples > 0 ? Double(pairedSamples) * 100 / Double(releasedSamples) : nil
    }
}

// MARK: - Debug dump

/// Float32 mono WAV at 16 kHz, header patched on close.
final class EchoDebugWriter {
    private let handles: [FileHandle]
    private var frames = 0
    private static let maxFrames = 16_000 * 300
    let directory: URL

    init?(names: [String]) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OpenWhisper/aec-\(stamp)")
        self.directory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            handles = try names.map { name in
                let url = directory.appendingPathComponent("\(name).wav")
                FileManager.default.createFile(atPath: url.path, contents: Self.header(frames: 0))
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                return handle
            }
        } catch {
            return nil
        }
    }

    /// One array per name, all the same length.
    func write(_ tracks: [[Float]]) {
        guard frames < Self.maxFrames, let count = tracks.first?.count else { return }
        for (handle, track) in zip(handles, tracks) {
            track.withUnsafeBufferPointer { handle.write(Data(buffer: $0)) }
        }
        frames += count
    }

    func close() {
        for handle in handles {
            handle.seek(toFileOffset: 0)
            handle.write(Self.header(frames: frames))
            try? handle.close()
        }
    }

    private static func header(frames: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dataBytes = UInt32(frames * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(1)
        u32(16_000); u32(64_000); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}
