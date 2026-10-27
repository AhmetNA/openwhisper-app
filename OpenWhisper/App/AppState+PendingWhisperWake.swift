import Foundation

extension AppState {
    func beginPendingWhisperWake(audio: [Float], score: Float, isDirect: Bool = false) {
        guard pendingWhisperWake == nil, wakeWordEnabled, !systemAsleep,
              recordingState == .idle, pendingTranscriptionCount == 0,
              !systemAudioEnabled, !targetSpeakerEnrollmentActive,
              hotkey?.isIdle == true,
              let uid = wakeWordListener?.holdAudioForWhisper() else { return }
        let clipID = WakeClipLog.shared.begin(audio: audio, wakeScore: score, kind: "deferred")
        let request = PendingWhisperWake(inputUID: uid, clipID: clipID)
        pendingWhisperWake = request
        lastWhisperActivity = Date()
        let hadMedia = mediaPlaying
        let ollama = ollamaAvailable
        let model = SpotifyManager.selectedOllamaModel
        owLog("[WhisperWake] Capturing bounded audio while Whisper loads")
        updateWakeWordListener()

        whisperWakeTimeoutTask = Task { [weak self, weak request] in
            do { try await Task.sleep(for: .seconds(PendingWhisperWake.timeout)) } catch { return }
            guard let self, let request, self.pendingWhisperWake === request else { return }
            self.cancelPendingWhisperWake(reason: "loading/verification timed out", retryDelay: 10)
            self.lastError = "Konuşma modeli zamanında hazırlanamadı. Yeniden seslenebilir veya Fn ile kayıt başlatabilirsiniz."
            self.updateWakeWordListener()
        }
        whisperWakeTask = Task { [weak self] in
            guard let self else { return }
            var speakerMatched = false
            let accepted = await request.evaluate(load: {
                await self.resumeIdleWhisperIfNeeded()
                return self.modelLoaded
            }, verify: {
                guard self.pendingWhisperWake === request, request.isValid(),
                      self.wakeWordEnabled, let transcriber = self.activeTranscriptionService else { return false }
                speakerMatched = self.targetSpeakerGuardsWakeWord
                    ? await self.wakeSpeakerMatches(audio: audio, clipID: clipID) : false
                guard request.isValid(), !Task.isCancelled else { return false }
                return await PendingWhisperWake.verifyWake(isDirect: isDirect, speakerMatched: speakerMatched) {
                    self.activeWhisperWakeChecks += 1
                    defer { self.activeWhisperWakeChecks -= 1 }
                    let verdict = await WakeWordVerifier.verify(audio: audio, transcriber: transcriber,
                        mediaPlaying: hadMedia, ollamaAvailable: ollama, model: model)
                    WakeClipLog.shared.update(clipID) { $0.wordCheck = Self.wakeClipWordCheck(verdict) }
                    if case .accepted = verdict { return true }
                    return false
                }
            })
            guard self.pendingWhisperWake === request else { return }
            guard accepted, self.wakeWordEnabled, !self.systemAsleep,
                  self.hotkey?.isIdle == true, self.recordingState == .idle,
                  self.wakeWordListener?.heldInputUID == uid else {
                self.cancelPendingWhisperWake(reason: "verification rejected or input changed", retryDelay: 10)
                self.updateWakeWordListener()
                return
            }
            self.pendingWakeSpeakerVerified = speakerMatched
            WakeClipLog.shared.finish(self.pendingWakeClipID, outcome: "not started")
            self.pendingWakeClipID = clipID
            // Keep the request and held audio until startRecording consumes the actual handoff.
            self.startVoiceSession(trigger: .wakeWord)
        }
    }

    func cancelPendingWhisperWake(reason: String, retryDelay: TimeInterval = 0) {
        guard let request = pendingWhisperWake else { return }
        request.cancel()
        pendingWhisperWake = nil
        whisperWakeTask?.cancel()
        whisperWakeTask = nil
        whisperWakeTimeoutTask?.cancel()
        whisperWakeTimeoutTask = nil
        wakeWordListener?.releaseAudioForWhisper()
        if pendingWakeClipID == request.clipID { pendingWakeClipID = nil }
        pendingWakeSpeakerVerified = false
        whisperWakeRetryAfter = max(whisperWakeRetryAfter, ProcessInfo.processInfo.systemUptime + retryDelay)
        // A false TV/noise candidate is not a conversation: let the idle sweep release
        // its model promptly instead of renewing the minute-long follow-up window.
        lastWhisperActivity = retryDelay > 0 ? .distantPast : Date()
        WakeClipLog.shared.finish(request.clipID, outcome: reason)
        owLog("[WhisperWake] Discarded pending wake: \(reason)")
    }

    func consumePendingWhisperWake(_ request: PendingWhisperWake) {
        guard pendingWhisperWake === request else { return }
        pendingWhisperWake = nil
        whisperWakeTimeoutTask?.cancel()
        whisperWakeTimeoutTask = nil
        whisperWakeTask = nil
        wakeWordListener?.releaseAudioForWhisper()
        lastWhisperActivity = Date()
        owLog("[WhisperWake] Verified; buffered microphone stream handed to recording")
    }
}
