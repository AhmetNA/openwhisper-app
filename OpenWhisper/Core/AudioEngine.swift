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
    private let levelUpdateInterval: TimeInterval = 1.0 / 25.0
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
    private var configuredNoiseSuppression: Bool? = nil
    private var isEnginePrepared = false

    /// Pre-warm the audio engine graph in the background so startRecording() takes < 2ms.
    func prewarm(deviceUID: String?, noiseSuppressionEnabled: Bool) {
        lock.lock()
        let needsConfig = !isEnginePrepared || configuredDeviceUID != deviceUID || configuredNoiseSuppression != noiseSuppressionEnabled
        lock.unlock()
        guard needsConfig else { return }
        owLog("[AudioEngine] Pre-warming audio engine graph in background...")
        configureEngine(deviceUID: deviceUID, noiseSuppressionEnabled: noiseSuppressionEnabled)
    }

    private func configureEngine(deviceUID: String?, noiseSuppressionEnabled: Bool) {
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()

        let inputNode = engine.inputNode
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

        if noiseSuppressionEnabled {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                owLog("[AudioEngine] Apple voice processing enabled")
            } catch {
                owLog("[AudioEngine] Voice processing unavailable: \(error)")
            }
        }

        configuredDeviceUID = deviceUID
        configuredNoiseSuppression = noiseSuppressionEnabled
        isEnginePrepared = true
        engine.prepare()
    }

    /// Start recording. If `deviceUID` is non-nil, route AUHAL to that input device;
    /// otherwise the system default input is used. Reuses the already-configured AVAudioEngine
    /// graph for instant ~1ms hardware recording start with zero background CPU overhead.
    func startRecording(
        deviceUID: String?,
        noiseSuppressionEnabled: Bool,
        levelCallback: @escaping (Float) -> Void
    ) {
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

        // Only rebuild the AudioEngine graph if device/noiseSuppression changed or engine is unconfigured
        if !isEnginePrepared || configuredDeviceUID != deviceUID || configuredNoiseSuppression != noiseSuppressionEnabled {
            owLog("[AudioEngine] Configuring audio engine graph inline (deviceUID=\(deviceUID ?? "default"), noiseSuppression=\(noiseSuppressionEnabled))...")
            configureEngine(deviceUID: deviceUID, noiseSuppressionEnabled: noiseSuppressionEnabled)
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        owLog("[AudioEngine] Recording format: \(format.sampleRate)Hz, \(format.channelCount)ch")

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

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
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
            owLog("[AudioEngine] Engine started (instant)")
        } catch {
            owLog("[AudioEngine] Failed to start: \(error). Resetting engine configuration.")
            isEnginePrepared = false
        }
    }

    func stopRecording() -> [CompletedAudioSegment] {
        let lastUID = configuredDeviceUID
        let lastNoise = configuredNoiseSuppression ?? false

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Reset and release the AUAudioUnit / CoreAudio HAL claim so system output volume
        // is never ducked and Bluetooth devices return to A2DP immediately.
        engine.reset()
        engine = AVAudioEngine()
        isEnginePrepared = false
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

        // Pre-warm background task right after stop so next press starts instantly
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.prewarm(deviceUID: lastUID, noiseSuppressionEnabled: lastNoise)
        }

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

    /// Select a headset-like input when automatic routing is enabled. A non-built-in
    /// duplex device is preferred because it represents a headset or USB audio device;
    /// Bluetooth input is also accepted when the device exposes no output stream. If no
    /// external headset is present, fall back to the Mac's built-in microphone.
    static func automaticInputDeviceUID() -> String? {
        let devices = availableInputDevices()
        let externalHeadset = devices
            .filter { !$0.isBuiltIn && ($0.hasOutputStream || $0.isBluetooth) }
            .sorted { lhs, rhs in
                if lhs.isBluetooth != rhs.isBluetooth {
                    return lhs.isBluetooth
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
