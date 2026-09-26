import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// What the Mac is playing, as 16 kHz mono with host-clock timestamps: the echo reference for
/// `EchoCanceller`. Audio-only ScreenCaptureKit stream (like `SystemAudioCapture`), so it needs
/// the Screen Recording permission and shows the recording indicator while it runs.
final class SystemOutputReference: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Samples and the host-clock time (seconds) of the first one. Runs on a private queue.
    typealias Handler = @Sendable ([Float], Double) -> Void

    private let queue = DispatchQueue(label: "com.openwhisper.aec-reference", qos: .userInitiated)
    private let handler: Handler
    private var stream: SCStream?
    private var loggedTiming = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Never prompts: without the permission the caller just runs without a reference.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        // Jarvis's own replies are echo too.
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = EchoCanceller.sampleRate
        configuration.channelCount = 1
        configuration.width = 16
        configuration.height = 16
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let newStream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                 configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await newStream.startCapture()
        stream = newStream
        owLog("[AEC] Reference capture started")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do { try await stream.stopCapture() } catch { owLog("[AEC] Reference stop failed: \(error)") }
        owLog("[AEC] Reference capture stopped")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        owLog("[AEC] Reference stream stopped: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              format.mFormatID == kAudioFormatLinearPCM,
              (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 1,
              Int(format.mSampleRate) == EchoCanceller.sampleRate else { return }
        let pts = CMTimeGetSeconds(sampleBuffer.presentationTimeStamp)
        guard pts.isFinite else { return }
        if !loggedTiming {
            loggedTiming = true
            let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            owLog(String(format: "[AEC] First reference buffer: pts − host now = %.1f ms", (pts - now) * 1000))
        }
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            guard let first = buffers.first, let data = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            handler(Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)), pts)
        }
    }
}
