import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// What the Mac is playing, as 16 kHz mono with host-clock timestamps: the echo reference for
/// `EchoCanceller`. A global Core Audio process tap (every process, ours included: Jarvis's own
/// replies are echo too) in a private aggregate device. Needs the system audio recording
/// permission; without it the tap delivers silence.
///
/// Why not ScreenCaptureKit (used until 29 Oct 2026): measured with the same clicks on this
/// Mac, its buffers arrived 28–46 ms after their audio, only ~6 ms before the mic heard the echo
/// (once 4.5 ms after). The tap's arrive after ~7 ms, ~43 ms ahead of the echo.
final class SystemOutputReference: @unchecked Sendable {
    /// Samples and the host-clock time (seconds) of the first one. Runs on a private queue.
    typealias Handler = @Sendable ([Float], Double) -> Void

    private let queue = DispatchQueue(label: "com.openwhisper.aec-reference", qos: .userInitiated)
    /// Swappable so a recording can take over the wake listener's running stream.
    ///
    /// Boxed, not a bare closure (as in `HALInputCapture`): every `withLock` reabstracts a closure
    /// state through the lock's generic `inout` storage and writes the extra thunks back, so the
    /// chain grew with each buffer until calling or freeing it overflowed the stack (crashes of
    /// 16 Oct 2026, after minutes of listening with music playing).
    private let handler: OSAllocatedUnfairLock<HandlerBox>
    /// Everything below is touched only on `queue`.
    private var tap: TapDevice?
    private var loggedTiming = false
    /// Set by `start`, cleared by `stop`: while set, the tap follows default output changes.
    private var wantsRunning = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private static let outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(EchoCanceller.sampleRate),
                                             channels: 1, interleaved: false)!
    /// Host time of the first converted sample and how many came out since: buffers get
    /// back-to-back timestamps, so the aligner sees no gaps from per-buffer rounding.
    private var anchorSeconds = 0.0
    private var producedSamples = 0
    private var inputSamplesSinceAnchor = 0.0
    private var nextInputSampleTime: Float64?
    /// Re-anchor when the running timestamps drift this far from the device's host times.
    private static let maxDriftSeconds = 0.005

    init(handler: @escaping Handler) {
        self.handler = OSAllocatedUnfairLock(initialState: HandlerBox(handler))
    }

    /// Sends later buffers to `handler` instead; the tap keeps running.
    func setHandler(_ handler: @escaping Handler) {
        let box = HandlerBox(handler)
        self.handler.withLock { $0 = box }
    }

    /// The system audio permission has no public preflight: the first `start` asks, and a denied
    /// tap delivers silence, which cancels nothing.
    static var hasPermission: Bool { true }

    func start() async throws {
        try queue.sync {
            wantsRunning = true
            addOutputListener()
            if tap == nil { try startTap() }
        }
    }

    func stop() async {
        queue.sync {
            wantsRunning = false
            removeOutputListener()
            guard tap != nil else { return }
            stopTap()
            owLog("[AEC] Reference capture stopped")
        }
    }

    /// Queue.
    private func startTap() throws {
        let tap = try TapDevice { [weak self] samples, channels, rate, hostTime, sampleTime in
            self?.queue.async { self?.ingest(samples, channels: channels, rate: rate, hostTime: hostTime, sampleTime: sampleTime) }
        }
        self.tap = tap
        loggedTiming = false
        owLog("[AEC] Reference capture started (process tap, \(Int(tap.sampleRate)) Hz)")
    }

    /// Queue.
    private func stopTap() {
        tap?.stop()
        tap = nil
        converter = nil
        nextInputSampleTime = nil
    }

    /// The aggregate device is built on the default output: when that changes (headphones, a
    /// Bluetooth speaker), rebuild on the new one, or the Mac's playback loses its reference.
    private func addOutputListener() {
        guard outputListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuild() }
        var address = Self.outputAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr {
            outputListener = listener
        }
    }

    private func removeOutputListener() {
        guard let listener = outputListener else { return }
        var address = Self.outputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        outputListener = nil
    }

    /// Queue.
    private func rebuild() {
        guard wantsRunning else { return }
        stopTap()
        do {
            try startTap()
            owLog("[AEC] Reference capture rebuilt for the new output device")
        } catch {
            owLog("[AEC] Reference rebuild failed: \(error.localizedDescription)")
        }
    }

    /// Queue: downmix, convert to 16 kHz and pass on with back-to-back timestamps.
    private func ingest(_ interleaved: [Float], channels: Int, rate: Double, hostTime: UInt64, sampleTime: Float64) {
        guard tap != nil, channels > 0, rate > 0 else { return }
        let frames = interleaved.count / channels
        guard frames > 0 else { return }
        let hostSeconds = AVAudioTime.seconds(forHostTime: hostTime)

        if converter == nil || inputFormat?.sampleRate != rate {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
                  let newConverter = AVAudioConverter(from: format, to: outputFormat) else { return }
            newConverter.primeMethod = .none
            inputFormat = format
            converter = newConverter
            nextInputSampleTime = nil
        }
        guard let converter, let inputFormat,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }

        // A jump in the device's sample clock (glitch, restart) or drift against the host clock:
        // start the timestamps over from this buffer.
        let expectedSeconds = anchorSeconds + inputSamplesSinceAnchor / rate
        if nextInputSampleTime.map({ abs($0 - sampleTime) > 1 }) ?? true
            || abs(expectedSeconds - hostSeconds) > Self.maxDriftSeconds {
            converter.reset()
            anchorSeconds = hostSeconds
            producedSamples = 0
            inputSamplesSinceAnchor = 0
        }
        nextInputSampleTime = sampleTime + Float64(frames)
        inputSamplesSinceAnchor += Double(frames)

        // Own downmix: AVAudioConverter's multichannel-to-mono can pick a single channel.
        let mono = input.floatChannelData![0]
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += interleaved[frame * channels + channel] }
            mono[frame] = sum * scale
        }
        input.frameLength = AVAudioFrameCount(frames)

        let capacity = AVAudioFrameCount(Double(frames) * outputFormat.sampleRate / rate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        let count = Int(output.frameLength)
        guard error == nil, count > 0 else { return }
        let pts = anchorSeconds + Double(producedSamples) / outputFormat.sampleRate
        producedSamples += count

        if !loggedTiming {
            loggedTiming = true
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time())
            owLog(String(format: "[AEC] First reference buffer: pts − host now = %.1f ms", (pts - now) * 1000))
        }
        let samples = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: count))
        handler.withLock { $0 }.call(samples, pts)
    }
}

