import AVFoundation
import AudioToolbox
import os

/// Captures one input device through a bare AUHAL unit, bound to that device before it is
/// initialized.
///
/// Why not `AVAudioEngine` + `setDeviceID`: with Bluetooth buds as the system default input,
/// the engine's input node binds the buds first. Measured on this Mac (25 Sep 2026, Redmi Buds
/// 5 Pro): the built-in mic ran for ~3 s, then the engine silently fell back to the buds (their
/// mic running, the Mac mic idle), the tap received nothing ("Audio too short (0 samples)"),
/// and the buds dropped into call-quality mode. This unit never touches the default device.
final class HALInputCapture {
    typealias Handler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    let format: AVAudioFormat
    let deviceID: AudioDeviceID
    private let unit: AUAudioUnit
    /// Who receives the audio. Swappable while running (`replaceHandler`), so the wake listener
    /// can hand its live stream to the recording without restarting the hardware. Held for the
    /// whole callback, so after a swap returns the old handler never runs again.
    private let handler = OSAllocatedUnfairLock<Handler?>(uncheckedState: nil)
    private let buffer: AVAudioPCMBuffer
    private let maxFrames: AVAudioFrameCount

    /// `deviceID` must be an input device; audio arrives as non-interleaved Float32 at the
    /// device's own sample rate and channel count (see `format`).
    init(deviceID: AudioDeviceID, maxFrames: AVAudioFrameCount = 16_384) throws {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        unit = try AUAudioUnit(componentDescription: description)
        unit.isInputEnabled = true
        unit.isOutputEnabled = false
        try unit.setDeviceID(deviceID)

        // Input element is bus 1: its input side is the hardware, its output side is what we
        // render. Match the hardware rate so the unit does no resampling of its own.
        let hardware = unit.inputBusses[1].format
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate,
                                         channels: hardware.channelCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maxFrames)
        else { throw HALInputCaptureError.noUsableFormat }
        try unit.outputBusses[1].setFormat(format)
        unit.maximumFramesToRender = maxFrames
        self.format = format
        self.deviceID = deviceID
        self.buffer = buffer
        self.maxFrames = maxFrames
    }

    /// Starts the hardware; `handler` runs on the real-time I/O thread with a buffer that is
    /// reused for the next callback (copy what you keep).
    func start(handler: @escaping Handler) throws {
        self.handler.withLockUnchecked { $0 = handler }
        try unit.allocateRenderResources()
        let render = unit.renderBlock
        let buffer = self.buffer
        let maxFrames = self.maxFrames
        let sampleRate = format.sampleRate
        let current = self.handler
        unit.inputHandler = { _, timestamp, frameCount, bus in
            guard frameCount <= maxFrames else { return }
            buffer.frameLength = frameCount
            // Reset sizes each time: a render may shrink mDataByteSize.
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for index in 0..<list.count {
                list[index].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
            }
            var flags = AudioUnitRenderActionFlags()
            let status = render(&flags, timestamp, frameCount, bus, buffer.mutableAudioBufferList, nil)
            guard status == noErr else { return }
            let time = AVAudioTime(audioTimeStamp: timestamp, sampleRate: sampleRate)
            current.withLockUnchecked { $0?(buffer, time) }
        }
        try unit.startHardware()
    }

    /// Points the running stream at `newHandler`. `beforeSwap` runs under the same lock as the
    /// audio callback: no buffer is delivered while it runs, so audio the old handler kept can
    /// be passed on in order before the first buffer reaches the new one.
    func replaceHandler(_ newHandler: @escaping Handler, beforeSwap: () -> Void = {}) {
        handler.withLockUnchecked {
            beforeSwap()
            $0 = newHandler
        }
    }

    func stop() {
        unit.stopHardware()
        unit.inputHandler = nil
        handler.withLockUnchecked { $0 = nil }
        unit.deallocateRenderResources()
    }
}

enum HALInputCaptureError: Error {
    case noUsableFormat
}
