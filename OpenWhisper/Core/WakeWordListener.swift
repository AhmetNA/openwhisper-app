import AVFoundation
import os

/// Listens for "(Hey) Jarvis" with the bundled openWakeWord model.
///
/// Power: the embedding model is ~90% of the cost, so `WakeWordActivityGate` skips it while the
/// room is quiet (scores stay exact, see `WakeWordDetector`), and inference runs at utility QoS
/// so it lands on the efficiency cores. Pinned to the built-in mic: holding a Bluetooth headset's
/// mic open would switch it to call-quality audio.
///
/// Plain microphone on purpose: measured on this Mac with Spotify playing, voice processing
/// (VPIO) ducked the music and dropped the input to digital silence for 2–7 s at a time, while
/// the raw mic scored 8 of 9 spoken "Jarvis" at or above 0.3.
final class WakeWordListener {
    /// Scores at or above this wake directly. Lower than openWakeWord's usual 0.5: in real use
    /// under music, spoken "Jarvis" scored 0.35–0.86 while non-speech stretches stayed at
    /// 0.00–0.10 (one 0.26). Real triggers on 25 Sep 2026 ran 0.27–0.48, and 10 s windows peaked
    /// at 0.13–0.23 where calls were likely missed; those now go through `onCandidate`.
    /// Override: `defaults write com.openwhisper.app wakeWordThreshold 0.3`
    static var threshold: Float {
        let stored = UserDefaults.standard.float(forKey: "wakeWordThreshold")
        return stored > 0 ? stored : 0.25
    }
    /// Scores from here up to `threshold` are only candidates: the surrounding audio is handed to
    /// `onCandidate` for Whisper + LLM confirmation (`WakeWordVerifier`).
    /// Override: `defaults write com.openwhisper.app wakeWordCandidateThreshold 0.15`
    static var candidateThreshold: Float {
        let stored = UserDefaults.standard.float(forKey: "wakeWordCandidateThreshold")
        return stored > 0 ? stored : 0.12
    }
    /// Audio kept before a candidate (the word itself) and collected after it (what follows:
    /// a pause or a command when calling, more lyrics when singing).
    private static let preRollSamples = 16000 * 2
    private static let postRollSamples = 16000 * 3 / 2
    /// The raw mic runs quiet (speech -63…-43 dBFS, see `AudioSignalProcessor.inputGain`).
    /// On a recorded Spotify take, ×4 lifted real triggers 0.35→0.45 and 0.79→0.88 without
    /// clipping; ×8 added nothing further.
    private static let inputGain: Float = 4
    private let cooldown: TimeInterval = 3

