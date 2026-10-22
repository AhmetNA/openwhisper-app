import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

/// What the Mac is playing, as 16 kHz mono with host-clock timestamps: the echo reference for
/// `EchoCanceller`. Audio-only ScreenCaptureKit stream (like `SystemAudioCapture`), so it needs
/// the Screen Recording permission and shows the recording indicator while it runs.
final class SystemOutputReference: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
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
    private var stream: SCStream?
    private var loggedTiming = false
    /// Set by `start`, cleared by `stop`: while set, a stream that dies is brought back.
    private var wantsRunning = false
    private var restarting = false
    private var wakeObserver: NSObjectProtocol?
    /// Between restart attempts while the stream can't come back (screen still asleep).
    private static let restartInterval: Duration = .seconds(2)

    init(handler: @escaping Handler) {
        self.handler = OSAllocatedUnfairLock(initialState: HandlerBox(handler))
        super.init()
        // The stream dies when the screen sleeps ("Failed to find any displays") and never came
        // back by itself: the first recording after the screen woke had no reference at all and
        // took the music in whole (16 Oct 2026, 22:55). Restart it the moment the screen wakes.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.restartIfDead() }
    }

    deinit {
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Sends later buffers to `handler` instead; the stream keeps running.
    func setHandler(_ handler: @escaping Handler) {
        let box = HandlerBox(handler)
        self.handler.withLock { $0 = box }
    }

    /// Never prompts: without the permission the caller just runs without a reference.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func start() async throws {
        wantsRunning = true
        try await startStream()
    }

    private func startStream() async throws {
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
        guard wantsRunning else {
            // `stop` came while this was starting.
            try? await newStream.stopCapture()
            return
        }
        stream = newStream
        loggedTiming = false
        owLog("[AEC] Reference capture started")
    }

    func stop() async {
        wantsRunning = false
        guard let stream else { return }
        self.stream = nil
        do { try await stream.stopCapture() } catch { owLog("[AEC] Reference stop failed: \(error)") }
        owLog("[AEC] Reference capture stopped")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        owLog("[AEC] Reference stream stopped: \(error.localizedDescription)")
        if self.stream === stream { self.stream = nil }
        restartIfDead()
    }

    /// Brings a dead stream back, retrying every `restartInterval` until it runs again or
    /// `stop` is called. Without it, the Mac's playback reaches recordings uncancelled.
    private func restartIfDead() {
        guard wantsRunning, stream == nil, !restarting else { return }
        restarting = true
        Task { [weak self] in
            var attempt = 0
            while let self, self.wantsRunning, self.stream == nil {
                attempt += 1
                do {
                    try await self.startStream()
                    owLog("[AEC] Reference capture back after \(attempt) attempt(s)")
                    break
                } catch {
                    if attempt == 1 { owLog("[AEC] Reference restart failed, retrying: \(error.localizedDescription)") }
                    try? await Task.sleep(for: Self.restartInterval)
                }
            }
            self?.restarting = false
        }
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
        let handler = handler.withLock { $0 }.call
        try? sampleBuffer.withAudioBufferList { buffers, _ in
            guard let first = buffers.first, let data = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            handler(Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)), pts)
        }
    }
}

private final class HandlerBox: Sendable {
    let call: SystemOutputReference.Handler
    init(_ call: @escaping SystemOutputReference.Handler) { self.call = call }
}