/// A private global tap (no process excluded, nothing muted) inside a private aggregate device
/// on the default output, with an IOProc reading it.
private final class TapDevice {
    /// Interleaved samples, channel count, sample rate, and host and device sample time of the
    /// first frame. Runs on the real-time I/O thread.
    typealias Sink = ([Float], Int, Double, UInt64, Float64) -> Void

    let sampleRate: Double
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(sink: @escaping Sink) throws {
        guard let output = Self.defaultOutputUID() else { throw SystemOutputReferenceError.noOutputDevice }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw SystemOutputReferenceError.coreAudio("tap", status) }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OpenWhisper echo reference",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw SystemOutputReferenceError.coreAudio("aggregate device", status)
        }

        var rateAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(aggregateID, &rateAddress, 0, nil, &size, &rate)
        sampleRate = rate

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inputData, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            // The tap is the aggregate's only input stream: one interleaved Float32 buffer.
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let channels = Int(max(buffer.mNumberChannels, 1))
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            sink(samples, channels, rate, inputTime.pointee.mHostTime, inputTime.pointee.mSampleTime)
        }
        guard status == noErr, procID != nil else {
            destroy()
            throw SystemOutputReferenceError.coreAudio("IOProc", status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            destroy()
            throw SystemOutputReferenceError.coreAudio("start", status)
        }
    }

    func stop() { destroy() }

    private func destroy() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            self.procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}

enum SystemOutputReferenceError: LocalizedError {
    case noOutputDevice
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noOutputDevice: "No default output device"
        case .coreAudio(let step, let status): "Core Audio \(step) failed (\(status))"
        }
    }
}

private final class HandlerBox: Sendable {
    let call: SystemOutputReference.Handler
    init(_ call: @escaping SystemOutputReference.Handler) { self.call = call }
}
