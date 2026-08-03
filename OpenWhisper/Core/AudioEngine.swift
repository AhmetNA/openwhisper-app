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
    private let levelUpdateInterval: TimeInterval = 1.0 / 8.0
    private var didLogInputChannelSelection = false
    /// Gain applied by `AudioSignalProcessor.process` for this recording. Resolved once at
    /// `startRecording` from the *effective* (read-back) voice-processing state, not the
    /// requested one, so it always matches what the microphone is actually doing.
    private var activeInputGain: Float = AudioSignalProcessor.inputGain
    /// One-shot flag for the `[Perf] engineStart=...` log; flipped on the first buffer that
    /// reaches the tap after `startRecording` is called.
    private var didLogEngineStartPerf = false

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

    /// Start recording. If `deviceUID` is non-nil, route AUHAL to that input device;
    /// otherwise the system default input is used.
    func startRecording(
        deviceUID: String?,
        noiseSuppressionEnabled: Bool,
        levelCallback: @escaping (Float) -> Void
    ) {
        // [Perf] Measured from the very first instruction of this call to the first real audio
        // buffer reaching the tap below (see the `didLogEngineStartPerf` block). A plain
        // timestamp comparison, no allocation.
        let recordingRequestedAt = DispatchTime.now()
        didLogEngineStartPerf = false

        // A previous stop waits for this queue, but keep start safe if a caller reuses the
        // engine after an interrupted setup.
        segmentPreparationQueue.sync {}
        self.levelCallback = levelCallback
        lastLevelUpdate = .distantPast
        lock.lock()
        sampleChunks = []
        capturedSampleCount = 0
        converter = nil
        monoInputBuffer = nil
        convertedBuffer = nil
        completedSegments.removeAll(keepingCapacity: false)
        leadingOverlapSampleCount = 0
        didLogInputChannelSelection = false
        lock.unlock()

        // Always start from a fresh engine so any prior HAL claim is fully released
        engine = AVAudioEngine()

        let inputNode = engine.inputNode

        // Voice processing is toggled BEFORE the device is selected. Apple's own header doc
        // (AVAudioIONode.h) only says the toggle rebuilds the input/output format and that this
        // can only happen while the engine is stopped -- it does not document what happens to a
        // device selection made beforehand. Community reports of the same underlying mechanism
        // (Apple Developer Forums threads 810129 and 771530; AudioKit issue #2130, which
        // documents that the previous "set deviceID, then flip voice processing" trick stopped
        // working once the aggregate device gets constructed) describe voice processing
        // constructing a brand-new AUVoiceProcessingIO aggregate device on access, which is
        // exactly the kind of operation that can silently discard an earlier setDeviceID call.
        // Doing the toggle first, then selecting the device, is the safe order either way -- and
        // the effective-device readback a few lines down is the real proof, not this comment.
        do {
            try inputNode.setVoiceProcessingEnabled(noiseSuppressionEnabled)
            owLog(
                "[AudioEngine] Apple voice processing "
                    + (noiseSuppressionEnabled ? "requested=enabled" : "requested=disabled")
            )
        } catch {
            owLog("[AudioEngine] Apple voice processing unavailable: \(error). Continuing without it.")
        }

        let requestedDeviceID = deviceUID.flatMap { Self.audioDeviceID(forUID: $0) }
        if let uid = deviceUID {
            if let deviceID = requestedDeviceID {
                let requestedName = Self.stringProperty(
                    deviceID: deviceID,
                    selector: kAudioDevicePropertyDeviceNameCFString
                ) ?? "unknown"
                do {
                    try inputNode.auAudioUnit.setDeviceID(deviceID)
                    owLog(
                        "[AudioEngine] Requested input device name=\(requestedName) uid=\(uid) "
                            + "id=\(deviceID) -> setDeviceID succeeded"
                    )
                } catch {
                    owLog(
                        "[AudioEngine] Requested input device name=\(requestedName) uid=\(uid) "
                            + "id=\(deviceID) -> setDeviceID FAILED: \(error). Falling back to default."
                    )
                }
            } else {
                owLog("[AudioEngine] Requested input device uid=\(uid) not found among current devices. Falling back to default.")
            }
        } else {
            owLog("[AudioEngine] Requested input: system default")
        }

        // Read back what the AU property accepted, instead of trusting that setDeviceID/
        // setVoiceProcessingEnabled succeeding means they took effect. NOTE: on macOS the
        // AUVoiceProcessingIO aggregate device is actually constructed when the engine starts
        // rendering (`engine.start()` below), not at property-set time -- so this read is only a
        // sanity check that the write stuck on *this* AU instance. It cannot see anything the
        // aggregate construction at start might still change. The authoritative reading, and the
        // one that should be trusted/compared against what was requested, is the "effective
        // input=" line logged after `engine.start()` succeeds, further down.
        let preStartDeviceID: AudioDeviceID = inputNode.auAudioUnit.deviceID
        let preStartDeviceName = Self.stringProperty(
            deviceID: preStartDeviceID,
            selector: kAudioDevicePropertyDeviceNameCFString
        ) ?? "unknown"
        let preStartDeviceUID = Self.stringProperty(
            deviceID: preStartDeviceID,
            selector: kAudioDevicePropertyDeviceUID
        ) ?? "unknown"
        let preStartVoiceProcessing = inputNode.isVoiceProcessingEnabled
        owLog(
            "[AudioEngine] pre-start input=\(preStartDeviceName) uid=\(preStartDeviceUID) "
                + "vp=\(preStartVoiceProcessing)"
        )

        // Resolve AudioSignalProcessor's gain from this pre-start reading and write it NOW,
        // strictly before `engine.start()` is called below. This must not wait until after
        // `engine.start()` returns: that call only kicks off rendering, it does not block until
        // the render thread is idle again. The tap closure below runs on a separate, real-time
        // audio IO thread that AVAudioEngine spins up as part of starting; that thread can call
        // back with the first buffers while this (calling) thread is still executing the lines
        // immediately after `engine.start()` returns. Writing here, before the call, is the only
        // ordering that guarantees no buffer is ever processed with a stale value from a
        // previous recording. If the authoritative post-start reading further down disagrees,
        // it corrects these same two values and logs a WARNING -- accepting that a few early
        // buffers (and the `[Perf]` line's `ns=` label) may have used the pre-start guess.
        AudioSignalProcessor.captureUsedVoiceProcessing = preStartVoiceProcessing
        activeInputGain = preStartVoiceProcessing
            ? AudioSignalProcessor.voiceProcessingInputGain
            : AudioSignalProcessor.inputGain

        let format = inputNode.outputFormat(forBus: 0)

        guard let monoInputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ), let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: monoInputFormat, to: targetFormat),
        let monoInputBuffer = AVAudioPCMBuffer(
            pcmFormat: monoInputFormat,
            frameCapacity: 4096
        ) else {
            owLog("[AudioEngine] Failed to create 16kHz recording converter")
            return
        }

        // The tap buffer size is 4096 frames. Keep one reusable destination buffer for the
        // whole recording, with enough headroom for sample-rate expansion and converter delay.
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(4096) * Self.targetSampleRate / format.sampleRate) + 256
        )
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: max(outputCapacity, 1)
        ) else {
            owLog("[AudioEngine] Failed to allocate 16kHz recording buffer")
            return
        }

        lock.lock()
        self.converter = converter
        self.monoInputBuffer = monoInputBuffer
        self.convertedBuffer = convertedBuffer
        lock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let selection = self.loudestInputChannel(in: buffer) else { return }

            if !self.didLogEngineStartPerf {
                self.didLogEngineStartPerf = true
                let elapsedMs = Double(
                    DispatchTime.now().uptimeNanoseconds - recordingRequestedAt.uptimeNanoseconds
                ) / 1_000_000
                // Reads the shared static rather than capturing a local: it was written above,
                // before this tap was even installed (let alone before `engine.start()` was
                // called), so no buffer -- including this first one -- can ever see a stale
                // value left over from a *previous* recording. It can still reflect the
                // pre-start guess rather than the post-start correction if this fires before
                // that correction runs; see the WARNING logged after `engine.start()` for when
                // that happened and this `ns=` label should be treated as suspect.
                owLog(
                    "[Perf] engineStart=" + String(format: "%.1f", elapsedMs)
                        + " ns=" + (AudioSignalProcessor.captureUsedVoiceProcessing ? "on" : "off")
                )
            }

            if !self.didLogInputChannelSelection {
                self.didLogInputChannelSelection = true
                owLog(
                    "[AudioEngine] Input downmix: "
                        + "selectedChannel=\(selection.index + 1)/\(buffer.format.channelCount) "
                        + String(format: "rms=%.5f", selection.rms)
                )
            }

            // The waveform is presentation-only. Limit UI work to 8 Hz while preserving every
            // microphone sample for transcription.
            let now = Date()
            if now.timeIntervalSince(self.lastLevelUpdate) >= self.levelUpdateInterval {
                self.lastLevelUpdate = now
                self.levelCallback?(selection.rms)
            }

            self.lock.lock()
            self.convert(buffer, channelIndex: selection.index)
            self.lock.unlock()
        }

        do {
            try engine.start()
            owLog("[AudioEngine] Engine started")

            // This is the readback that actually matters. The AUVoiceProcessingIO aggregate
            // device (when voice processing is on) is built when the engine starts rendering,
            // not when setDeviceID/setVoiceProcessingEnabled were called above -- so only a
            // reading taken after a successful `engine.start()` can see what that construction
            // did to routing/format. Compare this line's uid against the "Requested input
            // device" line above, and its format against the "pre-start" line: a mismatch on
            // either is the real, empirical answer to whether the reorder in this change
            // actually fixed anything, independent of what any doc or comment claims.
            let effectiveDeviceID: AudioDeviceID = inputNode.auAudioUnit.deviceID
            let effectiveDeviceName = Self.stringProperty(
                deviceID: effectiveDeviceID,
                selector: kAudioDevicePropertyDeviceNameCFString
            ) ?? "unknown"
            let effectiveDeviceUID = Self.stringProperty(
                deviceID: effectiveDeviceID,
                selector: kAudioDevicePropertyDeviceUID
            ) ?? "unknown"
            let effectiveVoiceProcessing = inputNode.isVoiceProcessingEnabled
            let effectiveFormat = inputNode.outputFormat(forBus: 0)

            owLog(
                "[AudioEngine] effective input=\(effectiveDeviceName) uid=\(effectiveDeviceUID) "
                    + "vp=\(effectiveVoiceProcessing) format=\(Int(effectiveFormat.sampleRate))/\(effectiveFormat.channelCount)"
            )

            if let uid = deviceUID, let requestedDeviceID, effectiveDeviceID != requestedDeviceID {
                owLog(
                    "[AudioEngine] WARNING requested input device did not take effect: "
                        + "requested uid=\(uid) id=\(requestedDeviceID), "
                        + "effective uid=\(effectiveDeviceUID) id=\(effectiveDeviceID) name=\(effectiveDeviceName)"
                )
            }
            if effectiveFormat.sampleRate != format.sampleRate || effectiveFormat.channelCount != format.channelCount {
                // The tap a few lines up was installed with `format` (the pre-start reading).
                // If the post-start format differs, the converter/tap are primed for the wrong
                // stream shape and the recording may come out silent, garbled, or wrong-speed.
                owLog(
                    "[AudioEngine] WARNING input format changed after engine start: tap installed "
                        + "with \(Int(format.sampleRate))/\(format.channelCount), engine now reports "
                        + "\(Int(effectiveFormat.sampleRate))/\(effectiveFormat.channelCount)"
                )
            }

            // AudioSignalProcessor.captureUsedVoiceProcessing and activeInputGain were already
            // set from `preStartVoiceProcessing` BEFORE `engine.start()` was called above (see
            // that comment for why: the tap's real-time audio IO thread can start delivering
            // buffers while this calling thread is still running these post-start lines, so
            // waiting until here to write them for the first time would race actual audio
            // against the assignment). If the post-start reading disagrees with the pre-start
            // one, correct both values now for the rest of the recording, and say so: it means
            // some number of buffers at the start of this recording -- and possibly the
            // `[Perf] engineStart=...` line's `ns=` label, if it fired before this correction --
            // used the wrong gain / wrong mode label.
            if effectiveVoiceProcessing != preStartVoiceProcessing {
                owLog(
                    "[AudioEngine] WARNING voice processing state changed after engine start: "
                        + "pre-start vp=\(preStartVoiceProcessing), effective vp=\(effectiveVoiceProcessing). "
                        + "Early buffers in this recording, and the ns= label on the [Perf] line "
                        + "above, may reflect the pre-start value instead."
                )
                AudioSignalProcessor.captureUsedVoiceProcessing = effectiveVoiceProcessing
                activeInputGain = effectiveVoiceProcessing
                    ? AudioSignalProcessor.voiceProcessingInputGain
                    : AudioSignalProcessor.inputGain
            }
        } catch {
            owLog("[AudioEngine] Failed to start: \(error)")
        }
    }

    func stopRecording() -> [CompletedAudioSegment] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Drop the AUAudioUnit and its HAL device claim now, not lazily on the next start.
        // This lets a Bluetooth headset return to A2DP immediately instead of lingering in HFP/SCO.
        engine.reset()
        engine = AVAudioEngine()
        levelCallback = nil

        lock.lock()
        flushConverter()
        lock.unlock()

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

    private func convert(_ inputBuffer: AVAudioPCMBuffer, channelIndex: Int) {
        guard let converter, let monoInputBuffer, let convertedBuffer,
              let sourceChannels = inputBuffer.floatChannelData,
              let monoChannel = monoInputBuffer.floatChannelData?[0] else { return }

        let frameLength = min(Int(inputBuffer.frameLength), Int(monoInputBuffer.frameCapacity))
        guard frameLength > 0 else { return }
        let safeChannelIndex = min(max(channelIndex, 0), Int(inputBuffer.format.channelCount) - 1)
        monoChannel.update(from: sourceChannels[safeChannelIndex], count: frameLength)
        monoInputBuffer.frameLength = AVAudioFrameCount(frameLength)

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
            return monoInputBuffer
        }

        guard error == nil,
              let output = convertedBuffer.floatChannelData?[0],
              convertedBuffer.frameLength > 0 else { return }
        // Preserve quiet speech before storing the Whisper input. There is deliberately no
        // noise gate here: a gate would erase exactly the low-volume syllables this path is
        // intended to recover. The compressor prevents the modest gain from clipping.
        // `activeInputGain` was resolved once at startRecording from the effective (read-back)
        // voice-processing state: full gain when voice processing is off, a reduced gain when
        // Apple's own AGC has already normalized the signal.
        AudioSignalProcessor.process(output, count: Int(convertedBuffer.frameLength), gain: activeInputGain)
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

    /// Select a headset-like input when automatic routing is enabled. A non-built-in
    /// duplex device is preferred because it represents a headset or USB audio device;
    /// Bluetooth input is also accepted when the device exposes no output stream. If no
    /// external headset is present, fall back to the Mac's built-in microphone.
    ///
    /// Ranking among external devices is quality-first, NOT connection-first: wired/USB
    /// headsets before Bluetooth. A Bluetooth microphone forces macOS to drop the link into
    /// HFP/SCO (narrowband, ~16 kHz mono, telephone-quality) for the duration of the recording
    /// -- this app's own Settings screen already warns the user about exactly this ("Bluetooth
    /// headsets drop into low-quality call mode while dictating"). A wired or USB headset has no
    /// such penalty, so it is always the better choice when both are available. Bluetooth still
    /// beats the built-in Mac mic, matching the "kulaklık varsa kulaklık" requirement -- it is
    /// only demoted below a wired/USB alternative, never below the built-in mic.
    static func automaticInputDeviceUID() -> String? {
        let devices = availableInputDevices()
        let externalHeadset = devices
            .filter { !$0.isBuiltIn && ($0.hasOutputStream || $0.isBluetooth) }
            .sorted { lhs, rhs in
                if lhs.isBluetooth != rhs.isBluetooth {
                    return !lhs.isBluetooth
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .first

        return externalHeadset?.uid ?? devices.first(where: { $0.isBuiltIn })?.uid
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
