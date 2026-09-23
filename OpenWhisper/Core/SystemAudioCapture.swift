import Foundation
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import CoreGraphics

/// Splits the system output into recordings using audible activity and a quiet tail.
/// The caller decides whether a recording contains speech; this detector only finds sound.
final class SystemAudioActivityDetector {
    static let sampleRate = 16_000
    private let onsetRMS: Float = 0.008
    private let quietTailSamples = 2 * sampleRate
    private let prerollSamples = sampleRate / 2
    private let minimumClipSamples = sampleRate * 3 / 5
    private let minimumAudibleSamples = sampleRate * 3 / 10
    // Keep a long voice message together; transcription itself still runs in 3-minute
    // batches after the user finishes or silence ends the recording.
    private let maximumClipSamples = sampleRate * 30 * 60

    private var preroll: [Float] = []
    private var clip: [Float] = []
    private var quietSamples = 0
    private var audibleSamples = 0
    private var lastAudibleUptime: TimeInterval = 0
    private(set) var isRecording = false
    var onRecordingChange: ((Bool) -> Void)?
    var onClip: (([Float]) -> Void)?

    func ingest(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let frameLength = Self.sampleRate / 50 // 20 ms
        var offset = 0
        while offset < samples.count {
            let end = min(offset + frameLength, samples.count)
            let frame = samples[offset..<end]
            let power = frame.reduce(Float.zero) { $0 + $1 * $1 } / Float(frame.count)
            let audible = sqrt(power) >= onsetRMS

            if !isRecording {
                if audible {
                    isRecording = true
                    clip = preroll + frame
                    preroll.removeAll(keepingCapacity: true)
                    quietSamples = 0
                    audibleSamples = frame.count
                    lastAudibleUptime = ProcessInfo.processInfo.systemUptime
                    onRecordingChange?(true)
                } else {
                    preroll.append(contentsOf: frame)
                    if preroll.count > prerollSamples {
                        preroll.removeFirst(preroll.count - prerollSamples)
                    }
                }
            } else {
                clip.append(contentsOf: frame)
                quietSamples = audible ? 0 : quietSamples + frame.count
                if audible {
                    audibleSamples += frame.count
                    lastAudibleUptime = ProcessInfo.processInfo.systemUptime
                }
                if quietSamples >= quietTailSamples || clip.count >= maximumClipSamples {
                    finish()
                }
            }
            offset = end
        }
    }

    /// Some audio streams stop delivering buffers as soon as playback ends.
    func checkForSilence(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if isRecording && now - lastAudibleUptime >= 2 {
            finish()
        }
    }

    func finish() {
        guard isRecording else { return }
        let completed = clip
        let audibleCount = audibleSamples
        clip = []
        quietSamples = 0
        audibleSamples = 0
        isRecording = false
        onRecordingChange?(false)
        if completed.count >= minimumClipSamples && audibleCount >= minimumAudibleSamples {
            onClip?(completed)
        }
    }
}

/// ScreenCaptureKit delivers the mixed Mac output directly, without opening a microphone.
/// Only an audio output is installed; video frames are never received or retained.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.openwhisper.system-audio", qos: .userInitiated)
    private let detector = SystemAudioActivityDetector()
    private var silenceTimer: DispatchSourceTimer?
    private var stream: SCStream?
    private var didLogUnexpectedFormat = false

    var onClip: (@Sendable ([Float]) -> Void)?
    var onRecordingChange: (@Sendable (Bool) -> Void)?
    var onError: (@Sendable (String) -> Void)?

    override init() {
        super.init()
        detector.onClip = { [weak self] samples in self?.onClip?(samples) }
        detector.onRecordingChange = { [weak self] active in self?.onRecordingChange?(active) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.detector.checkForSilence() }
        silenceTimer = timer
        timer.resume()
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
        configuration.sampleRate = SystemAudioActivityDetector.sampleRate
        configuration.channelCount = 1
        configuration.width = 16
        configuration.height = 16
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await newStream.startCapture()
        stream = newStream
        owLog("[SystemAudio] Capture started")
    }

    func stop() async {
        queue.sync {
            detector.finish()
            silenceTimer?.cancel()
            silenceTimer = nil
        }
        if let stream {
            self.stream = nil
            do { try await stream.stopCapture() }
            catch { owLog("[SystemAudio] Stop failed: \(error)") }
        }
        owLog("[SystemAudio] Capture stopped")
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
              Int(format.mSampleRate) == SystemAudioActivityDetector.sampleRate else {
            if !didLogUnexpectedFormat {
                didLogUnexpectedFormat = true
                onError?("Bilgisayar sesi beklenen 16 kHz mono biçiminde gelmedi.")
            }
            return
        }
        do {
            try sampleBuffer.withAudioBufferList { buffers, _ in
                guard let first = buffers.first, let data = first.mData else { return }
                let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
                let samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
                detector.ingest(samples)
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
