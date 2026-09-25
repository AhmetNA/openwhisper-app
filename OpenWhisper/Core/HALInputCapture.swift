import AVFoundation
import AudioToolbox

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
    private let unit: AUAudioUnit
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
        self.buffer = buffer
        self.maxFrames = maxFrames
    }

    /// Starts the hardware; `handler` runs on the real-time I/O thread with a buffer that is
    /// reused for the next callback (copy what you keep).
    func start(handler: @escaping Handler) throws {
        try unit.allocateRenderResources()
        let render = unit.renderBlock
        let buffer = self.buffer
        let maxFrames = self.maxFrames
        let sampleRate = format.sampleRate
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
            handler(buffer, AVAudioTime(audioTimeStamp: timestamp, sampleRate: sampleRate))
        }
        try unit.startHardware()
    }

    func stop() {
        unit.stopHardware()
        unit.inputHandler = nil
        unit.deallocateRenderResources()
    }
}

enum HALInputCaptureError: Error {
    case noUsableFormat
}
