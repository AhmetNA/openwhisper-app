import Foundation

extension AppState {
    static let whisperIdleSeconds: TimeInterval = 60

    /// Keep a minute of warmth for follow-ups; the small wake listener no longer needs Whisper.
    /// Every actual transcription consumer must still finish before its model is released.
    var canSuspendIdleWhisper: Bool {
        modelLoaded && !modelLoading
            && Date().timeIntervalSince(lastWhisperActivity) >= Self.whisperIdleSeconds
            && pendingWhisperWake == nil && whisperWakeTask == nil
            && transcriptionModelLoadTask == nil && whisperUnloadTask == nil
            && recordingState == .idle && activeTranscriptionSession == nil
            && pendingTranscriptionCount == 0 && !systemAudioEnabled
            && !systemAudioIsRecording && !systemAudioIsTranscribing
            && replayingRecordingID == nil && recordingPreviewTask == nil
            && !wakeCandidateVerifying && activeWhisperWakeChecks == 0 && !targetSpeakerEnrollmentActive
            && injectedTranscriptionService == nil
            && transcriptionModelRegistry.provider(for: transcriptionModel) is WhisperKitTranscriptionProvider
    }

    func startWhisperIdleMonitoring() {
        whisperIdleTask?.cancel()
        whisperIdleTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if let self, self.recordingState != .idle || self.pendingTranscriptionCount > 0
                    || self.systemAudioEnabled || self.systemAudioIsTranscribing
                    || self.replayingRecordingID != nil || self.recordingPreviewTask != nil
                    || self.activeWhisperWakeChecks > 0 || self.wakeCandidateVerifying || self.pendingWhisperWake != nil {
                    self.lastWhisperActivity = Date()
                }
                await self?.suspendIdleWhisperIfPossible()
            }
        }
    }

    func suspendIdleWhisperIfPossible() async {
        guard canSuspendIdleWhisper else { return }
        // Set the flag before awaiting: a key press can capture audio immediately and queue
        // the reload behind this release, instead of dropping the first recording.
        whisperSuspendedForIdle = true
        modelLoaded = false
        let unloading = Task { await transcriptionModelRegistry.unloadWhisperKit() }
        whisperUnloadTask = unloading
        await unloading.value
        whisperUnloadTask = nil
        owLog("[WhisperIdle] Released idle Whisper; small wake listener remains independent")
    }

    func resumeIdleWhisperIfNeeded() async {
        guard whisperSuspendedForIdle else { return }
        await loadModel()
    }
}
