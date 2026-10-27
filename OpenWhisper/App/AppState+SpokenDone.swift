import Foundation
import QuartzCore

extension AppState {
    /// Check a short tail once per speech pause, without waiting for the normal endpoint.
    func checkSpokenDoneEndpoint() {
        guard recordingState == .recording, recordingInputReady, modelLoaded,
              !commandFollowUpAwaitingReplyEnd,
              let session = activeTranscriptionSession, !session.isCancelled,
              !session.doneCheckInFlight, let audioEngine,
              let transcriber = activeTranscriptionService else { return }
        let now = CACurrentMediaTime()
        let speechTime = session.doneLastSpeechTime
        guard speechTime > session.doneCheckedSpeechTime,
              now - speechTime >= 0.20, now - speechTime < 1.5,
              now - session.doneLastCheckTime >= 0.75 else { return }
        let endpoint = smartTurnEndpointDetector?.lastEndpoint
        if smartTurnEndpointDetector != nil {
            // One decode per VAD pause, not a new expensive call for every level fluctuation.
            guard let endpoint, endpoint.time > session.doneCheckedEndpointTime else { return }
        }
        let whole = endpoint != nil && session.queuedSampleCount == 0 && session.nextSegmentNumber == 0
            ? audioEngine.previewSamples(maximumCount: 20 * 16_000) : nil
        let samples = whole ?? audioEngine.recentSamples(count: 64_000)
        guard samples.count >= 6_400 else { return }
        session.doneCheckedSpeechTime = speechTime
        session.doneLastCheckTime = now
        session.doneCheckInFlight = true
        if let endpoint { session.doneCheckedEndpointTime = endpoint.time }
        let language = self.language
        let started = CACurrentMediaTime()
        let bypass = session.bypassAudioProcessing
        let previewTask = Task<String?, Never> {
            do {
                let text = try await AudioSignalProcessor.$bypassProcessing.withValue(bypass) {
                    try await transcriber.previewTranscription(audioData: samples, language: language)
                }
                owLog(String(format: "[SpeechPreview] single pass %.0f ms, usable=%@", (CACurrentMediaTime() - started) * 1000,
                             text == nil ? "false" : "true"))
                return text
            } catch {
                owLog("[SpeechPreview] Optional decode failed: \(error)")
                return nil
            }
        }
        if whole != nil, endpoint != nil {
            session.speechPreview = SpeechPreview(samples: samples, language: language, modelID: transcriptionModel,
                                                  speechTime: speechTime, task: previewTask)
        }
        Task { [weak self] in
            defer { session.doneCheckInFlight = false }
            do {
                guard let text = await previewTask.value else { return }
                guard let self, self.recordingState == .recording,
                      self.activeTranscriptionSession === session, !session.isCancelled,
                      session.doneLastSpeechTime == speechTime,
                      SpokenDoneEndpoint.removingSuffix(from: text) != nil else { return }
                // Respect the enrolled-speaker gate before accepting a spoken control word.
                if session.targetSpeakerEnabled, let profile = session.targetSpeakerProfile {
                    let score = try await self.targetSpeakerFilter.wakeSpeakerScore(samples: samples, profile: profile)
                    guard score >= TargetSpeakerFilter.wakeThreshold else { return }
                }
                guard self.recordingState == .recording, self.activeTranscriptionSession === session,
                      !session.isCancelled, session.doneLastSpeechTime == speechTime else { return }
                owLog("[SpokenDone] Final done detected; processing recording immediately")
                self.hotkey?.externalCancelHandsFree()
                self.stopRecording()
            } catch {
                owLog("[SpokenDone] Tail check failed: \(error)")
            }
        }
    }
}
