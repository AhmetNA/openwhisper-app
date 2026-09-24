import Foundation

/// Decides when a voice-triggered recording (openwhisper:// URL — no key to release) is over,
/// from the raw microphone level alone.
///
/// Everything is relative to the room: this microphone's normal dictation runs -63 to -43 dBFS
/// mean (see `AudioSignalProcessor.inputGain`), so any absolute speech gate would reject real
/// speech. Instead the detector tracks the room's noise floor, learns how loud the person
/// talking to it is, and ends the recording once the level stays closer to the room than to
/// that person for `silenceToStop`.
///
/// Feed it the *raw* RMS (not `AppState.audioLevel`, whose display mapping clamps everything
/// below about -64 dBFS raw to zero) with a timestamp taken in the audio callback, so main-thread
/// stalls can't bunch frames together and distort silence durations.
struct VoiceEndpointDetector {
    struct Config {
        /// Continuous quiet after speech that ends the recording. This is the whole perceived
        /// pause: auto-stop skips the 0.4 s release tail, since the speech ended this long ago.
        var silenceToStop: TimeInterval = 1.0
        /// Nobody spoke at all → the trigger was probably false; discard instead of transcribing
        /// silence (Whisper hallucinates on it).
        var noSpeechTimeout: TimeInterval = 6
        var maxDuration: TimeInterval = 120
        /// A frame counts toward speech onset when it is this far above the floor… Quiet
        /// dictation on this mic sits only ~9 dB over the room, so this must stay well under that.
        var onsetMarginDB: Float = 6
        /// …for at least this long (filters out clicks and single loud frames).
        var onsetDuration: TimeInterval = 0.2
        /// End threshold sits this fraction of the way from the floor up to the speaker's level:
        /// floor -72, speaker -55 → quiet below about -65 dBFS.
        var endFraction: Float = 0.4
        var minEndMarginDB: Float = 5
        /// How fast the floor may rise in quiet frames (dB/s). It drops quickly (EMA below), so a
        /// floor first seeded by speech settles on the first pause between words.
        var floorRiseDBPerSecond: Float = 1.0
        var floorFallSmoothing: Float = 0.3
        /// Frames below this are engine start-up zeros or dropouts, not the room. Letting one
        /// through would pin the floor near -120 and make room noise look like speech forever.
        var dropoutDB: Float = -100
    }

    enum Decision: Equatable {
        case continueRecording
        case stop
        case stopMaxDuration
        case cancelNoSpeech
    }

    let config: Config
    private let startTime: TimeInterval
    private var lastTime: TimeInterval?

    private(set) var floorDB: Float?
    private(set) var speakerDB: Float?
    private(set) var speechDetected = false
    private var onsetAccumulated: TimeInterval = 0
    private var onsetSumDB: Float = 0
    private var onsetFrames = 0
    private var silentFor: TimeInterval = 0

    /// Frames before this are ignored (timeouts still count from `startTime`). Used when the
    /// session paused music: the first few hundred ms still carry the song, which would
    /// otherwise register as speech onset.
    private let ignoreUntil: TimeInterval

    init(startTime: TimeInterval, config: Config = Config(), ignoreUntil: TimeInterval? = nil) {
        self.startTime = startTime
        self.config = config
        self.ignoreUntil = ignoreUntil ?? startTime
    }

    static func dBFS(fromRMS rms: Float) -> Float {
        max(20 * log10(max(rms, 1e-7)), -120)
    }

    var endThresholdDB: Float? {
        guard let floorDB, let speakerDB else { return nil }
        return max(floorDB + config.minEndMarginDB, floorDB + config.endFraction * (speakerDB - floorDB))
    }

    mutating func process(rms: Float, at time: TimeInterval) -> Decision {
        let dB = Self.dBFS(fromRMS: rms)
        // Level callbacks arrive at ~20 Hz; clamp so one late callback can't count as a long pause.
        let dt = min(max(time - (lastTime ?? time), 0), 0.2)
        lastTime = time
        if dB < config.dropoutDB || time < ignoreUntil { return timeoutDecision(at: time) }

        guard let floor = floorDB else {
            floorDB = dB
            return .continueRecording
        }

        let onsetThreshold = floor + config.onsetMarginDB
        let isLoud = dB > onsetThreshold

        // Floor: drop immediately, rise slowly and only on frames that don't look like speech.
        if dB < floor {
            floorDB = floor + config.floorFallSmoothing * (dB - floor)
        } else if !isLoud {
            floorDB = min(dB, floor + config.floorRiseDBPerSecond * Float(dt))
        }

        if !speechDetected {
            if isLoud {
                onsetAccumulated += dt
                onsetSumDB += dB
                onsetFrames += 1
            } else {
                onsetAccumulated = 0
                onsetSumDB = 0
                onsetFrames = 0
            }
            if onsetAccumulated >= config.onsetDuration {
                speechDetected = true
                // Averaged over the onset window so one spike (a door, a key clack) can't set
                // the speaker level above real speech and cut the sentence short.
                speakerDB = onsetSumDB / Float(onsetFrames)
            }
        } else if let endThreshold = endThresholdDB {
            if dB >= endThreshold {
                silentFor = 0
                if isLoud, let speaker = speakerDB {
                    speakerDB = speaker + 0.1 * (dB - speaker)
                }
            } else {
                silentFor += dt
            }
        }

        if speechDetected && silentFor >= config.silenceToStop { return .stop }
        return timeoutDecision(at: time)
    }

    private func timeoutDecision(at time: TimeInterval) -> Decision {
        let elapsed = time - startTime
        if elapsed >= config.maxDuration { return speechDetected ? .stopMaxDuration : .cancelNoSpeech }
        if !speechDetected && elapsed >= config.noSpeechTimeout { return .cancelNoSpeech }
        return .continueRecording
    }

    var summary: String {
        func fmt(_ v: Float?) -> String { v.map { String(format: "%.1f", $0) } ?? "nil" }
        return "floor=\(fmt(floorDB))dBFS speaker=\(fmt(speakerDB))dBFS endThreshold=\(fmt(endThresholdDB))dBFS"
    }
}
