import Foundation
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import CoreGraphics

/// Keeps everything heard between Başlat and Bitir as one recording. Silence never ends
/// the recording: voice messages often have pauses, and splitting them made every part
/// overwrite the previous one on the clipboard. Long pauses are only shortened (to ~1 s)
/// so Whisper keeps the sentence break but does not invent text over minutes of silence.
final class SystemAudioSessionRecorder {
    static let sampleRate = 16_000
    /// -42 dBFS: counts as something actually heard.
    private let audibleRMS: Float = 0.008
    /// -50 dBFS: only frames this quiet belong to a pause that may be shortened, so soft
    /// speech between the two thresholds is always kept.
    private let pauseRMS: Float = 0.003
    private let keptPauseSamples = sampleRate
    private let minimumAudibleSamples = sampleRate * 3 / 10
    /// 90 minutes of kept audio (~350 MB of Float samples) — the session is then finished.
    static let maximumSamples = sampleRate * 90 * 60

    private var samples: [Float] = []
    private var pause: [Float] = []
    private var audibleSamples = 0
    private(set) var reachedLimit = false
    var onLimitReached: (() -> Void)?

    var keptSampleCount: Int { samples.count + min(pause.count, keptPauseSamples) }

    func ingest(_ input: [Float]) {
        guard !input.isEmpty, !reachedLimit else { return }
        let frameLength = Self.sampleRate / 50 // 20 ms
        var offset = 0
        while offset < input.count {
            let end = min(offset + frameLength, input.count)
            let frame = input[offset..<end]
            let rms = sqrt(frame.reduce(Float.zero) { $0 + $1 * $1 } / Float(frame.count))
            if rms < pauseRMS {
                pause.append(contentsOf: frame)
                // Bound memory during a long pause: keep its first and last half second.
                if pause.count > keptPauseSamples * 2 {
                    let half = keptPauseSamples / 2
                    pause.removeSubrange(half..<(pause.count - half))
                }
            } else {
                flushPause()
                samples.append(contentsOf: frame)
                if rms >= audibleRMS { audibleSamples += frame.count }
            }
            offset = end
            if samples.count >= Self.maximumSamples {
                reachedLimit = true
                onLimitReached?()
                return
            }
        }
    }

    /// Returns the whole session, or nil when nothing audible was heard (Whisper would only
    /// hallucinate on it). The recorder is empty afterwards.
    func finish() -> [Float]? {
        flushPause()
        let completed = samples
        let audible = audibleSamples
        samples = []
        audibleSamples = 0
        reachedLimit = false
        return audible >= minimumAudibleSamples ? completed : nil
    }

    private func flushPause() {
        guard !pause.isEmpty else { return }
        if pause.count <= keptPauseSamples {
            samples.append(contentsOf: pause)
        } else {
            let half = keptPauseSamples / 2
            samples.append(contentsOf: pause.prefix(half))
            samples.append(contentsOf: pause.suffix(half))
        }
        pause.removeAll(keepingCapacity: true)
    }
}

struct SystemAudioRecording: Sendable {
    let samples: [Float]
    let startedAt: Date
    /// Wall-clock length of the session; `samples` is shorter when pauses were shortened.
    let elapsed: TimeInterval
}

/// ScreenCaptureKit delivers the mixed Mac output directly, without opening a microphone.
/// Only an audio output is installed; video frames are never received or retained.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.openwhisper.system-audio", qos: .userInitiated)
    private let recorder = SystemAudioSessionRecorder()
    private var stream: SCStream?
    private var didLogUnexpectedFormat = false
    private var startedAt = Date()
    private var startedUptime = ProcessInfo.processInfo.systemUptime
    /// End time of the last delivered buffer; ScreenCaptureKit may skip buffers while the
    /// output is silent, and the gap is filled so words on either side do not run together.
    private var lastBufferEnd: CMTime?

    var onLimitReached: (@Sendable () -> Void)?
    var onError: (@Sendable (String) -> Void)?

    override init() {
        super.init()
        recorder.onLimitReached = { [weak self] in self?.onLimitReached?() }
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw SystemAudioCaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = SystemAudioSessionRecorder.sampleRate
        configuration.channelCount = 1
        configuration.width = 16
        configuration.height = 16
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await newStream.startCapture()
        stream = newStream
        queue.sync {
            startedAt = Date()
            startedUptime = ProcessInfo.processInfo.systemUptime
        }
        owLog("[SystemAudio] Capture started")
    }

    /// Ends the session and returns everything recorded since `start()`.
    /// - Parameter tail: keeps listening this long first, so the last word that is still
    ///   playing when Bitir is pressed is not cut off.
    func stop(tail: TimeInterval = 0.7) async -> SystemAudioRecording? {
        if let stream {
            if tail > 0 { try? await Task.sleep(nanoseconds: UInt64(tail * 1_000_000_000)) }
            self.stream = nil
            do { try await stream.stopCapture() }
            catch { owLog("[SystemAudio] Stop failed: \(error)") }
        }
        // Finish on the sample queue so buffers already handed to it are included.
        let recording: SystemAudioRecording? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                let elapsed = ProcessInfo.processInfo.systemUptime - startedUptime
                let samples = recorder.finish()
                lastBufferEnd = nil
                continuation.resume(returning: samples.map {
                    SystemAudioRecording(samples: $0, startedAt: startedAt, elapsed: elapsed)
                })
            }
        }
        owLog(String(format: "[SystemAudio] Capture stopped: %.1f s kept of %.1f s",
                     Double(recording?.samples.count ?? 0) / Double(SystemAudioSessionRecorder.sampleRate),
                     recording?.elapsed ?? 0))
        return recording
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let format = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        // With 16 kHz mono configured, ScreenCaptureKit normally supplies Float32 LPCM.
        // Explicitly reject unexpected data rather than reading it as Float samples.
        guard format.mFormatID == kAudioFormatLinearPCM,
              (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame == 1,
              Int(format.mSampleRate) == SystemAudioSessionRecorder.sampleRate else {
            if !didLogUnexpectedFormat {
                didLogUnexpectedFormat = true
                onError?("Bilgisayar sesi beklenen 16 kHz mono biçiminde gelmedi.")
            }
            return
        }
        let start = sampleBuffer.presentationTimeStamp
        if let lastBufferEnd, start.isValid, lastBufferEnd.isValid {
            let gap = CMTimeGetSeconds(CMTimeSubtract(start, lastBufferEnd))
            if gap > 0.05 {
                // The recorder shortens long pauses itself; 2 s is enough to mark one.
                recorder.ingest(Array(repeating: 0, count: Int(min(gap, 2) * Double(SystemAudioSessionRecorder.sampleRate))))
            }
        }
        if start.isValid {
            lastBufferEnd = CMTimeAdd(start, sampleBuffer.duration)
        }
        do {
            try sampleBuffer.withAudioBufferList { buffers, _ in
                guard let first = buffers.first, let data = first.mData else { return }
                let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
                recorder.ingest(samples)
            }
        } catch {
            onError?("Bilgisayar sesi okunamadı: \(error.localizedDescription)")
        }
    }
}

enum SystemAudioCaptureError: LocalizedError {
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .noDisplay: "Ses yakalamak için kullanılabilir ekran bulunamadı."
        }
    }
}