    private let onWake: () -> Void
    /// Grey-zone candidate: 16 kHz mono audio in -1…1 around the word, and its peak score.
    /// Runs on the main queue; the listener keeps running meanwhile.
    var onCandidate: (([Float], Float) -> Void)?
    private var recentAudio: [Float] = []
    private var pendingCandidate: (audio: [Float], remaining: Int, peak: Float)?
    private var lastCandidate = Date.distantPast
    private let queue = DispatchQueue(label: "com.openwhisper.wakeword", qos: .utility)
    private var engine: AVAudioEngine?
    private var detector: WakeWordDetector?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var lastWake = Date.distantPast
    private var peakSinceLog: Float = 0
    private var lastPeakLog = Date()
    private var embeddingsAtLog = 0
    private var blocksAtLog = 0
    private var levelsSinceLog: [Float] = []
    private var mediaPlaying = false
    private var configObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    /// Uptime of the last buffer from the tap: the only reliable sign the mic is still flowing.
    private let lastAudio = OSAllocatedUnfairLock(initialState: ProcessInfo.processInfo.systemUptime)

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
                self.detector?.gate = WakeWordActivityGate()
                owLog(String(format: "[WakeWord] Models loaded in %.0f ms", Date().timeIntervalSince(t0) * 1000))
            } catch {
                owLog("[WakeWord] Model load failed: \(error)")
            }
        }
    }

    /// Speaker music keeps the gate open; see `WakeWordActivityGate`.
    func setMediaPlaying(_ playing: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.mediaPlaying = playing
            self.detector?.gate?.mediaPlaying = playing
        }
    }

    /// Wanted state; the engine underneath is rebuilt by the watchdog if audio stops arriving.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        startEngine()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.checkAudioFlow() }
        timer.resume()
        watchdog = timer
    }

    func stop() {
        watchdog?.cancel()
        watchdog = nil
        stopEngine()
        isRunning = false
    }

    private func startEngine() {
        let builtIn = AudioEngine.availableInputDevices().first(where: \.isBuiltIn)
        if builtIn == nil && AudioEngine.systemDefaultInputIsBluetooth() {
            owLog("[WakeWord] Only a Bluetooth mic available — not listening (would force call-quality audio)")
            return
        }
        lastAudio.withLock { $0 = ProcessInfo.processInfo.systemUptime }
        // Cheap now (seed features are cached); queued so it lands before the first audio.
        queue.async { [weak self] in
            guard let self else { return }
            self.recentAudio.removeAll(keepingCapacity: true)
            self.pendingCandidate = nil
            guard let detector = self.detector else { return }
            try? detector.reset()
            var gate = detector.gate ?? WakeWordActivityGate()
            gate.mediaPlaying = self.mediaPlaying
            gate.warmupBlocks = 6
            detector.gate = gate
        }
        do {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            // Only switch devices when needed: every switch posts a configuration change.
            if let builtIn, !AudioEngine.systemDefaultInputIsBuiltIn() {
                try input.auAudioUnit.setDeviceID(builtIn.id)
            }
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
            peakSinceLog = 0
            lastPeakLog = Date()
            // Apple's recipe: a configuration change stops the engine, restarting it keeps the tap.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self, weak engine] _ in
                guard let self, let engine, self.isRunning, !engine.isRunning else { return }
                do {
                    try engine.start()
                    owLog("[WakeWord] Engine restarted after configuration change")
                } catch {
                    owLog("[WakeWord] Restart after configuration change failed: \(error)")
                }
            }
            owLog("[WakeWord] Listening on \(builtIn?.name ?? "default input"), threshold \(Self.threshold)")
        } catch {
            owLog("[WakeWord] Failed to start: \(error)")
            stopEngine()
        }
    }

    private func stopEngine() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            owLog("[WakeWord] Stopped listening")
        }
        engine = nil
    }

    /// Covers what the notification doesn't: a device that vanished, a start that failed.
    private func checkAudioFlow() {
        guard isRunning else { return }
        let silentFor = ProcessInfo.processInfo.systemUptime - lastAudio.withLock { $0 }
        guard silentFor > 4 else { return }
        owLog(String(format: "[WakeWord] No audio for %.0f s — rebuilding engine", silentFor))
        stopEngine()
        startEngine()
    }

    /// Audio thread: take channel 0, resample to 16 kHz, hand off to the detector queue.
    private func handle(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) {
        lastAudio.withLock { $0 = ProcessInfo.processInfo.systemUptime }
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
        let raw = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        let samples = raw.map { min(max($0 * scale, -32768), 32767) }
        queue.async { [weak self] in self?.score(samples, raw: raw) }
    }

    private func score(_ samples: [Float], raw: [Float]) {
        recentAudio.append(contentsOf: raw)
        if recentAudio.count > Self.preRollSamples { recentAudio.removeFirst(recentAudio.count - Self.preRollSamples) }
        pendingCandidate?.audio.append(contentsOf: raw)
        pendingCandidate?.remaining -= raw.count

        guard let detector else { return }
        let scores: [Float]
        do { scores = try detector.process(samples) } catch {
            owLog("[WakeWord] Inference failed: \(error)")
            return
        }
        let threshold = Self.threshold
        if !scores.isEmpty { levelsSinceLog.append(detector.lastLevelDB) }
        for s in scores {
            peakSinceLog = max(peakSinceLog, s)
            let now = Date()
            if s >= threshold, now.timeIntervalSince(lastWake) > cooldown {
                lastWake = now
                owLog(String(format: "[WakeWord] Detected (score %.2f, level %.0f dB, floor %.0f dB)",
                             s, detector.lastLevelDB, detector.gate?.floor ?? .nan))
                if pendingCandidate != nil { owLog("[WakeWord] Candidate superseded by direct detection") }
                pendingCandidate = nil
                DispatchQueue.main.async { [weak self] in self?.onWake() }
            } else if pendingCandidate != nil {
                let peak = pendingCandidate?.peak ?? 0
                pendingCandidate?.peak = max(peak, s)
            } else if s >= Self.candidateThreshold, onCandidate != nil,
                      now.timeIntervalSince(lastWake) > cooldown, now.timeIntervalSince(lastCandidate) > cooldown {
                pendingCandidate = (recentAudio, Self.postRollSamples, s)
                owLog(String(format: "[WakeWord] Candidate (score %.2f, level %.0f dB) — collecting audio to verify",
                             s, detector.lastLevelDB))
            }
        }
        if let pending = pendingCandidate, pending.remaining <= 0 {
            pendingCandidate = nil
            lastCandidate = Date()
            let audio = Self.normalizedForWhisper(pending.audio)
            DispatchQueue.main.async { [weak self] in self?.onCandidate?(audio, pending.peak) }
        }
        // Tuning aid: the highest score in each 10 s stretch, and how many blocks actually ran
        // the embedding model (the power cost; backfill included).
        if Date().timeIntervalSince(lastPeakLog) >= 10 {
            let blocks = detector.blockCount - blocksAtLog
            let embeddings = detector.embeddingCount - embeddingsAtLog
            let median = levelsSinceLog.isEmpty ? Float.nan : levelsSinceLog.sorted()[levelsSinceLog.count / 2]
            owLog(String(format: "[WakeWord] peak score last 10s: %.2f, embeddings %d/%d blocks, level median %.0f dB, floor %.0f dB",
                         peakSinceLog, embeddings, blocks, median, detector.gate?.floor ?? .nan))
            levelsSinceLog.removeAll(keepingCapacity: true)
            blocksAtLog = detector.blockCount
            embeddingsAtLog = detector.embeddingCount
            peakSinceLog = 0
            lastPeakLog = Date()
        }
    }

    /// The raw mic is quiet (speech around -50 dBFS); bring the peak to -6 dBFS for Whisper,
    /// with the gain capped so a silent clip isn't blown up into noise.
    static func normalizedForWhisper(_ audio: [Float]) -> [Float] {
        let peak = audio.reduce(0) { max($0, abs($1)) }
        guard peak > 0 else { return audio }
        let gain = min(0.5 / peak, 30)
        return audio.map { $0 * gain }
    }
}
