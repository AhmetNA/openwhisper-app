import AVFoundation
import Accelerate
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isBluetooth: Bool
}

/// A bounded, immutable Whisper-ready audio unit. `overlapSampleCount` describes the leading
/// audio repeated from the preceding unit so the transcript owner can de-duplicate text safely.
struct CompletedAudioSegment: Sendable {
    let samples: [Float]
    let overlapSampleCount: Int
}

final class AudioEngine: @unchecked Sendable {
    /// Fixed-size storage avoids allocating a Swift Array for every input callback. The final
    /// contiguous array is intentionally produced only at the existing `stopRecording()` API
    /// boundary, immediately before WhisperKit consumes it.
    private final class SampleChunk {
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
    private var convertedBuffer: AVAudioPCMBuffer?
    private var segmentCallback: (@Sendable (CompletedAudioSegment) -> Void)?
    private var leadingOverlapSampleCount = 0
    private let segmentDeliveryQueue = DispatchQueue(label: "com.openwhisper.audio-segments")
    private var levelCallback: ((Float) -> Void)?
    private var lastLevelUpdate = Date.distantPast
    private let levelUpdateInterval: TimeInterval = 1.0 / 8.0

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
        levelCallback: @escaping (Float) -> Void,
        completedSegmentCallback: (@Sendable (CompletedAudioSegment) -> Void)? = nil
    ) {
        self.levelCallback = levelCallback
        lastLevelUpdate = .distantPast
        lock.lock()
        sampleChunks = []
        capturedSampleCount = 0
        converter = nil
        convertedBuffer = nil
        segmentCallback = completedSegmentCallback
        leadingOverlapSampleCount = 0
        lock.unlock()

        // Always start from a fresh engine so any prior HAL claim is fully released
        engine = AVAudioEngine()

        let inputNode = engine.inputNode

        if let uid = deviceUID, let deviceID = Self.audioDeviceID(forUID: uid) {
            do {
                try inputNode.auAudioUnit.setDeviceID(deviceID)
                owLog("[AudioEngine] Using input device UID=\(uid) id=\(deviceID)")
            } catch {
                owLog("[AudioEngine] Failed to set input device \(uid): \(error). Falling back to default.")
            }
        } else {
            owLog("[AudioEngine] Using system default input")
        }

        let format = inputNode.outputFormat(forBus: 0)
        owLog("[AudioEngine] Recording format: \(format.sampleRate)Hz, \(format.channelCount)ch")

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: format, to: targetFormat) else {
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
        self.convertedBuffer = convertedBuffer
        lock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)

            // The waveform is presentation-only. Limit UI work to 8 Hz while preserving every
            // microphone sample for transcription.
            let now = Date()
            if now.timeIntervalSince(self.lastLevelUpdate) >= self.levelUpdateInterval {
                var rms: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
                self.lastLevelUpdate = now
                self.levelCallback?(rms)
            }

            self.lock.lock()
            self.convert(buffer)
            self.lock.unlock()
        }

        do {
            try engine.start()
            owLog("[AudioEngine] Engine started")
        } catch {
            owLog("[AudioEngine] Failed to start: \(error)")
        }
    }

    func stopRecording() -> [Float]? {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Drop the AUAudioUnit and its HAL device claim now, not lazily on the next start.
        // This lets a Bluetooth headset return to A2DP immediately instead of lingering in HFP/SCO.
        engine.reset()
        engine = AVAudioEngine()
        levelCallback = nil

        lock.lock()
        flushConverter()
        let captured = flattenedSamples()
        let callback = segmentCallback
        let finalOverlap = leadingOverlapSampleCount
        sampleChunks = []
        capturedSampleCount = 0
        converter = nil
        convertedBuffer = nil
        segmentCallback = nil
        leadingOverlapSampleCount = 0
        lock.unlock()

        // Segmented callers receive the final bounded unit through the same ordered callback
        // path. Legacy callers keep the original return-value behavior unchanged.
        if let callback {
            if !captured.isEmpty {
                deliver(CompletedAudioSegment(samples: captured, overlapSampleCount: finalOverlap), to: callback)
            }
            return nil
        }
        return captured.isEmpty ? nil : captured
    }

    /// Allows an async owner to establish that all callbacks queued before this call have begun
    /// and finished. Segment callbacks themselves must not synchronously call this method.
    func waitForCompletedSegmentDelivery() async {
        await withCheckedContinuation { continuation in
            segmentDeliveryQueue.async {
                continuation.resume()
            }
        }
    }

    // MARK: - Streaming conversion and storage

    /// Runs the one converter instance throughout a recording so resampling filter state is
    /// continuous across input buffers. This work stays inside the audio callback, but only
    /// copies the already-required 16kHz output into fixed-size storage.
    private func convert(_ inputBuffer: AVAudioPCMBuffer) {
        guard let converter, let convertedBuffer else { return }

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
            return inputBuffer
        }

        guard error == nil,
              let output = convertedBuffer.floatChannelData?[0],
              convertedBuffer.frameLength > 0 else { return }
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

    /// Keeps only the still-active segment in AudioEngine memory. AudioSegmentation chooses the
    /// exact same silence-preferred cut used by the post-recording path; retaining one second of
    /// prior audio gives the next unit context without retaining completed recordings.
    private func emitCompletedSegmentIfNeeded() {
        guard let callback = segmentCallback,
              capturedSampleCount > AudioSegmentation.maximumDuration * AudioSegmentation.sampleRate else {
            return
        }

        let activeSamples = flattenedSamples()
        let segments = AudioSegmentation.makeSegments(from: activeSamples)
        guard segments.count > 1, let completed = segments.first else { return }

        let completedSamples = Array(completed.samples)
        let completedOverlap = leadingOverlapSampleCount
        let retainedOverlap = min(
            AudioSegmentation.overlapDuration * AudioSegmentation.sampleRate,
            completedSamples.count
        )
        let remainingSamples = Array(activeSamples[(completedSamples.count - retainedOverlap)...])

        sampleChunks = []
        capturedSampleCount = 0
        remainingSamples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                appendSamples(baseAddress, count: remainingSamples.count)
            }
        }
        leadingOverlapSampleCount = retainedOverlap
        deliver(
            CompletedAudioSegment(samples: completedSamples, overlapSampleCount: completedOverlap),
            to: callback
        )
    }

    private func deliver(
        _ segment: CompletedAudioSegment,
        to callback: @escaping @Sendable (CompletedAudioSegment) -> Void
    ) {
        segmentDeliveryQueue.async {
            callback(segment)
        }
    }

    // MARK: - Device enumeration

    /// All system input devices (those exposing at least one input stream).
    static func availableInputDevices() -> [AudioInputDevice] {
        return allAudioDeviceIDs().compactMap { id in
            guard hasInputStream(deviceID: id) else { return nil }
            guard let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceNameCFString) ?? "Unknown"
            return AudioInputDevice(id: id, uid: uid, name: name, isBluetooth: isBluetoothTransport(deviceID: id))
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
}
