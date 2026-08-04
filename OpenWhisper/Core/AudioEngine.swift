import AVFoundation
import Accelerate
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBluetooth: Bool
    let hasOutputStream: Bool
    let isBuiltIn: Bool
}

/// A bounded, immutable Whisper-ready audio unit. `overlapSampleCount` describes the leading
/// audio repeated from the preceding unit so the transcript owner can de-duplicate text safely.
struct CompletedAudioSegment: Sendable {
    let samples: [Float]
    let overlapSampleCount: Int
}

/// How microphone audio is cleaned up before transcription.
/// `.appleVoiceProcessing` costs ~900ms-1.1s at recording start (VPIO hardware setup);
/// `.deepFilterNet` runs a local neural denoiser (DeepFilterNet 3) with negligible startup cost
/// once its model is preloaded; `.off` does no noise suppression beyond AudioSignalProcessor's
/// fixed gain/compressor.
enum AudioProcessingMode: String, Codable, Sendable {
    case off
    case deepFilterNet
    case appleVoiceProcessing
}

final class AudioEngine: @unchecked Sendable {
    /// Fixed-size storage avoids allocating a Swift Array for every input callback. Completed
    /// batches are detached from this storage and flattened on a utility queue.
    private final class SampleChunk: @unchecked Sendable {
        var values: [Float]
        var count = 0

        init(capacity: Int) {
            values = Array(repeating: 0, count: capacity)
        }
    }

    private static let targetSampleRate: Double = 16_000
    private static let chunkCapacity = 16_384
    /// Upper bound on frames CoreAudio may deliver per input callback. `installTap(bufferSize:)`
    /// is only a hint — the driver can and does deliver more (e.g. 4410 or 4800 frames when a
    /// 4096-frame hint was given, at 44.1kHz/48kHz respectively). All downstream buffer
    /// capacities derive from this single constant so they stay consistent with each other.
    private static let maxInputFrameCount: AVAudioFrameCount = 16_384

    /// Frame capacities for every buffer in the recording chain, derived from
    /// `maxInputFrameCount` so they can never fall out of sync with each other. Exposed as a
    /// static pure function so the derivation can be unit-tested without spinning up audio I/O.
    struct BufferCapacities: Equatable {
        let monoInput: AVAudioFrameCount
        let df3Resampled: AVAudioFrameCount?
        let df3Output: AVAudioFrameCount?
        let converted: AVAudioFrameCount
    }

