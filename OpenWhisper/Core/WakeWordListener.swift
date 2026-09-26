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
    /// Direct detections below this start the session at once but are double-checked by
    /// Whisper in parallel (`WakeWordVerifier.heardWakeWord`). On 25 Sep 2026 false wakes scored
    /// 0.25 and 0.44 (background talk), while real calls ran 0.25–0.98.
    /// Override: `defaults write com.openwhisper.app wakeWordConfirmedScore 0.6`
    static var confirmedScore: Float {
        let stored = UserDefaults.standard.float(forKey: "wakeWordConfirmedScore")
        return stored > 0 ? stored : 0.5
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

    /// Direct detection, with the last 2 s of audio (the word itself, normalized like
    /// `onCandidate`'s) for the speaker and word checks, and the score.
    private let onWake: ([Float], Float) -> Void
    /// Grey-zone candidate: 16 kHz mono audio in -1…1 around the word, and its peak score.
    /// Runs on the main queue; the listener keeps running meanwhile.
    var onCandidate: (([Float], Float) -> Void)?
    private var recentAudio: [Float] = []
    private var pendingCandidate: (audio: [Float], remaining: Int, peak: Float)?
    private var lastCandidate = Date.distantPast
    private let queue = DispatchQueue(label: "com.openwhisper.wakeword", qos: .utility)
    private var engine: AVAudioEngine?
    private var capture: HALInputCapture?
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
    /// Echo cancellation while something plays (see `EchoCanceller`); queue-confined state.
    private var aecActive = false
    private var aecAligner = EchoReferenceAligner()
    private var echoCanceller = EchoCanceller()
    private var aecDump: EchoDebugWriter?
    private var lastAECLog = Date()
    private var loggedMicTiming = false
    /// Main-thread: the reference stream, running while media plays on the built-in mic path.
    private var echoReference: SystemOutputReference?
    /// Main-thread copy of `mediaPlaying` (that one belongs to `queue`).
    private var mediaPlayingOnMain = false
    private var referenceGeneration = 0
    /// Queue: the reference stream whose buffers are accepted (late ones from a stopped
    /// stream must not switch cancellation back on).
    private var acceptedReference = 0
    private var configObserver: NSObjectProtocol?
    private var watchdog: DispatchSourceTimer?
    /// Uptime of the last buffer from the tap: the only reliable sign the mic is still flowing.
    private let lastAudio = OSAllocatedUnfairLock(initialState: ProcessInfo.processInfo.systemUptime)

    private(set) var isRunning = false

    init(onWake: @escaping ([Float], Float) -> Void) {
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
        mediaPlayingOnMain = playing
        updateEchoReference(playing: playing && isRunning)
    }

    /// Main thread. Starts the reference when music plays and the built-in mic is in use;
    /// otherwise stops it and returns the mic to the plain path.
    private func updateEchoReference(playing: Bool) {
        let wanted = playing && capture != nil && EchoCancellationSettings.isEnabled
        if wanted, echoReference == nil {
            guard SystemOutputReference.hasPermission else {
                owLog("[AEC] No Screen Recording permission — running without echo cancellation")
                return
            }
            referenceGeneration += 1
            let generation = referenceGeneration
            queue.async { [weak self] in self?.acceptedReference = generation }
            let reference = SystemOutputReference { [weak self] samples, pts in
                self?.queue.async { self?.ingestReference(samples, pts: pts, generation: generation) }
            }
            echoReference = reference
            Task {
                do { try await reference.start() } catch {
                    owLog("[AEC] Reference capture failed: \(error.localizedDescription)")
                    await MainActor.run { [weak self] in
                        if self?.echoReference === reference { self?.echoReference = nil }
                    }
                }
            }
        } else if !wanted, let reference = echoReference {
            echoReference = nil
            Task { await reference.stop() }
            queue.async { [weak self] in
                self?.acceptedReference = 0
                self?.deactivateAEC()
            }
        }
    }

    /// Queue: the first reference buffer switches the mic onto the cancelling path.
    private func ingestReference(_ samples: [Float], pts: Double, generation: Int) {
        guard generation == acceptedReference else { return }
        if !aecActive {
            aecActive = true
            loggedMicTiming = false
            aecAligner = EchoReferenceAligner()
            echoCanceller = EchoCanceller()
            echoCanceller.log = { owLog($0) }
            lastAECLog = Date()
            if EchoCancellationSettings.dumpsAudio {
                aecDump = EchoDebugWriter(names: ["mic", "reference"])
                if let dir = aecDump?.directory { owLog("[AEC] Dumping audio to \(dir.path)") }
            }
            owLog("[AEC] Echo cancellation active")
        }
        aecAligner.appendReference(samples, startIndex: Int((pts * Double(EchoCanceller.sampleRate)).rounded()))
    }

    /// Queue: back to the plain mic; whatever the aligner still held is scored as is.
    private func deactivateAEC() {
        guard aecActive else { return }
        aecActive = false
        let held = aecAligner.drain()
        aecAligner = EchoReferenceAligner()
        echoCanceller = EchoCanceller()
        aecDump?.close()
        aecDump = nil
        owLog("[AEC] Echo cancellation off")
        if !held.isEmpty { score(held) }
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
        // Built-in mic through a bare AUHAL unit: an AVAudioEngine pinned with setDeviceID fell
        // back to Bluetooth buds that are the system default (see `HALInputCapture`).
        if let builtIn {
            do {
                let capture = try HALInputCapture(deviceID: builtIn.id)
                let monoFormat = AVAudioFormat(standardFormatWithSampleRate: capture.format.sampleRate, channels: 1)!
                converter = AVAudioConverter(from: monoFormat, to: targetFormat)
                try capture.start { [weak self] buffer, time in
                    self?.handle(buffer, monoFormat: monoFormat, time: time)
                }
                self.capture = capture
                updateEchoReference(playing: mediaPlayingOnMain)
                peakSinceLog = 0
                lastPeakLog = Date()
                owLog("[WakeWord] Listening on \(builtIn.name) (\(Int(capture.format.sampleRate)) Hz), threshold \(Self.threshold)")
            } catch {
                owLog("[WakeWord] Failed to start: \(error)")
                stopEngine()
            }
            return
        }
        do {
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
            peakSinceLog = 0
            lastPeakLog = Date()
            // Apple's recipe: a configuration change stops the engine, restarting it keeps the tap.
            // If the input format changed underneath the tap (a device appeared or went away),
            // the restart fails; rebuild with a fresh tap instead of waiting for the watchdog.
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self, weak engine] _ in
                guard let self, let engine, self.isRunning, !engine.isRunning else { return }
                do {
                    try engine.start()
                    owLog("[WakeWord] Engine restarted after configuration change")
                } catch {
                    owLog("[WakeWord] Restart after configuration change failed: \(error) — rebuilding engine")
                    self.stopEngine()
                    self.startEngine()
                }
            }
            owLog("[WakeWord] Listening on default input, threshold \(Self.threshold)")
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
        if let capture {
            capture.stop()
            owLog("[WakeWord] Stopped listening")
        }
        capture = nil
        updateEchoReference(playing: false)
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
    private func handle(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat, time: AVAudioTime? = nil) {
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
        let raw = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        // 16 kHz sample index on the host clock, for pairing with the echo reference.
        let hostIndex = time.flatMap { $0.isHostTimeValid
            ? Int((AVAudioTime.seconds(forHostTime: $0.hostTime) * Double(EchoCanceller.sampleRate)).rounded())
            : nil }
        queue.async { [weak self] in self?.ingestMic(raw, hostIndex: hostIndex) }
    }

    /// Queue: echo-cancelled first while the reference runs, then scored.
    private func ingestMic(_ raw: [Float], hostIndex: Int?) {
        if aecActive, !loggedMicTiming {
            loggedMicTiming = true
            let now = AVAudioTime.seconds(forHostTime: mach_absolute_time()) * Double(EchoCanceller.sampleRate)
            owLog(hostIndex.map { String(format: "[AEC] Mic timestamps valid: mic time − host now = %.1f ms", (Double($0) - now) / 16) }
                  ?? "[AEC] Mic buffers have no valid host time — echo cancellation bypassed")
        }
        guard aecActive, let hostIndex else {
            score(raw)
            return
        }
        guard let pair = aecAligner.appendMic(raw, startIndex: hostIndex) else { return }
        let cleaned = echoCanceller.process(mic: pair.mic, reference: pair.reference)
        // The paired inputs; offline tuning re-runs the canceller on them.
        aecDump?.write([pair.mic, pair.reference])
        if Date().timeIntervalSince(lastAECLog) >= 10 {
            lastAECLog = Date()
            let erle = echoCanceller.takeERLESamples().sorted()
            let median = erle.isEmpty ? Float.nan : erle[erle.count / 2]
            let paired = aecAligner.takePairedPercent() ?? .nan
            owLog(String(format: "[AEC] ERLE median %.1f dB over %d blocks, paired with reference %.0f%%, filter delay %.1f ms, mic resyncs %d",
                         median, erle.count, paired,
                         Double(echoCanceller.filterDelay - EchoCanceller.lookahead) / 16, aecAligner.resyncs))
        }
        if !cleaned.isEmpty { score(cleaned) }
    }

    private func score(_ raw: [Float]) {
        // openWakeWord expects int16-scale values.
        let scale = 32767 * Self.inputGain
        let samples = raw.map { min(max($0 * scale, -32768), 32767) }
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
                let audio = Self.normalizedForWhisper(recentAudio)
                DispatchQueue.main.async { [weak self] in self?.onWake(audio, s) }
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
