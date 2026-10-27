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
        let endpoint = smartTurnEndpointDetector?.lastEndpoint
        if smartTurnEndpointDetector != nil {
            // One decode per fresh VAD pause, not a new expensive call for every level
            // fluctuation. Timed by the pause itself: the level meter can miss quiet speech
            // entirely, and Silero reports the pause up to ~1.7 s after the level drops.
            guard let endpoint, endpoint.time > session.doneCheckedEndpointTime,
                  now - endpoint.time < 1.5 else { return }
        } else {
            guard speechTime > session.doneCheckedSpeechTime,
                  now - speechTime >= 0.20, now - speechTime < 1.5,
                  now - session.doneLastCheckTime >= 0.75 else { return }
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
                      session.doneLastSpeechTime == speechTime else { return }
                let spokenDone = SpokenDoneEndpoint.removingSuffix(from: text) != nil
                guard spokenDone || self.isFinishedClearCommand(text, session: session, endpoint: endpoint,
                                                                previewSampleCount: whole?.count) else { return }
                // Respect the enrolled-speaker gate before accepting a spoken control word.
                if session.targetSpeakerEnabled, let profile = session.targetSpeakerProfile {
                    let score = try await self.targetSpeakerFilter.wakeSpeakerScore(samples: samples, profile: profile)
                    guard score >= TargetSpeakerFilter.wakeThreshold else { return }
                }
                guard self.recordingState == .recording, self.activeTranscriptionSession === session,
                      !session.isCancelled, session.doneLastSpeechTime == speechTime else { return }
                if !spokenDone {
                    // Re-check after the speaker score: the user may have gone on meanwhile.
                    guard self.isFinishedClearCommand(text, session: session, endpoint: endpoint,
                                                      previewSampleCount: whole?.count) else { return }
                    owLog("[FastStop] Clear command '\(text)'; processing recording without the remaining silence")
                    self.hotkey?.externalCancelHandsFree()
                    self.stopRecording()
                    return
                }
                owLog("[SpokenDone] Final done detected; processing recording immediately")
                self.hotkey?.externalCancelHandsFree()
                self.stopRecording()
            } catch {
                owLog("[SpokenDone] Tail check failed: \(error)")
            }
        }
    }

    /// While Jarvis still reads a YouTube list, "Barış Soydan'ı açabilir misin" is a request
    /// for one of it: the reading stops and the recording is processed now, instead of after
    /// the list and the follow-up window. Only a request that names a listed video, a place
    /// in the list or "başka" counts, so Jarvis's own voice on the mic doesn't stop him.
    func checkCommandOverReply() {
        guard recordingState == .recording, recordingInputReady, modelLoaded,
              commandFollowUpAwaitingReplyEnd,
              let session = activeTranscriptionSession, !session.isCancelled,
              session.commandFollowUpDomain == .youtubeList,
              !session.doneCheckInFlight, let audioEngine,
              let transcriber = activeTranscriptionService else { return }
        let now = CACurrentMediaTime()
        guard now - session.overReplyLastCheckTime >= 1.5 else { return }
        let samples = audioEngine.recentSamples(count: 64_000)
        guard samples.count >= 16_000 else { return }
        session.overReplyLastCheckTime = now
        session.doneCheckInFlight = true
        let language = self.language
        let bypass = session.bypassAudioProcessing
        let listed = YouTubeList.listed
        Task { [weak self] in
            defer { session.doneCheckInFlight = false }
            let text = try? await AudioSignalProcessor.$bypassProcessing.withValue(bypass) {
                try await transcriber.previewTranscription(audioData: samples, language: language)
            }
            guard let text = text ?? nil,
                  let command = CommandFollowUp.resolve(text, after: .youtubeList, listed: listed),
                  let self, self.recordingState == .recording, self.commandFollowUpAwaitingReplyEnd,
                  self.activeTranscriptionSession === session, !session.isCancelled else { return }
            owLog("[FollowUp] '\(text)' while the list was read → \(command); stopping the reply")
            JarvisVoice.shared.stop()
            self.hotkey?.externalCancelHandsFree()
            self.stopRecording()
        }
    }

    /// A Jarvis command the rules alone run, whose whole audio the preview covered, with Smart
    /// Turn certain it is complete and no speech since: waiting out the rest of the silence
    /// only delays it. Anything else keeps the normal endpoint, so a pause mid-sentence never
    /// ends the recording here.
    private func isFinishedClearCommand(_ text: String, session: RecordingTranscriptionSession,
                                        endpoint: SmartTurnEndpointDetector.Endpoint?,
                                        previewSampleCount: Int?) -> Bool {
        guard session.isVoiceCommand, let endpoint, let previewSampleCount,
              let detector = smartTurnEndpointDetector,
              endpoint.probability >= 0.97, detector.lastEndpoint == endpoint,
              detector.previewCoverage.lastSpeechSample <= previewSampleCount else { return false }
        let timers = TimerManager.shared
        let context = CommandRegistry.Context(ringing: timers.ringing != nil, timerActive: !timers.timers.isEmpty,
                                              installedApps: SystemController.installedApps())
        return CommandRegistry.isClearCommand(WakeWordVerifier.strippingLeadingWakeWord(text), context: context)
    }
}