    static func bufferCapacities(nativeSampleRate: Double, deepFilterActive: Bool) -> BufferCapacities {
        let mono = maxInputFrameCount

        guard deepFilterActive else {
            let convertedCapacity = AVAudioFrameCount(
                ceil(Double(mono) * targetSampleRate / nativeSampleRate) + 256
            )
            return BufferCapacities(monoInput: mono, df3Resampled: nil, df3Output: nil, converted: convertedCapacity)
        }

        let df3SampleRate = DeepFilterProcessor.sampleRate
        // No resampler is needed when the mic is already delivering DF3's native rate; the
        // mono downmix buffer then serves directly as the 48kHz source.
        let df3Resampled: AVAudioFrameCount? = nativeSampleRate == df3SampleRate
            ? nil
            : AVAudioFrameCount(ceil(Double(mono) * df3SampleRate / nativeSampleRate) + 256)
        let df3InputCapacityAt48k = df3Resampled ?? mono
        // +512 covers DF3's internal ring buffer, which can carry over up to frameLength-1
        // (479) samples from a partially-filled 480-sample frame into the next callback.
        let df3Output = df3InputCapacityAt48k + 512
        let convertedCapacity = AVAudioFrameCount(
            ceil(Double(df3Output) * targetSampleRate / df3SampleRate) + 256
        )
        return BufferCapacities(
            monoInput: mono,
            df3Resampled: df3Resampled,
            df3Output: df3Output,
            converted: convertedCapacity
        )
    }

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var sampleChunks: [SampleChunk] = []
    private var capturedSampleCount = 0
    private var converter: AVAudioConverter?
    /// Voice-processing I/O can expose a multichannel input (for example 9 channels on a
    /// built-in microphone). Downmix it explicitly before the 16 kHz converter; letting
    /// AVAudioConverter infer a multichannel-to-mono mix can select an empty channel.
    private var monoInputBuffer: AVAudioPCMBuffer?
    private var convertedBuffer: AVAudioPCMBuffer?
    /// Loaded once via prewarmDeepFilter() and kept for the app's lifetime; ~170ms model load
    /// only needs to happen once, never on the Fn-press path.
    private var deepFilterProcessor: DeepFilterProcessor?
    /// Non-nil only while a recording with `.deepFilterNet` mode is active; nil the rest of the
    /// time even though `deepFilterProcessor` itself stays loaded. This is the per-recording gate.
    private var activeDeepFilter: DeepFilterProcessor?
    /// Resamples the native-rate downmix to DeepFilterNet's fixed 48kHz, skipped (left nil) when
    /// the mic is already 48kHz (e.g. would only happen if VP were also on, which this mode never does).
    private var df3NativeTo48kConverter: AVAudioConverter?
    private var df3ResampledBuffer: AVAudioPCMBuffer?
    /// Holds DeepFilterNet's denoised 48kHz output, which then feeds the existing 16kHz converter.
    private var df3OutputBuffer: AVAudioPCMBuffer?
    /// Reused across every callback's `DeepFilterProcessor.process(...)` call instead of
    /// allocating a fresh `[Float]` each time on the real-time audio thread. Capacity is
    /// reserved once in `startRecording()`; each callback only `removeAll(keepingCapacity:)`s it.
    private var deepFilterDenoiseScratch: [Float] = []
    /// Completed units are owned by AudioEngine until stopRecording takes them atomically.
    /// Keeping them here avoids a second asynchronous delivery queue racing the stop path.
    private var completedSegments: [CompletedAudioSegment] = []
    private let segmentPreparationQueue = DispatchQueue(
        label: "com.openwhisper.audio-segment-preparation",
        qos: .utility
    )
    private var leadingOverlapSampleCount = 0
    private var levelCallback: ((Float) -> Void)?
    private var lastLevelUpdate = Date.distantPast
    private let levelUpdateInterval: TimeInterval = 1.0 / 20.0
    private var didLogInputChannelSelection = false
    private var pinnedInputChannelIndex: Int? = nil

