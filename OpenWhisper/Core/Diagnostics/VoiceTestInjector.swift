import AVFoundation
import os

/// Automatic voice tests (`tools/voice_test.py`): plays a prepared clip into the microphone
/// stream as if someone said it in the room, so "Hey Jarvis, …" runs end to end (wake word,
/// handoff, recording, transcription, routing, reply) without anyone speaking.
///
/// The clip replaces what `HALInputCapture` rendered, indexed by host time rather than by a
/// read cursor: the wake listener and a recording on its own capture see the same audio at the
/// same moment, like a real voice. While a test runs the real mic is muted (a faint noise floor
/// instead), so the room and Jarvis's own replies stay out of it, and nothing is pasted (see
/// `TextInjector`). The AVAudioEngine paths (voice processing) are not covered.
///
/// Off unless `defaults write com.openwhisper.app voiceTestMode -bool true`; clips are read only
/// from `directory`, because any app or link can open an `openwhisper://` URL.
final class VoiceTestInjector: @unchecked Sendable {
    static let shared = VoiceTestInjector()

    static var enabled: Bool { UserDefaults.standard.bool(forKey: "voiceTestMode") }
    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenWhisper/VoiceTests", isDirectory: true)
    /// A test the runner never ends (crashed, killed) gives the mic back after this long.
    private static let safetyTimeout: Double = 90
    /// Lead time so the first samples are not already in the past when the clip is armed.
    private static let startDelay: Double = 0.1
    /// About −80 dBFS: digital zero can trip level and VAD logic that never sees it from a mic.
    private static let noiseFloor: Float = 0.0001

    private struct State {
        var samples: [Float] = []
        var sampleRate: Double = 48_000
        var startHost: UInt64 = 0
        var activeUntilHost: UInt64 = 0
        var bypassSpeakerChecks = true
        var focus: TextFocusStatus?
        var audible = false
        var noiseSeed: UInt32 = 0x1234_5678
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    /// A test is running: the mic is replaced, speaker checks may be bypassed, pastes are logged.
    var isActive: Bool {
        let now = mach_absolute_time()
        return state.withLock { now < $0.activeUntilHost }
    }

    /// Treat the injected voice as the enrolled user's (the default): the TTS voice would
    /// otherwise be filtered out as "someone else". `speaker=real` keeps the checks on.
    var bypassesSpeakerChecks: Bool {
        let now = mach_absolute_time()
        return state.withLock { now < $0.activeUntilHost && $0.bypassSpeakerChecks }
    }

    /// What the keyboard focus counts as for "dictate or answer" (`[Addressee]`), so a test
    /// doesn't depend on whichever app the developer has in front; nil = the real focus.
    var simulatedFocus: TextFocusStatus? {
        let now = mach_absolute_time()
        return state.withLock { now < $0.activeUntilHost ? $0.focus : nil }
    }

    /// Replies and the wake chime play at zero volume (same timing, nothing heard) unless the
    /// scenario tests what comes out of the speakers (`audible=1`).
    var mutesOutput: Bool {
        let now = mach_absolute_time()
        return state.withLock { now < $0.activeUntilHost && !$0.audible }
    }

    /// `openwhisper://voicetest/play?file=<name in directory>&speaker=user|real&audible=1`
    /// `&focus=editable|notEditable|unknown&id=<marker>`
    /// and `openwhisper://voicetest/end`.
    func handle(_ url: URL) {
        guard Self.enabled else {
            owLog("[VoiceTest] Ignored \(url.path): voiceTestMode is off")
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        switch url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
        case "play":
            guard let name = query("file"), !name.contains("/"), !name.hasPrefix(".") else {
                owLog("[VoiceTest] play needs a file name inside \(Self.directory.path)")
                return
            }
            play(Self.directory.appendingPathComponent(name), bypassSpeaker: query("speaker") != "real",
                 focus: query("focus").flatMap(TextFocusStatus.init(rawValue:)),
                 audible: query("audible") == "1", id: query("id"))
        case "end":
            state.withLock { $0.activeUntilHost = 0; $0.samples = [] }
            owLog("[VoiceTest] Ended \(query("id") ?? "")")
        default:
            owLog("[VoiceTest] Unknown action: \(url.path)")
        }
    }

    private func play(_ file: URL, bypassSpeaker: Bool, focus: TextFocusStatus?, audible: Bool, id: String?) {
        let samples: [Float]
        let sampleRate: Double
        do {
            let audio = try AVAudioFile(forReading: file)
            let format = AVAudioFormat(standardFormatWithSampleRate: audio.processingFormat.sampleRate,
                                       channels: audio.processingFormat.channelCount)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.length)) else {
                owLog("[VoiceTest] Could not allocate \(file.lastPathComponent)")
                return
            }
            try audio.read(into: buffer)
            samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            sampleRate = format.sampleRate
        } catch {
            owLog("[VoiceTest] Could not read \(file.lastPathComponent): \(error)")
            return
        }
        let duration = Double(samples.count) / sampleRate
        let start = mach_absolute_time() + UInt64(Self.startDelay * ticksPerSecond)
        let until = start + UInt64((duration + Self.safetyTimeout) * ticksPerSecond)
        state.withLock {
            $0.samples = samples
            $0.sampleRate = sampleRate
            $0.startHost = start
            $0.activeUntilHost = until
            $0.bypassSpeakerChecks = bypassSpeaker
            $0.focus = focus
            $0.audible = audible
        }
        owLog(String(format: "[VoiceTest] Playing %@ (%.2f s)%@%@%@%@", file.lastPathComponent, duration,
                     audible ? ", replies audible" : ", replies muted",
                     bypassSpeaker ? ", speaker checks bypassed" : ", speaker checks on",
                     focus.map { ", focus \($0.rawValue)" } ?? "",
                     id.map { " id \($0)" } ?? ""))
    }

    /// Real-time thread, from `HALInputCapture`: overwrites every channel of `buffer` with the
    /// clip (or the noise floor around it) while a test runs. No allocation.
    func fill(_ buffer: AVAudioPCMBuffer, hostTime: UInt64, deviceRate: Double) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }
        let channelCount = Int(buffer.format.channelCount)
        let ticksPerSecond = self.ticksPerSecond
        state.withLockUnchecked { state in
            guard hostTime < state.activeUntilHost else { return }
            let target = channels[0]
            // Clip position of the buffer's first frame, in clip samples (negative before it starts).
            let offsetSeconds = (Double(hostTime) - Double(state.startHost)) / ticksPerSecond
            let step = state.sampleRate / deviceRate
            var position = offsetSeconds * state.sampleRate
            var seed = state.noiseSeed
            let count = state.samples.count
            state.samples.withUnsafeBufferPointer { clip in
                for frame in 0..<frames {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    var sample = (Float(seed >> 8) / Float(1 << 24) * 2 - 1) * Self.noiseFloor
                    if position >= 0, count > 1 {
                        let index = Int(position)
                        if index < count - 1 {
                            let fraction = Float(position - Double(index))
                            sample += clip[index] + (clip[index + 1] - clip[index]) * fraction
                        }
                    }
                    target[frame] = sample
                    position += step
                }
            }
            state.noiseSeed = seed
            for channel in 1..<max(channelCount, 1) {
                channels[channel].update(from: target, count: frames)
            }
        }
    }
}
