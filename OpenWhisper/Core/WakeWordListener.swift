import AVFoundation

/// Listens for "(Hey) Jarvis" with the bundled openWakeWord model while music is playing —
/// the case where Vocal Shortcuts misses the phrase.
///
/// Plain microphone on purpose: measured on this Mac with Spotify playing, voice processing
/// (VPIO) ducked the music and dropped the input to digital silence for 2–7 s at a time, while
/// the raw mic scored 8 of 9 spoken "Jarvis" at or above 0.3.
final class WakeWordListener {
    /// Lower than openWakeWord's usual 0.5: in real use under music, spoken "Jarvis" scored
    /// 0.35–0.86 while non-speech stretches stayed at 0.00–0.10 (one 0.26). A false trigger only
    /// pauses Spotify and opens a voice session that cancels itself after 6 s of no speech.
    /// Override: `defaults write com.openwhisper.app wakeWordThreshold 0.2`
    static var threshold: Float {
        let stored = UserDefaults.standard.float(forKey: "wakeWordThreshold")
        return stored > 0 ? stored : 0.25
    }
    /// The raw mic runs quiet (speech -63…-43 dBFS, see `AudioSignalProcessor.inputGain`).
    /// On a recorded Spotify take, ×4 lifted real triggers 0.35→0.45 and 0.79→0.88 without
    /// clipping; ×8 added nothing further.
    private static let inputGain: Float = 4
    private let cooldown: TimeInterval = 3

    private let onWake: () -> Void
    private let queue = DispatchQueue(label: "com.openwhisper.wakeword", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var detector: WakeWordDetector?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var lastWake = Date.distantPast
    private var peakSinceLog: Float = 0
    private var lastPeakLog = Date()

    private(set) var isRunning = false

    init(onWake: @escaping () -> Void) {
        self.onWake = onWake
    }

    /// Loads the three ONNX sessions off the main thread (the CGEventTap lives there).
    func prepare() {
        queue.async { [weak self] in
            guard let self, self.detector == nil else { return }
            guard let dir = WakeWordDetector.bundledModelDirectory() else {
                owLog("[WakeWord] Model files missing from bundle — listener disabled")
                return
            }
            let t0 = Date()
            do {
                self.detector = try WakeWordDetector(modelDirectory: dir)
                owLog(String(format: "[WakeWord] Models loaded in %.0f ms", Date().timeIntervalSince(t0) * 1000))
            } catch {
                owLog("[WakeWord] Model load failed: \(error)")
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        do {
            // Cheap now (seed features are cached); queued so it lands before the first audio.
            queue.async { [weak self] in try? self?.detector?.reset() }

            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                owLog("[WakeWord] No usable input format")
                return
            }
            let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1)!
            converter = AVAudioConverter(from: monoFormat, to: targetFormat)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.handle(buffer, monoFormat: monoFormat)
            }
            try engine.start()
            self.engine = engine
            isRunning = true
            peakSinceLog = 0
            lastPeakLog = Date()
            owLog("[WakeWord] Listening (music playing), threshold \(Self.threshold)")
        } catch {
            owLog("[WakeWord] Failed to start: \(error)")
            stop()
        }
    }

    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            owLog("[WakeWord] Stopped listening")
        }
        engine = nil
        isRunning = false
    }

    /// Audio thread: take channel 0, resample to 16 kHz, hand off to the detector queue.
    private func handle(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) {
        guard let converter, let channel = buffer.floatChannelData?[0],
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return }
        mono.frameLength = buffer.frameLength
        mono.floatChannelData![0].update(from: channel, count: Int(buffer.frameLength))

        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / monoFormat.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return }
        // openWakeWord expects int16-scale values.
        let scale = 32767 * Self.inputGain
        let samples = (0..<Int(out.frameLength)).map { min(max(data[$0] * scale, -32768), 32767) }
        queue.async { [weak self] in self?.score(samples) }
    }

    private func score(_ samples: [Float]) {
        guard let detector else { return }
        let scores: [Float]
        do { scores = try detector.process(samples) } catch {
            owLog("[WakeWord] Inference failed: \(error)")
            return
        }
        let threshold = Self.threshold
        for s in scores {
            peakSinceLog = max(peakSinceLog, s)
            let now = Date()
            if s >= threshold, now.timeIntervalSince(lastWake) > cooldown {
                lastWake = now
                owLog(String(format: "[WakeWord] Detected (score %.2f)", s))
                DispatchQueue.main.async { [weak self] in self?.onWake() }
            }
        }
        // Tuning aid: the highest score in each 10 s stretch.
        if Date().timeIntervalSince(lastPeakLog) >= 10 {
            owLog(String(format: "[WakeWord] peak score last 10s: %.2f", peakSinceLog))
            peakSinceLog = 0
            lastPeakLog = Date()
        }
    }
}

/// Tracks whether Spotify is playing, from its distributed notifications. Spotify only for now:
/// voice sessions pause the music (see `AppState.startVoiceSession`), and only Spotify is
/// controllable from here — a listener running under unpausable music would never auto-stop.
final class MusicPlaybackMonitor {
    private let onChange: (Bool) -> Void
    private var playing: [String: Bool] = [:]
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        let center = DistributedNotificationCenter.default()
        for (name, player) in [("com.spotify.client.PlaybackStateChanged", "Spotify")] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                let state = note.userInfo?["Player State"] as? String
                self?.set(player, playing: state == "Playing")
            })
        }
    }

    deinit {
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
    }

    var isPlaying: Bool { playing.values.contains(true) }
    var isSpotifyPlaying: Bool { playing["Spotify"] == true }

    /// For the state at launch, before any notification arrives.
    func set(_ player: String, playing isPlaying: Bool) {
        let before = self.isPlaying
        playing[player] = isPlaying
        if self.isPlaying != before { onChange(self.isPlaying) }
    }
}