    /// Request microphone permission (call before first recording)
    func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        owLog("[AudioEngine] Current mic permission: \(status.rawValue)")
        if status == .authorized { return true }
        if status == .notDetermined {
            return await AVCaptureDevice.requestAccess(for: .audio)
        }
        return false
    }

    private var configuredDeviceUID: String? = nil
    private var configuredAudioProcessingMode: AudioProcessingMode? = nil
    private var isEnginePrepared = false
    private var hasLoggedFirstBuffer = false
    private var hasLoggedFirstAudibleBuffer = false
    private var hasLoggedInputTruncation = false
    private var hasLoggedDeepFilterFirstFrame = false

    /// Pre-warm the audio engine graph in the background so startRecording() takes < 2ms.
    func prewarm(deviceUID: String?, audioProcessingMode: AudioProcessingMode) {
        lock.lock()
        let needsConfig = !isEnginePrepared || configuredDeviceUID != deviceUID || configuredAudioProcessingMode != audioProcessingMode
        lock.unlock()
        guard needsConfig else { return }
        owLog("[AudioEngine] Pre-warming audio engine graph in background...")
        configureEngine(deviceUID: deviceUID, audioProcessingMode: audioProcessingMode)
    }

    /// Loads the DeepFilterNet model once, off the Fn-press path (call from app startup).
    /// Safe to call more than once; only the first call does anything.
    func prewarmDeepFilter() {
        lock.lock()
        let alreadyLoaded = deepFilterProcessor != nil
        lock.unlock()
        guard !alreadyLoaded else { return }
        let processor = DeepFilterProcessor()
        lock.lock()
        deepFilterProcessor = processor
        lock.unlock()
    }

    private func configureEngine(deviceUID: String?, audioProcessingMode: AudioProcessingMode) {
        var tStep = CACurrentMediaTime()
        func logStep(_ label: String) {
            let tNow = CACurrentMediaTime()
            let stepMs = (tNow - tStep) * 1000
            let elapsedMs = (tNow - GlobalHotkey.lastFnPressUptime) * 1000
            owLog(String(format: "[Perf] [\(label)] step=%.2f ms, total=%.2f ms / %.3f s from Fn press", stepMs, elapsedMs, elapsedMs / 1000.0))
            tStep = tNow
        }

        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
        logStep("CfgEngineAlloc")

        let inputNode = engine.inputNode
        logStep("CfgInputNodeAccess")

        if let uid = deviceUID, let deviceID = Self.audioDeviceID(forUID: uid) {
            do {
                try inputNode.auAudioUnit.setDeviceID(deviceID)
                owLog("[AudioEngine] Set input device UID=\(uid) id=\(deviceID)")
            } catch {
                owLog("[AudioEngine] Failed to set input device \(uid): \(error)")
            }
        } else {
            owLog("[AudioEngine] Using system default input")
        }
        logStep("CfgSetDeviceID")

        if audioProcessingMode == .appleVoiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                owLog("[AudioEngine] Apple voice processing enabled")
            } catch {
                owLog("[AudioEngine] Voice processing unavailable: \(error)")
            }
        }
        logStep("CfgVoiceProcessing")

        configuredDeviceUID = deviceUID
        configuredAudioProcessingMode = audioProcessingMode
        isEnginePrepared = true
        engine.prepare()
        logStep("CfgPrepare")
    }

    /// Start recording. If `deviceUID` is non-nil, route AUHAL to that input device;
    /// otherwise the system default input is used. Reuses the already-configured AVAudioEngine
    /// graph for instant ~1ms hardware recording start with zero background CPU overhead.
    /// Returns `true` when `.deepFilterNet` was requested but the model wasn't loaded in time
    /// (still within its ~230ms startup window), so this recording ran without denoising --
    /// callers can surface that to the user instead of it being silent.
    @discardableResult
    func startRecording(
        deviceUID: String?,
        audioProcessingMode: AudioProcessingMode,
        levelCallback: @escaping (Float) -> Void
    ) -> Bool {
        hasLoggedFirstBuffer = false
        hasLoggedFirstAudibleBuffer = false
        hasLoggedInputTruncation = false
        hasLoggedDeepFilterFirstFrame = false
        let tStartCall = CACurrentMediaTime()
        let elapsedStart = (tStartCall - GlobalHotkey.lastFnPressUptime) * 1000
        owLog(String(format: "[Perf] [AudioEngineStartCall] startRecording() entered (%.2f ms / %.3f s from Fn press)", elapsedStart, elapsedStart / 1000.0))

        // A previous stop waits for this queue, but keep start safe if a caller reuses the
        // engine after an interrupted setup.
        segmentPreparationQueue.sync {}
        self.levelCallback = levelCallback
        lastLevelUpdate = .distantPast
        lock.lock()
        sampleChunks = []
        capturedSampleCount = 0
        completedSegments.removeAll(keepingCapacity: false)
        leadingOverlapSampleCount = 0
        didLogInputChannelSelection = false
        pinnedInputChannelIndex = nil
        lock.unlock()

        // Only rebuild the AudioEngine graph if device/mode changed or engine is unconfigured
        if !isEnginePrepared || configuredDeviceUID != deviceUID || configuredAudioProcessingMode != audioProcessingMode {
            owLog("[AudioEngine] Configuring audio engine graph inline (deviceUID=\(deviceUID ?? "default"), audioProcessingMode=\(audioProcessingMode))...")
            configureEngine(deviceUID: deviceUID, audioProcessingMode: audioProcessingMode)
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        owLog("[AudioEngine] Recording format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        lock.lock()
        let loadedDeepFilter = deepFilterProcessor
        lock.unlock()
        let useDeepFilter = audioProcessingMode == .deepFilterNet && loadedDeepFilter != nil
        let didFallBackFromDeepFilter = audioProcessingMode == .deepFilterNet && loadedDeepFilter == nil
        if didFallBackFromDeepFilter {
            owLog("[AudioEngine] DeepFilterNet selected but not loaded (prewarm failed or still loading); recording without it")
        }
        loadedDeepFilter?.resetStream()

        let capacities = Self.bufferCapacities(nativeSampleRate: format.sampleRate, deepFilterActive: useDeepFilter)

        guard let downmixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ), let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let monoInputBuffer = AVAudioPCMBuffer(
            pcmFormat: downmixFormat,
            frameCapacity: capacities.monoInput
        ) else {
            owLog("[AudioEngine] Failed to create recording buffers")
            return false
        }

        // When DeepFilterNet is active, the 16kHz converter reads from DF3's fixed-48kHz output
        // instead of directly from the mic's native rate; DF3 may need its own native->48kHz
        // converter first (skipped if the mic already delivers 48kHz).
        var newDf3NativeTo48kConverter: AVAudioConverter?
        var newDf3ResampledBuffer: AVAudioPCMBuffer?
        var newDf3OutputBuffer: AVAudioPCMBuffer?
        let converterSourceFormat: AVAudioFormat
        if useDeepFilter, let df3Format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: DeepFilterProcessor.sampleRate,
            channels: 1,
            interleaved: false
        ) {
            converterSourceFormat = df3Format
            if let resampledCapacity = capacities.df3Resampled {
                newDf3NativeTo48kConverter = AVAudioConverter(from: downmixFormat, to: df3Format)
                newDf3ResampledBuffer = AVAudioPCMBuffer(pcmFormat: df3Format, frameCapacity: resampledCapacity)
            }
            newDf3OutputBuffer = AVAudioPCMBuffer(pcmFormat: df3Format, frameCapacity: capacities.df3Output ?? capacities.monoInput)
        } else {
            converterSourceFormat = downmixFormat
        }

        guard let converter = AVAudioConverter(from: converterSourceFormat, to: targetFormat) else {
            owLog("[AudioEngine] Failed to create 16kHz recording converter")
            return false
        }

        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(capacities.converted, 1)
        ) else {
            owLog("[AudioEngine] Failed to allocate 16kHz recording buffer")
            return false
        }

        lock.lock()
        self.converter = converter
        self.monoInputBuffer = monoInputBuffer
        self.convertedBuffer = convertedBuffer
        self.activeDeepFilter = useDeepFilter ? loadedDeepFilter : nil
        self.df3NativeTo48kConverter = newDf3NativeTo48kConverter
        self.df3ResampledBuffer = newDf3ResampledBuffer
        self.df3OutputBuffer = newDf3OutputBuffer
        // Sized to this recording's actual worst-case denoised-frame count so the real-time
        // callback never needs to grow this array; harmless no-op if already large enough.
        deepFilterDenoiseScratch.reserveCapacity(Int(capacities.df3Output ?? capacities.monoInput))
        lock.unlock()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: Self.maxInputFrameCount, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }

            self.lock.lock()
            let channelIndex: Int
            let rms: Float
            if let pinned = self.pinnedInputChannelIndex {
                channelIndex = pinned
                rms = self.channelRMS(in: buffer, channelIndex: pinned)
            } else {
                let selection = self.loudestInputChannel(in: buffer)
                let index = selection?.index ?? 0
                self.pinnedInputChannelIndex = index
                channelIndex = index
                rms = selection?.rms ?? 0.0
                if !self.didLogInputChannelSelection {
                    self.didLogInputChannelSelection = true
                    owLog(
                        "[AudioEngine] Input downmix (pinned): "
                            + "selectedChannel=\(index + 1)/\(buffer.format.channelCount) "
                            + String(format: "rms=%.5f", rms)
                    )
                }
            }
            self.lock.unlock()

            let tNow = CACurrentMediaTime()
            let elapsedMs = (tNow - GlobalHotkey.lastFnPressUptime) * 1000
            if !self.hasLoggedFirstBuffer {
                self.hasLoggedFirstBuffer = true
                owLog(String(format: "[Perf] [AudioEngineFirstBufferArrived] CoreAudio delivered 1st audio buffer (%.2f ms / %.3f s from Fn press, frames=%d, rms=%.5f)", elapsedMs, elapsedMs / 1000.0, frameLength, rms))
            }
            if !self.hasLoggedFirstAudibleBuffer && rms > 0.001 {
                self.hasLoggedFirstAudibleBuffer = true
                owLog(String(format: "[Perf] [AudioEngineFirstAudibleSpeechArrived] First non-silent voice buffer detected (%.2f ms / %.3f s from Fn press, rms=%.5f)", elapsedMs, elapsedMs / 1000.0, rms))
            }

            // The waveform is presentation-only. Limit UI work to 8 Hz while preserving every
            // microphone sample for transcription.
            let now = Date()
            if now.timeIntervalSince(self.lastLevelUpdate) >= self.levelUpdateInterval {
                self.lastLevelUpdate = now
                self.levelCallback?(rms)
            }

            self.lock.lock()
            self.convert(buffer, channelIndex: channelIndex)
            self.lock.unlock()
        }

        do {
            try engine.start()
            let tEngineStarted = CACurrentMediaTime()
            let elapsedEngineStarted = (tEngineStarted - GlobalHotkey.lastFnPressUptime) * 1000
            owLog(String(format: "[Perf] [AudioEngineEngineStarted] engine.start() completed (%.2f ms / %.3f s from Fn press)", elapsedEngineStarted, elapsedEngineStarted / 1000.0))
        } catch {
            owLog("[AudioEngine] Failed to start: \(error). Resetting engine configuration.")
            isEnginePrepared = false
            return false
        }
        return didFallBackFromDeepFilter
    }

    func stopRecording() -> [CompletedAudioSegment] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Reset and release the AUAudioUnit / CoreAudio HAL claim so system output volume
        // is never ducked and Bluetooth devices return to A2DP immediately.
        engine.reset()
        engine = AVAudioEngine()
        isEnginePrepared = false
        configuredDeviceUID = nil
        configuredAudioProcessingMode = nil
        levelCallback = nil

        lock.lock()
        flushConverter()
        let stoppedDeepFilter = activeDeepFilter
        activeDeepFilter = nil
        df3NativeTo48kConverter = nil
        df3ResampledBuffer = nil
        df3OutputBuffer = nil
        lock.unlock()

        // Tap is already removed and the engine stopped above, so no audio-thread call into
        // `process()` can still be in flight — reading these counters here is safe.
        if let stoppedDeepFilter, stoppedDeepFilter.processedFrameCount > 0 {
            owLog(String(
                format: "[DeepFilter] Recording summary: frames=%d processedMs=%.1f avgSNR=%.2fdB",
                stoppedDeepFilter.processedFrameCount,
                stoppedDeepFilter.processedDurationMs,
                stoppedDeepFilter.averageSNR
            ))
        }

        // A completed three-minute batch may still be flattening off the audio callback.
        // Wait for that work before taking the final tail, preserving batch order.
        segmentPreparationQueue.sync {}

        lock.lock()
        let captured = flattenedSamples()
        let finalOverlap = leadingOverlapSampleCount
        var segments = completedSegments
        if !captured.isEmpty {
            segments.append(CompletedAudioSegment(samples: captured, overlapSampleCount: finalOverlap))
        }
        sampleChunks = []
        capturedSampleCount = 0
        converter = nil
        convertedBuffer = nil
        completedSegments.removeAll(keepingCapacity: false)
        leadingOverlapSampleCount = 0
        lock.unlock()

        return segments
    }

    /// Takes batches that crossed the three-minute boundary while recording is still active.
    /// The recording engine keeps running; this only transfers already-completed audio to the
    /// transcription queue.
    func takeCompletedSegments() -> [CompletedAudioSegment] {
        lock.lock()
        defer { lock.unlock() }

        let segments = completedSegments
        completedSegments.removeAll(keepingCapacity: true)
        return segments
    }

    // MARK: - Streaming conversion and storage

    /// Runs the one converter instance throughout a recording so resampling filter state is
    /// continuous across input buffers. This work stays inside the audio callback, but only
    /// copies the already-required 16kHz output into fixed-size storage.
    private func channelRMS(in buffer: AVAudioPCMBuffer, channelIndex: Int) -> Float {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0,
              channelIndex >= 0 && channelIndex < Int(buffer.format.channelCount) else { return 0.0 }
        var rms: Float = 0
        vDSP_rmsqv(channels[channelIndex], 1, &rms, vDSP_Length(buffer.frameLength))
        return rms
    }

    private func loudestInputChannel(in buffer: AVAudioPCMBuffer) -> (index: Int, rms: Float)? {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0,
              buffer.format.channelCount > 0 else { return nil }

        var selectedIndex = 0
        var selectedRMS: Float = -.greatestFiniteMagnitude
        for index in 0..<Int(buffer.format.channelCount) {
            var rms: Float = 0
            vDSP_rmsqv(channels[index], 1, &rms, vDSP_Length(buffer.frameLength))
            if rms > selectedRMS {
                selectedRMS = rms
                selectedIndex = index
            }
        }
        return (selectedIndex, selectedRMS)
    }

    /// Resamples `nativeMonoBuffer` to 48kHz if needed, runs it through DeepFilterNet, and
    /// writes any fully-denoised frames into `outputBuffer`. Returns nil when DF3's internal
    /// 480-sample ring buffer hasn't accumulated a full frame yet this callback (normal at the
    /// start of a recording) or on a conversion failure.
    private func deepFilterDenoisedBuffer(
        from nativeMonoBuffer: AVAudioPCMBuffer,
        processor: DeepFilterProcessor,
        outputBuffer: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        let source: AVAudioPCMBuffer
        if let df3NativeTo48kConverter, let df3ResampledBuffer {
            df3ResampledBuffer.frameLength = 0
            var suppliedInput = false
            var error: NSError?
            df3NativeTo48kConverter.convert(to: df3ResampledBuffer, error: &error) { _, status in
                if suppliedInput {
                    status.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                status.pointee = .haveData
                return nativeMonoBuffer
            }
            guard error == nil, df3ResampledBuffer.frameLength > 0 else { return nil }
            source = df3ResampledBuffer
        } else {
            source = nativeMonoBuffer
        }

        guard let sourceChannel = source.floatChannelData?[0], source.frameLength > 0 else { return nil }

        deepFilterDenoiseScratch.removeAll(keepingCapacity: true)
        processor.process(sourceChannel, count: Int(source.frameLength), into: &deepFilterDenoiseScratch)
        guard !deepFilterDenoiseScratch.isEmpty else { return nil }

        if !hasLoggedDeepFilterFirstFrame {
            hasLoggedDeepFilterFirstFrame = true
            let tNow = CACurrentMediaTime()
            let elapsedMs = (tNow - GlobalHotkey.lastFnPressUptime) * 1000
            owLog(String(format: "[Perf] [DeepFilterFirstFrame] First denoised frame produced (%.2f ms / %.3f s from Fn press)", elapsedMs, elapsedMs / 1000.0))
        }

        let capacity = Int(outputBuffer.frameCapacity)
        let count = min(deepFilterDenoiseScratch.count, capacity)
        if count < deepFilterDenoiseScratch.count {
            owLog("[DeepFilter] Denoised frame count \(deepFilterDenoiseScratch.count) exceeds output buffer capacity \(capacity); truncating.")
        }
        guard let outputChannel = outputBuffer.floatChannelData?[0] else { return nil }
        deepFilterDenoiseScratch.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            outputChannel.update(from: baseAddress, count: count)
        }
        outputBuffer.frameLength = AVAudioFrameCount(count)
        return outputBuffer
    }

    private func convert(_ inputBuffer: AVAudioPCMBuffer, channelIndex: Int) {
        guard let converter, let monoInputBuffer, let convertedBuffer,
              let sourceChannels = inputBuffer.floatChannelData,
              let monoChannel = monoInputBuffer.floatChannelData?[0] else { return }

        let delivered = Int(inputBuffer.frameLength)
        let capacity = Int(monoInputBuffer.frameCapacity)
        let frameLength = min(delivered, capacity)
        guard frameLength > 0 else { return }
        if delivered > capacity && !hasLoggedInputTruncation {
            hasLoggedInputTruncation = true
            owLog("[AudioEngine] Input buffer truncated: delivered=\(delivered) capacity=\(capacity) — ses kaybı var.")
        }
        let safeChannelIndex = min(max(channelIndex, 0), Int(inputBuffer.format.channelCount) - 1)
        monoChannel.update(from: sourceChannels[safeChannelIndex], count: frameLength)
        monoInputBuffer.frameLength = AVAudioFrameCount(frameLength)

        // DeepFilterNet, when active for this recording, denoises between the native-rate
        // downmix and the 16kHz converter below. It buffers internally in 480-sample/10ms
        // frames, so a given tap callback may yield fewer (or zero) denoised samples than it
        // was fed; zero is normal on the first callback or two of a recording.
        let converterSource: AVAudioPCMBuffer
        if let activeDeepFilter, let df3OutputBuffer {
            guard let denoised = deepFilterDenoisedBuffer(
                from: monoInputBuffer,
                processor: activeDeepFilter,
                outputBuffer: df3OutputBuffer
            ) else { return }
            converterSource = denoised
        } else {
            converterSource = monoInputBuffer
        }

        convertedBuffer.frameLength = 0
        var suppliedInput = false
        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { _, status in
            if suppliedInput {
                status.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return converterSource
        }

        guard error == nil,
              let output = convertedBuffer.floatChannelData?[0],
              convertedBuffer.frameLength > 0 else { return }
        // Preserve quiet speech before storing the Whisper input. There is deliberately no
        // noise gate here: a gate would erase exactly the low-volume syllables this path is
        // intended to recover. The compressor prevents the modest gain from clipping.
        AudioSignalProcessor.process(output, count: Int(convertedBuffer.frameLength))
        appendSamples(output, count: Int(convertedBuffer.frameLength))
        emitCompletedSegmentIfNeeded()
    }

    /// Drains converter delay after the tap is removed, preserving the tail of the recording.
    private func flushConverter() {
        guard let converter, let convertedBuffer else { return }

        while true {
            convertedBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }

            guard error == nil,
                  let output = convertedBuffer.floatChannelData?[0],
                  convertedBuffer.frameLength > 0 else { break }
            appendSamples(output, count: Int(convertedBuffer.frameLength))

            if status == .endOfStream { break }
        }
    }

    private func appendSamples(_ source: UnsafePointer<Float>, count: Int) {
        var sourceOffset = 0
        while sourceOffset < count {
            let chunk: SampleChunk
            if let last = sampleChunks.last, last.count < last.values.count {
                chunk = last
            } else {
                chunk = SampleChunk(capacity: Self.chunkCapacity)
                sampleChunks.append(chunk)
            }

            let writable = min(chunk.values.count - chunk.count, count - sourceOffset)
            chunk.values.withUnsafeMutableBufferPointer { destination in
                destination.baseAddress!.advanced(by: chunk.count).update(
                    from: source.advanced(by: sourceOffset),
                    count: writable
                )
            }
            chunk.count += writable
            capturedSampleCount += writable
            sourceOffset += writable
        }
    }

    private func flattenedSamples() -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(capturedSampleCount)
        for chunk in sampleChunks where chunk.count > 0 {
            result.append(contentsOf: chunk.values.prefix(chunk.count))
        }
        return result
    }

    /// Keeps only the still-active batch in AudioEngine memory. The duration boundary is kept
    /// near three minutes; retaining one second of prior audio gives the next batch context
    /// without interrupting the microphone.
    private func emitCompletedSegmentIfNeeded() {
        guard capturedSampleCount > AudioSegmentation.maximumDuration * AudioSegmentation.sampleRate else {
            return
        }

        // Do not flatten three minutes of audio on the real-time input callback. Detach the
        // immutable chunk storage, retain only one second for boundary context, and flatten the
        // detached batch on a utility queue while the microphone continues uninterrupted.
        let detachedChunks = sampleChunks
        let detachedSampleCount = capturedSampleCount
        let completedOverlap = leadingOverlapSampleCount
        let retainedOverlap = min(
            AudioSegmentation.overlapDuration * AudioSegmentation.sampleRate,
            detachedSampleCount
        )
        let overlapSamples = trailingSamples(count: retainedOverlap)

        sampleChunks = []
        capturedSampleCount = 0
        overlapSamples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                appendSamples(baseAddress, count: overlapSamples.count)
            }
        }
        leadingOverlapSampleCount = retainedOverlap

        segmentPreparationQueue.async { [weak self, detachedChunks] in
            let completedSamples = Self.flattenedSamples(
                from: detachedChunks,
                sampleCount: detachedSampleCount
            )
            guard !completedSamples.isEmpty, let self else { return }

            self.lock.lock()
            self.completedSegments.append(
                CompletedAudioSegment(samples: completedSamples, overlapSampleCount: completedOverlap)
            )
            self.lock.unlock()
        }
    }

    private func trailingSamples(count: Int) -> [Float] {
        guard count > 0 else { return [] }

        var remaining = count
        var reversed: [Float] = []
        reversed.reserveCapacity(count)
        for chunk in sampleChunks.reversed() where remaining > 0 {
            let copied = min(chunk.count, remaining)
            let start = chunk.count - copied
            reversed.append(contentsOf: chunk.values[start..<chunk.count])
            remaining -= copied
        }
        return Array(reversed.reversed())
    }

    private static func flattenedSamples(
        from chunks: [SampleChunk],
        sampleCount: Int
    ) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(sampleCount)
        for chunk in chunks where chunk.count > 0 {
            result.append(contentsOf: chunk.values.prefix(chunk.count))
        }
        return result
    }

    // MARK: - Device enumeration

    /// All system input devices (those exposing at least one input stream).
    static func availableInputDevices() -> [AudioInputDevice] {
        return allAudioDeviceIDs().compactMap { id in
            guard hasInputStream(deviceID: id) else { return nil }
            guard let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"
            return AudioInputDevice(
                id: id,
                uid: uid,
                name: name,
                isBluetooth: isBluetoothTransport(deviceID: id),
                hasOutputStream: hasOutputStream(deviceID: id),
                isBuiltIn: isBuiltInTransport(deviceID: id)
            )
        }
    }

    /// True when the system's current default input is a Bluetooth device.
    static func systemDefaultInputIsBluetooth() -> Bool {
        guard let id = defaultInputDeviceID() else { return false }
        return isBluetoothTransport(deviceID: id)
    }

    /// Look up an AudioDeviceID by its persistent UID.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        return availableInputDevices().first(where: { $0.uid == uid })?.id
    }

    /// Returns the currently connected headset-like external input device, if any.
    static func connectedExternalHeadsetDevice() -> AudioInputDevice? {
        return availableInputDevices()
            .filter { !$0.isBuiltIn && ($0.hasOutputStream || $0.isBluetooth) }
            .sorted { lhs, rhs in
                if lhs.isBluetooth != rhs.isBluetooth {
                    return lhs.isBluetooth
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .first
    }

    /// Select a headset-like input when automatic routing is enabled. A non-built-in
    /// duplex device is preferred because it represents a headset or USB audio device;
    /// Bluetooth input is also accepted when the device exposes no output stream. If no
    /// external headset is present, fall back to the Mac's built-in microphone.
    static func automaticInputDeviceUID() -> String? {
        let devices = availableInputDevices()
        return connectedExternalHeadsetDevice()?.uid ?? devices.first(where: { $0.isBuiltIn })?.uid
    }

    // MARK: - Core Audio property helpers

    private static func allAudioDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        ) == noErr else { return nil }
        return id == 0 ? nil : id
    }

    private static func hasInputStream(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func hasOutputStream(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = cfStr?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func isBluetoothTransport(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func isBuiltInTransport(deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }
}
