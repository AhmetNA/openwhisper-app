import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    func setupWakeWordListener() {
        let listener = WakeWordListener { [weak self] audio, score in
            MainActor.assumeIsolated { self?.handleDirectWake(audio: audio, score: score) }
        }
        listener.onCandidate = { [weak self] audio, peak in
            MainActor.assumeIsolated { self?.verifyWakeCandidate(audio: audio, peak: peak) }
        }
        listener.onProblemChange = { [weak self] in self?.updateWakeWordListener() }
        listener.prepare()
        listener.priorityUIDs = inputPriorityUIDs
        wakeWordListener = listener
        let mediaMonitor = SystemMediaActivityMonitor { [weak self] playing in
            guard let self else { return }
            self.mediaPlaying = playing
            self.wakeWordListener?.setMediaPlaying(playing)
            self.updateWakeWordListener()
        }
        mediaActivityMonitor = mediaMonitor
        mediaMonitor.start()
        observeSleepForWakeWord()
        updateWakeWordListener()
        prepareWakeSpeakerModel()
    }

    /// Score above the direct threshold: start listening at once, so words right after
    /// "Jarvis" aren't lost. With "Yalnızca Benim Sesim" the speaker check runs meanwhile: a
    /// match lets the recording through as the user's; no match doesn't end the session (the
    /// wake-time check scored the real user 0.11–0.38 about half the time, 26 Sep 2026), the
    /// recording's own speaker filter decides, and a weak "Jarvis" must still be confirmed by
    /// Whisper.
    func handleDirectWake(audio: [Float], score: Float) {
        // The pause after a rejected wake is for weak triggers: on 27 Oct 2026 it swallowed a
        // 0.84 call 4 s after a rejected 0.31 one.
        guard wakeWordEnabled, score >= WakeWordListener.confirmedScore
                || ProcessInfo.processInfo.systemUptime >= whisperWakeRetryAfter else { return }
        if whisperSuspendedForIdle || pendingWhisperWake != nil {
            beginPendingWhisperWake(audio: audio, score: score, isDirect: true)
            return
        }
        owLog("[OpenWhisper] Voice session requested (wake word)")
        pendingWakeSpeakerVerified = false
        let clipID = beginWakeClip(audio: audio, score: score, kind: "direct")
        startVoiceSession(trigger: .wakeWord)
        guard targetSpeakerGuardsWakeWord else {
            if score < WakeWordListener.confirmedScore { confirmDirectWake(audio: audio, score: score, clipID: clipID) }
            recordWakeSpeakerScoreOnly(audio: audio, clipID: clipID)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if await self.wakeSpeakerMatches(audio: audio, clipID: clipID) {
                self.markWakeSpeakerVerified()
                if score < WakeWordListener.confirmedScore { self.shadowWakeWordCheck(audio: audio, clipID: clipID) }
            } else if score < WakeWordListener.confirmedScore {
                self.confirmDirectWake(audio: audio, score: score, clipID: clipID)
            } else {
                owLog("[WakeWord] Voice not matched at the wake word; the recording's speaker filter decides")
            }
        }
    }

    /// Opens the `WakeClipLog` record for a trigger about to start a session. A previous clip
    /// whose session never started (hotkey busy) is closed first.
    func beginWakeClip(audio: [Float], score: Float, kind: String) -> UUID? {
        WakeClipLog.shared.finish(pendingWakeClipID, outcome: "not started")
        let id = WakeClipLog.shared.begin(audio: audio, wakeScore: score, kind: kind)
        pendingWakeClipID = hotkey?.isIdle == true ? id : nil
        if pendingWakeClipID == nil { WakeClipLog.shared.finish(id, outcome: "not started") }
        return id
    }

    /// With the voice guard off but a profile enrolled, the wake clip is still scored for the log.
    func recordWakeSpeakerScoreOnly(audio: [Float], clipID: UUID?) {
        guard clipID != nil, let profile = wakeTargetSpeakerProfile else { return }
        let filter = targetSpeakerFilter
        Task { [weak self] in
            guard let score = try? await filter.wakeSpeakerScore(samples: audio, profile: profile), self != nil else { return }
            WakeClipLog.shared.update(clipID) { $0.speakerScore = score }
        }
    }

    func markWakeSpeakerVerified() {
        if recordingState == .recording, let session = activeTranscriptionSession, session.trigger == .wakeWord {
            session.wakeSpeakerVerified = true
        } else {
            pendingWakeSpeakerVerified = true
        }
    }

    /// A weak direct detection: the session is already recording (no added latency) while
    /// Whisper checks the clip for "Jarvis"; without it the recording is dropped untranscribed.
    func confirmDirectWake(audio: [Float], score: Float, clipID: UUID?) {
        guard modelLoaded, let transcriber = activeTranscriptionService else { return }
        activeWhisperWakeChecks += 1
        wakeConfirmationID &+= 1
        let id = wakeConfirmationID
        let started = Date()
        Task { [weak self] in
            guard let self else { return }
            defer { self.activeWhisperWakeChecks -= 1 }
            let verdict = await WakeWordVerifier.heardWakeWord(audio: audio, transcriber: transcriber)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            WakeClipLog.shared.update(clipID) { $0.wordCheck = Self.wakeClipWordCheck(verdict) }
            switch verdict {
            case .accepted(let why):
                owLog(String(format: "[WakeWord] Weak detection %.2f confirmed in %d ms — %@", score, ms, why))
            case .rejected(let why):
                guard id == self.wakeConfirmationID, self.recordingState == .recording else {
                    owLog(String(format: "[WakeWord] Weak detection %.2f rejected in %d ms, session already over — %@", score, ms, why))
                    return
                }
                // Never close the moment it opened: the session stays up at least
                // `minimumRejectedWakeOpen` (16 Oct 2026: rejected and gone in 477 ms).
                if let session = self.activeTranscriptionSession {
                    let wait = Self.minimumRejectedWakeOpen - Date().timeIntervalSince(session.startedAt)
                    if wait > 0 {
                        try? await Task.sleep(for: .seconds(wait))
                        guard id == self.wakeConfirmationID, self.recordingState == .recording,
                              self.activeTranscriptionSession === session else {
                            owLog(String(format: "[WakeWord] Weak detection %.2f rejected, session over while held open — %@", score, why))
                            return
                        }
                    }
                    // The wake clip alone often transcribes empty ('' while the user really
                    // called): check it again together with what was said since it opened.
                    let since = self.audioEngine?.recentSamples(count: Int.max) ?? []
                    if !since.isEmpty {
                        let again = await WakeWordVerifier.heardWakeWord(audio: audio + since, transcriber: transcriber)
                        guard id == self.wakeConfirmationID, self.recordingState == .recording,
                              self.activeTranscriptionSession === session else { return }
                        if case .accepted(let why) = again {
                            owLog(String(format: "[WakeWord] Weak detection %.2f confirmed on the second check with %.1f s more — %@",
                                         score, Double(since.count) / 16_000, why))
                            WakeClipLog.shared.update(clipID) { $0.wordCheck = Self.wakeClipWordCheck(again) }
                            return
                        }
                    }
                }
                // Never cut the user off: Whisper mishears real calls ("Hey Jones", 16 Oct 2026,
                // 22:58, while the user was talking). The session keeps listening and ends on
                // silence like any other; with media playing only a command is taken from it.
                self.activeTranscriptionSession?.wakeUnconfirmed = true
                owLog(String(format: "[WakeWord] Weak detection %.2f not confirmed in %d ms — keeping the session open (%@): %@",
                             score, Int(Date().timeIntervalSince(started) * 1000),
                             self.mediaPlaying ? "media playing, commands only" : "nothing playing", why))
            }
        }
    }

    /// A weak "Jarvis" whose voice matched skips `confirmDirectWake`. Whether Whisper would have
    /// heard the word is only recorded (`shadow:` in the wake clip log), never acted on, until the
    /// clips show that enforcing it doesn't drop the user's own calls (WAKE-SPEAKER-PLANI.md).
    func shadowWakeWordCheck(audio: [Float], clipID: UUID?) {
        guard modelLoaded, clipID != nil, let transcriber = activeTranscriptionService else { return }
        activeWhisperWakeChecks += 1
        Task {
            defer { activeWhisperWakeChecks -= 1 }
            let verdict = await WakeWordVerifier.heardWakeWord(audio: audio, transcriber: transcriber)
            WakeClipLog.shared.update(clipID) { $0.wordCheck = "shadow " + Self.wakeClipWordCheck(verdict) }
        }
    }

    /// Whether the wake clip sounds like the enrolled user; true when the check is off. A model
    /// error lets the wake through: a failed download must not silence "Jarvis" altogether.
    func wakeSpeakerMatches(audio: [Float], clipID: UUID? = nil) async -> Bool {
        guard targetSpeakerGuardsWakeWord, let profile = wakeTargetSpeakerProfile else { return true }
        let threshold = TargetSpeakerFilter.wakeThreshold
        let started = Date()
        do {
            let score = try await targetSpeakerFilter.wakeSpeakerScore(samples: audio, profile: profile)
            let matched = score >= threshold
            WakeClipLog.shared.update(clipID) {
                $0.speakerScore = score
                $0.speakerThreshold = threshold
            }
            owLog(String(format: "[WakeWord] Speaker %@ (score %.3f, threshold %.2f, %d ms)",
                         matched ? "matched" : "rejected", score, threshold,
                         Int(Date().timeIntervalSince(started) * 1000)))
            return matched
        } catch {
            owLog("[WakeWord] Speaker check failed, allowing wake: \(error)")
            return true
        }
    }

    /// Loads the speaker model in the background so the first guarded "Jarvis" isn't slowed by it.
    func prepareWakeSpeakerModel() {
        guard targetSpeakerGuardsWakeWord else { return }
        let filter = targetSpeakerFilter
        Task.detached(priority: .utility) {
            do { try await filter.prepareModel() } catch {
                owLog("[WakeWord] Speaker model preparation failed: \(error)")
            }
        }
    }

    /// Grey-zone wake score: Whisper must hear "Jarvis" and the LLM must judge it a call rather
    /// than a song or talk about Jarvis (`WakeWordVerifier`). One check at a time.
    func verifyWakeCandidate(audio: [Float], peak: Float) {
        guard wakeWordEnabled, ProcessInfo.processInfo.systemUptime >= whisperWakeRetryAfter else { return }
        if whisperSuspendedForIdle || pendingWhisperWake != nil {
            beginPendingWhisperWake(audio: audio, score: peak)
            return
        }
        guard modelLoaded, !wakeCandidateVerifying, let transcriber = activeTranscriptionService,
              let hotkey, hotkey.isIdle else { return }
        wakeCandidateVerifying = true
        // Not yet a session: opened directly, handed to one only if the candidate is accepted.
        let clipID = WakeClipLog.shared.begin(audio: audio, wakeScore: peak, kind: "candidate")
        let mediaPlaying = self.mediaPlaying
        let ollama = ollamaAvailable
        let model = SpotifyManager.selectedOllamaModel
        let started = Date()
        Task { [weak self] in
            guard let self else { return }
            // A voice mismatch alone no longer drops the call (see `handleDirectWake`); Whisper
            // and the LLM below still have to hear a real "Jarvis".
            let speakerMatched = self.targetSpeakerGuardsWakeWord ? await self.wakeSpeakerMatches(audio: audio, clipID: clipID) : false
            if !self.targetSpeakerGuardsWakeWord { self.recordWakeSpeakerScoreOnly(audio: audio, clipID: clipID) }
            let verdict = await WakeWordVerifier.verify(
                audio: audio, transcriber: transcriber, mediaPlaying: mediaPlaying,
                ollamaAvailable: ollama, model: model
            )
            self.wakeCandidateVerifying = false
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            WakeClipLog.shared.update(clipID) { $0.wordCheck = Self.wakeClipWordCheck(verdict) }
            switch verdict {
            case .accepted(let why):
                owLog(String(format: "[WakeWord] Candidate %.2f accepted in %d ms — %@", peak, ms, why))
                self.pendingWakeSpeakerVerified = speakerMatched
                WakeClipLog.shared.finish(self.pendingWakeClipID, outcome: "not started")
                self.pendingWakeClipID = self.hotkey?.isIdle == true ? clipID : nil
                if self.pendingWakeClipID == nil { WakeClipLog.shared.finish(clipID, outcome: "not started") }
                self.startVoiceSession(trigger: .wakeWord)
            case .rejected(let why):
                owLog(String(format: "[WakeWord] Candidate %.2f rejected in %d ms — %@", peak, ms, why))
                WakeClipLog.shared.finish(clipID, outcome: "candidate rejected")
            }
        }
    }

    static func wakeClipWordCheck(_ verdict: WakeWordVerifier.Verdict) -> String {
        switch verdict {
        case .accepted(let why): "accepted: \(why)"
        case .rejected(let why): "rejected: \(why)"
        }
    }

    /// System sleep stops the listener; `didWake` only arrives on a full wake, so the DarkWakes of
    /// Power Nap never reopen the mic. With the display asleep and nothing playing, the open mic
    /// would be the only thing keeping the Mac from idle sleep, so the listener pauses then too,
    /// unless remote control holds the Mac awake on purpose (`RemoteControl`).
    func observeSleepForWakeWord() {
        let center = NSWorkspace.shared.notificationCenter
        let handlers: [(Notification.Name, (AppState) -> Void)] = [
            (NSWorkspace.willSleepNotification, { $0.systemAsleep = true }),
            (NSWorkspace.didWakeNotification, { $0.systemAsleep = false }),
            (NSWorkspace.screensDidSleepNotification, { $0.screensAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.screensAsleep = false }),
        ]
        sleepObservers = handlers.map { name, apply in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    owLog("[WakeWord] \(name.rawValue)")
                    apply(self)
                    self.updateWakeWordListener()
                }
            }
        }
    }

    /// One microphone user at a time: the listener runs while enabled and nothing else
    /// (dictation, enrollment, system-audio capture) is recording.
    func updateWakeWordListener() {
        guard let listener = wakeWordListener else { return }
        let busy = recordingState == .recording || targetSpeakerEnrollmentIsRecording || systemAudioEnabled
        let paused = systemAsleep || (screensAsleep && !mediaPlaying && !remoteControl.isHoldingAwake)
        updateDisplayAsleepWork()
        if !wakeWordEnabled || busy || paused || listener.problem != nil {
            cancelPendingWhisperWake(reason: "listener unavailable")
        }
        let speechAvailable = modelLoaded || whisperSuspendedForIdle
        let shouldRun = wakeWordEnabled && speechAvailable && !busy && !paused
        if shouldRun && !listener.isRunning {
            listener.start()
        } else if !shouldRun && listener.isRunning {
            listener.stop()
        }
        let micDenied = [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
        let problem = listener.isRunning ? listener.problem : nil
        wakeWordListening = listener.isRunning && problem == nil && !micDenied
        let blocked: String? = if !wakeWordEnabled { nil }
            else if micDenied { "Mikrofon izni yok — Sistem Ayarları › Gizlilik ve Güvenlik › Mikrofon'dan Jarvis'i açın" }
            else if listener.problem == .modelMissing { "Uyandırma modeli bulunamadı — uygulamayı yeniden kurun" }
            else if listener.problem == .modelLoadFailed { "Uyandırma modeli yüklenemedi — Jarvis'i yeniden başlatın" }
            else if problem == .bluetoothOnly { "Yalnızca Bluetooth mikrofon var — Mac'in kendi mikrofonu gerekli" }
            else if problem == .micUnavailable { "Mikrofon açılamadı — başka bir uygulama kullanıyor olabilir, tekrar deneniyor" }
            else if problem == .noAudio { "Mikrofondan ses gelmiyor — tekrar deneniyor" }
            else if !listener.isRunning && !busy && !paused && speechAvailable { "Mikrofon açılamadı" }
            else if systemAudioEnabled { "“Bilgisayar sesini yazıya dök” açık — kapatınca dinler" }
            else { nil }
        wakeWordBlocked = blocked != nil
        wakeWordStatus = if !wakeWordEnabled { "Kapalı" }
            else if let blocked { blocked }
            else if pendingWhisperWake != nil { "Uyandırma doğrulanıyor — konuşmaya devam edebilirsiniz" }
            else if listener.isRunning && mediaPlaying { "Dinliyor — müzik çalarken daha yüksek sesle söyleyin" }
            else if listener.isRunning { "“Jarvis” deyince dinlemeye başlar" }
            else if paused { "Mac uykuda — duraklatıldı" }
            else if busy { "Kayıt sırasında duraklatıldı" }
            else if !modelLoaded { "Konuşma modeli yükleniyor — birazdan dinlemeye başlar" }
            else { "Mikrofon açılamadı" }
    }
}
