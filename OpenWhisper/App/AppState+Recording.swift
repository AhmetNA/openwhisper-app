import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

/// What the target-speaker gate's result means for one transcription batch.
private struct BatchGate {
    let isFailClosedPassthrough: Bool
    let isAmbiguousTargetMatch: Bool
    let isSingleSpeakerUncertain: Bool
    let isBelowThresholdRejection: Bool
    let shouldUseDiarization: Bool
    let skipsScreenStepDiarization: Bool
}

extension AppState {
    func startRecording() {
        recordingPreviewTask?.cancel()
        let hiddenRequested = nextWakeSessionHidden
        nextWakeSessionHidden = false
        wakeSessionHidden = false
        guard prepareForNewRecording() else { return }

        let armVoiceAutoStop = armVoiceAutoStopForNextRecording
        armVoiceAutoStopForNextRecording = false
        let recordingTrigger = hotkey?.trigger ?? .fnHold
        let deferredWake = recordingTrigger == .wakeWord ? pendingWhisperWake : nil
        if recordingTrigger != .wakeWord { cancelPendingWhisperWake(reason: "manual recording took over") }
        if recordingTrigger == .wakeWord && (!wakeWordEnabled || deferredWake.map({ !$0.accepted || !$0.isValid() }) == true) {
            cancelPendingWhisperWake(reason: "wake cancelled before recording")
            hotkey?.externalCancelHandsFree()
            return
        }
        let startsHidden = hiddenRequested && recordingTrigger == .wakeWord
        // The voice matched before the recording began: it starts shown, with the chime it skipped.
        if startsHidden && pendingWakeSpeakerVerified { WakeChime.play() }
        wakeSessionHidden = startsHidden && !pendingWakeSpeakerVerified
        let commandFollowUp = recordingTrigger == .followUp ? pendingCommandFollowUp : nil
        pendingCommandFollowUp = nil
        let claudeRecap = recordingTrigger == .followUp ? pendingClaudeMessage : nil
        let claudeMessage = claudeRecap != nil
        pendingClaudeMessage = nil
        let overReply = commandFollowUp != nil && commandFollowUpOverReply
        commandFollowUpOverReply = false
        commandFollowUpAwaitingReplyEnd = overReply
        commandFollowUpAfterReply = false
        followUpLiveText = nil
        followUpLiveStart = CACurrentMediaTime()

        // A previous session may still be transcribing. Only an already-active microphone
        // session blocks a new recording.
        guard recordingState != .recording else { return }
        clearFlowBarMessage()
        // The recap stays readable while the user words the message.
        if let claudeRecap { showFlowBarMessage(claudeRecap, durationMs: Self.flowBarDuration(ofRecap: claudeRecap)) }
        guard modelLoaded || whisperSuspendedForIdle else {
            owLog("[OpenWhisper] Cannot record — model not loaded yet")
            return
        }
        if whisperSuspendedForIdle { Task { await resumeIdleWhisperIfNeeded() } }
        let sessionStart = CACurrentMediaTime()
        // A reply follow-up behaves like "Hey Jarvis" once the user speaks (full command,
        // Smart Turn endpoint); only its no-speech window is short.
        let wakeLikeSession = [.wakeWord, .jarvisKey, .followUp].contains(recordingTrigger)
        // A deferred wake keeps the listener's microphone for this session: changing to a
        // preferred Bluetooth mic here would discard the words spoken during model loading.
        let recordingInputDeviceUID = deferredWake?.inputUID ?? resolvedInputDeviceUID(for: recordingTrigger)
        let recordingInputIsBluetooth = Self.inputIsBluetooth(uid: recordingInputDeviceUID)
        let recordingMic = TargetSpeakerMic(device: AudioEngine.availableInputDevices().first { $0.uid == recordingInputDeviceUID })
        if ![.confirmation, .followUp].contains(recordingTrigger) {
            chainedInputUID = recordingInputDeviceUID
        }
        // A handed-over wake stream is already live; a fresh Bluetooth capture is not.
        let waitsForLinkAudio = recordingInputIsBluetooth
        armEndpointDetectors(
            sessionStart: sessionStart, trigger: recordingTrigger, armVoiceAutoStop: armVoiceAutoStop,
            wakeLikeSession: wakeLikeSession, deferredWake: deferredWake != nil,
            followsCommand: commandFollowUp != nil, claudeMessage: claudeMessage, overReply: overReply,
            inputIsBluetooth: recordingInputIsBluetooth, mic: recordingMic
        )
        // The buds' call-mode mic scores 0.2–0.35 against the Mac-mic profile and a USB mic
        // 0.33–0.43, so every batch was rejected: they are filtered only against their own profile.
        let sessionProfile = Self.sessionTargetSpeakerProfile(
            mic: recordingMic, mac: targetSpeakerProfile, buds: budsTargetSpeakerProfile, external: externalTargetSpeakerProfile
        )
        if targetSpeakerEnabled && recordingMic != .mac {
            owLog(sessionProfile == nil
                ? "[TargetSpeaker] \(recordingMic) input: speaker filter off (no \(recordingMic) profile)"
                : "[TargetSpeaker] \(recordingMic) input: filtering against the \(recordingMic) profile")
        }
        armOwnVoiceStopGate(
            sessionStart: sessionStart, mic: recordingMic, profile: sessionProfile,
            armVoiceAutoStop: armVoiceAutoStop, wakeLikeSession: wakeLikeSession, overReply: overReply
        )
        let pausesMedia = pauseMediaForRecording(
            sessionStart: sessionStart, trigger: recordingTrigger, mic: recordingMic,
            profile: sessionProfile, followsCommand: commandFollowUp != nil
        )

        // 1. Start microphone recording asynchronously off main thread FIRST — before any UI
        // work (flow bar appearance, NSWorkspace query) gets a chance to occupy the main thread
        // and delay this dispatch. Read everything the background block needs up front so the
        // dispatch itself has zero main-thread work between it and the guards above.
        let bypassProcessing = bypassAudioProcessing
        // Also on the raw mic: it only takes out what the Mac plays; DeepFilter and gain stay off.
        let echoCancellation = recordingEchoCancellationWanted(mic: recordingMic)
        let processingMode = decideProcessingMode(
            bypassProcessing: bypassProcessing,
            inputDeviceUID: recordingInputDeviceUID,
            inputIsBluetooth: recordingInputIsBluetooth,
            echoCancellation: echoCancellation
        )
        let sessionID = nextTranscriptionID &+ 1
        let playbackHeard = OSAllocatedUnfairLock(initialState: false)
        let audioEngineRef = audioEngine
        let smartEndpoint = smartTurnEndpointDetector
        let endpointSampleCallback: (([Float]) -> Void)? = smartEndpoint.map { endpoint in
            { samples in endpoint.feed(samples) }
        }
        let rank = recordingInputDeviceUID.flatMap { uid in inputPriorityUIDs.firstIndex(of: uid) }
        let pickedNote = rank.map { " (#\($0 + 1) in mic priority)" } ?? " (not in mic priority)"
        owLog("[OpenWhisper] Resolved recording input: \(recordingInputDeviceUID ?? "system default")\(pickedNote)")
        activeRecordingInputUID = recordingInputDeviceUID ?? AudioEngine.defaultInputDeviceUID()
        // Voice sessions continue the wake listener's running mic stream (same device only)
        // instead of restarting the hardware; after "Hey Jarvis" the audio since the wake comes
        // along, so a command said without a pause keeps its first words. Taken here, before
        // `recordingState` below stops the listener.
        let (captureHandoff, canRecord) = claimWakeCapture(
            wakeLikeSession: wakeLikeSession, trigger: recordingTrigger, deviceUID: recordingInputDeviceUID,
            echoCancellation: echoCancellation, deferredWake: deferredWake, audioEngine: audioEngineRef
        )
        guard canRecord else { return }

        launchMicCapture(
            audioEngine: audioEngineRef, deviceUID: recordingInputDeviceUID, processingMode: processingMode,
            bypassProcessing: bypassProcessing, sampleCallback: endpointSampleCallback,
            echoCancellation: echoCancellation, playbackHeard: playbackHeard, handoff: captureHandoff,
            waitsForLinkAudio: waitsForLinkAudio, sessionID: sessionID
        )

        // 2. Update recordingState so flow bar UI appears
        showRecordingStarted(sessionID: sessionID, waitsForLinkAudio: waitsForLinkAudio)

        // Save the currently focused app (instant NSWorkspace query)
        targetApp = NSWorkspace.shared.frontmostApplication
        owLog("[OpenWhisper] Target app: \(targetApp?.localizedName ?? "unknown")")
        AppFocus.current = AppFocus(app: targetApp, entries: SoundAlikeCorrector.loadEntries())

        // 3. Create session immediately with non-blocking initial context (AX details captured in background)
        nextTranscriptionID &+= 1
        let initialContext = PasteContext.initial(targetApp: targetApp)
        let session = RecordingTranscriptionSession(
            id: nextTranscriptionID,
            targetApp: targetApp,
            // Runs on the raw mic too: on 30 raw external-mic recordings (29 Oct 2026) the profile
            // scored the same as on their DeepFilter copies (median 0.58 vs 0.58).
            targetSpeakerEnabled: targetSpeakerFiltersTranscription && sessionProfile != nil,
            targetSpeakerProfile: sessionProfile,
            pasteContext: initialContext
        )
        captureDestination(for: session, sessionID: sessionID)
        configure(
            session, bypassProcessing: bypassProcessing, armVoiceAutoStop: armVoiceAutoStop, trigger: recordingTrigger,
            mic: recordingMic, pausesMedia: pausesMedia, claudeMessage: claudeMessage, commandFollowUp: commandFollowUp,
            overReply: overReply, echoCancellation: echoCancellation, playbackHeard: playbackHeard
        )
        activeTranscriptionSession = session
        pendingTranscriptionCount += 1

        startTranscriptionQueue(for: session)

        // 4. Start duration timer
        startRecordingTimer()

        // Dictation snapshot reset (instant if no active snapshot)
        DictationSnapshot.shared.handleNewDictationStarting()
    }

    /// False when the key press was used up by voice-profile enrollment.
    private func prepareForNewRecording() -> Bool {
        // A new command cuts Jarvis off, and his voice must not end up in the recording. Not a
        // command follow-up opened over his reply: it listens while he finishes.
        if !(hotkey?.trigger == .followUp && commandFollowUpOverReply) { JarvisVoice.shared.stop() }

        if targetSpeakerEnrollmentActive {
            if targetSpeakerEnrollmentIsRecording {
                stopTargetSpeakerEnrollmentRecording()
            } else {
                startTargetSpeakerEnrollmentRecording()
            }
            return false
        }
        // Cancel any pending tail-stop work item and finish previous recording if a new recording starts immediately
        if delayedStopWorkItem != nil {
            delayedStopWorkItem?.cancel()
            delayedStopWorkItem = nil
            stopRecording()
        }
        return true
    }

    private func decideProcessingMode(
        bypassProcessing: Bool,
        inputDeviceUID recordingInputDeviceUID: String?,
        inputIsBluetooth recordingInputIsBluetooth: Bool,
        echoCancellation: Bool
    ) -> AudioProcessingMode {
        // Decided once here for the whole recording, never switched while it runs.
        if bypassProcessing {
            activeDeepFilterDecision = DeepFilterDecision(enabled: false, reason: "unprocessed")
            return .off
        }
        return decideDeepFilter(
            inputDeviceUID: recordingInputDeviceUID,
            inputIsBluetooth: recordingInputIsBluetooth,
            echoCancellation: echoCancellation
        ) ? .deepFilterNet : .off
    }

    private func claimWakeCapture(
        wakeLikeSession: Bool,
        trigger recordingTrigger: RecordingTrigger,
        deviceUID recordingInputDeviceUID: String?,
        echoCancellation: Bool,
        deferredWake: PendingWhisperWake?,
        audioEngine audioEngineRef: AudioEngine?
    ) -> (handoff: WakeCaptureHandoff?, canRecord: Bool) {
        let captureHandoff: WakeCaptureHandoff? = wakeLikeSession
            ? wakeWordListener?.handOffCapture(
                toDeviceID: recordingInputDeviceUID.flatMap(AudioEngine.audioDeviceID(forUID:)) ?? AudioEngine.defaultInputDeviceID(),
                wakePreroll: recordingTrigger == .wakeWord,
                echo: echoCancellation)
            : nil
        if let deferredWake {
            guard captureHandoff != nil, audioEngineRef != nil else {
                captureHandoff?.capture.stop()
                captureHandoff?.echo?.release()
                cancelPendingWhisperWake(reason: "buffered microphone unavailable", falseWake: true)
                hotkey?.externalCancelHandsFree()
                return (nil, false)
            }
            consumePendingWhisperWake(deferredWake)
        }
        if audioEngineRef == nil {
            captureHandoff?.capture.stop()
            captureHandoff?.echo?.release()
        }
        return (captureHandoff, true)
    }

    private func launchMicCapture(
        audioEngine audioEngineRef: AudioEngine?,
        deviceUID recordingInputDeviceUID: String?,
        processingMode: AudioProcessingMode,
        bypassProcessing: Bool,
        sampleCallback endpointSampleCallback: (([Float]) -> Void)?,
        echoCancellation: Bool,
        playbackHeard: OSAllocatedUnfairLock<Bool>,
        handoff captureHandoff: WakeCaptureHandoff?,
        waitsForLinkAudio: Bool,
        sessionID: UInt64
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let didFallBackFromDeepFilter = audioEngineRef?.startRecording(
                deviceUID: recordingInputDeviceUID,
                audioProcessingMode: processingMode,
                bypassAudioProcessing: bypassProcessing,
                sampleCallback: endpointSampleCallback,
                echoCancellation: echoCancellation,
                playbackHeard: playbackHeard,
                handoff: captureHandoff,
                waitsForLinkAudio: waitsForLinkAudio,
                onInputReady: { DispatchQueue.main.async { self?.markRecordingInputReady(sessionID: sessionID) } },
                levelCallback: { rawLevel in
                    let target = AudioSignalProcessor.displayLevel(forRawRMS: rawLevel)
                    // Stamped here, on the audio thread, so main-thread stalls can't distort
                    // the voice auto-stop's silence timing.
                    let levelTime = CACurrentMediaTime()
                    Task { @MainActor in
                        guard let self else { return }
                        self.audioLevel = target
                        self.feedVoiceEndpoint(rawRMS: rawLevel, at: levelTime)
                    }
                }
            ) ?? false

            // Non-blocking: this recording is already under way by the time this lands, so it
            // can never delay the Fn->audio path -- it only informs the user after the fact.
            if didFallBackFromDeepFilter {
                Task { @MainActor in
                    if self?.nextTranscriptionID == sessionID {
                        self?.activeDeepFilterDecision = DeepFilterDecision(enabled: false, reason: "model unavailable")
                    }
                    self?.showFlowBarMessage(L("Gürültü engelleme henüz hazır değildi, bu kayıt engelsiz işlendi", "Noise cancelling wasn't ready yet, this recording was processed without it"))
                }
            }
        }
    }

    private func showRecordingStarted(sessionID: UInt64, waitsForLinkAudio: Bool) {
        recordingInputReady = !waitsForLinkAudio
        if waitsForLinkAudio {
            // A link that never delivers audio must not leave the bar on "connecting".
            DispatchQueue.main.asyncAfter(deadline: .now() + AudioEngine.linkAudioWaitLimit + 0.5) { [weak self] in
                guard let self, !self.recordingInputReady, self.nextTranscriptionID == sessionID else { return }
                owLog("[AudioEngine] Bluetooth mic sent no audio; showing the recording as live anyway")
                self.markRecordingInputReady(sessionID: sessionID)
            }
        }
        caretPenRect = nil
        caretFieldRect = nil
        caretPenSessionID = sessionID
        caretPenDuration = 0
        caretLookupPending = flowBarEnabled
        recordingState = .recording
        recordingDuration = 0
        audioLevel = 0
        lastError = nil
    }

    private func captureDestination(for session: RecordingTranscriptionSession, sessionID: UInt64) {
        // Start destination capture before the remaining microphone/UI setup.
        // Keep AX IPC off the hotkey callback thread.
        let currentTargetApp = targetApp
        Task.detached(priority: .userInitiated) { [weak self, weak session] in
            let capturedContext = PasteContext.capture(targetApp: currentTargetApp)
            let caret = capturedContext.focusStatus != .notEditable
                ? capturedContext.focusedElement.flatMap(AXTextAccess.caretRect) : nil
            let field = capturedContext.focusedElement.flatMap(AXTextAccess.fieldRect)
            owLog("[Caret] \(capturedContext.bundleIdentifier ?? "unknown"): focus=\(capturedContext.focusStatus) element=\(capturedContext.focusedElement != nil) caret=\(caret.map { "\($0)" } ?? "nil")")
            await MainActor.run {
                guard let session else { return }
                session.pasteContext = capturedContext
                guard let self, self.caretPenSessionID == session.id,
                      self.caretLookupPending, !session.isCancelled,
                      self.recordingState != .idle else { return }
                self.caretPenRect = caret
                self.caretFieldRect = field
                self.caretLookupPending = false
                self.syncFlowBarVisibility()
            }
        }
        // An unresponsive AX app must not hide recording feedback indefinitely. Once the
        // fallback is visible, keep it there for this session even if the lookup returns late.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.caretPenSessionID == sessionID, self.caretLookupPending else { return }
            self.caretLookupPending = false
            self.syncFlowBarVisibility()
        }
    }

    private func configure(
        _ session: RecordingTranscriptionSession,
        bypassProcessing: Bool,
        armVoiceAutoStop: Bool,
        trigger recordingTrigger: RecordingTrigger,
        mic recordingMic: TargetSpeakerMic,
        pausesMedia: Bool,
        claudeMessage: Bool,
        commandFollowUp: CommandFollowUp.Domain??,
        overReply: Bool,
        echoCancellation: Bool,
        playbackHeard: OSAllocatedUnfairLock<Bool>
    ) {
        session.bypassAudioProcessing = bypassProcessing
        session.previewEndpointDetector = smartTurnEndpointDetector
        owLog("[AudioProcessing] session=\(session.id) unprocessed=\(bypassProcessing)")
        session.isVoiceCommand = armVoiceAutoStop
        session.trigger = recordingTrigger
        session.mediaWasPlaying = mediaPlaying
        session.targetSpeakerMic = recordingMic
        if recordingMic != .mac && pausesMedia {
            let media = recordingMedia
            session.playbackSurvivedPause = { media.playbackLeftRunning }
        }
        session.sendsToRecappedSession = claudeMessage ? pendingRecapAgent : nil
        if let commandFollowUp {
            session.followsCommand = true
            session.commandFollowUpDomain = commandFollowUp
            if overReply { session.precedingReply = lastSpokenReply }
        }
        session.echoCancelled = echoCancellation
        session.playbackHeard = playbackHeard
        // A key press means the user is at the Mac: treat the voice like a matched "Jarvis".
        session.wakeSpeakerVerified = session.trigger == .jarvisKey
            || ([.wakeWord, .followUp].contains(session.trigger) && pendingWakeSpeakerVerified)
        pendingWakeSpeakerVerified = false
        if session.trigger == .wakeWord {
            session.wakeClipID = pendingWakeClipID
            pendingWakeClipID = nil
        }
    }

    /// Sets up the voice auto-stop for a new recording: the level detector, and Smart Turn
    /// for wake-like sessions.
    private func armEndpointDetectors(
        sessionStart: TimeInterval,
        trigger recordingTrigger: RecordingTrigger,
        armVoiceAutoStop: Bool,
        wakeLikeSession: Bool,
        deferredWake: Bool,
        followsCommand: Bool,
        claudeMessage: Bool,
        overReply: Bool,
        inputIsBluetooth recordingInputIsBluetooth: Bool,
        mic recordingMic: TargetSpeakerMic
    ) {
        // Smart Turn would take Jarvis's reply for the user's speech, and its clock can't be
        // moved past the reply: a follow-up over the reply uses the level detector alone.
        let useSmartTurnEndpoint = armVoiceAutoStop && wakeLikeSession && !overReply
        let isDeletionConfirmation = armVoiceAutoStop && recordingTrigger == .confirmation
        let isReplyFollowUp = armVoiceAutoStop && recordingTrigger == .followUp
        var smartTurnConfig = SmartTurnEndpointDetector.Config()
        // Jarvis's own voice tail (or its echo on the Mac speakers) must not count as an answer.
        let ignoredLeadingSeconds: TimeInterval = deferredWake ? 0 : mediaPlaying ? 0.8 : isReplyFollowUp ? Self.replyFollowUpEchoGuard : 0
        recordingIgnoredLeadingSeconds = ignoredLeadingSeconds
        var endpointFallbackConfig: VoiceEndpointDetector.Config = recordingInputIsBluetooth ? .closeTalk : .init()
        // Smart Turn normally answers at the first real endpoint. Two seconds matches its longest
        // silence wait and also keeps a model failure bounded.
        if useSmartTurnEndpoint { endpointFallbackConfig.silenceToStop = 2 }
        if isDeletionConfirmation {
            // Jarvis has just finished asking for confirmation: wait up to five seconds for
            // speech, then close automatically. Once speech begins, leave enough room for a
            // natural answer and stop quickly after it ends.
            endpointFallbackConfig.noSpeechTimeout = 5
            endpointFallbackConfig.maxDuration = 10
            endpointFallbackConfig.silenceToStop = min(endpointFallbackConfig.silenceToStop, 0.8)
            owLog("[Reminders] Listening for deletion confirmation (5 s response window)")
        }
        if isReplyFollowUp {
            // Jarvis has just asked something back (or run a command the user may want to
            // fix): no speech within the window closes the mic quietly. Both detectors need
            // it — while Smart Turn is ready, it alone decides.
            let window = followsCommand ? (screenModeActive ? screenModeWindow : Self.commandFollowUpWindow)
                : claudeMessage ? Self.claudeMessageWindow : Self.replyFollowUpWindow
            endpointFallbackConfig.noSpeechTimeout = window
            smartTurnConfig.noSpeechTimeout = window
            if followsCommand {
                // A fix is a few words; vocals of the song just started must not keep it open.
                // Screen mode: "… yaz ve gönder" carries a whole message.
                let maxDuration = screenModeActive ? ScreenMode.maxDuration : Self.commandFollowUpMaxDuration
                endpointFallbackConfig.maxDuration = maxDuration
                smartTurnConfig.maxDuration = maxDuration
            }
            if overReply {
                // Jarvis is still speaking: nothing counts until `commandFollowUpReplyEnded`
                // starts the window. These only bound a reply that never reports its end.
                endpointFallbackConfig.noSpeechTimeout = 60
                endpointFallbackConfig.maxDuration = 90
            }
            owLog(String(format: "[FollowUp] Listening for %@ (%.1f s window)",
                         followsCommand ? "a fix to the command" : claudeMessage ? "the Claude message" : "an answer", window))
        }
        voiceEndpointDetector = armVoiceAutoStop
            ? VoiceEndpointDetector(
                startTime: sessionStart,
                config: endpointFallbackConfig,
                ignoreUntil: overReply ? sessionStart + 60
                    : ignoredLeadingSeconds > 0 ? sessionStart + ignoredLeadingSeconds : nil
            )
            : nil
        // An external mic over a video: only sound near the mic counts as speech. The endpoint
        // samples carry the input gain unless the audio is unprocessed.
        let farSoundFloorDB: Float? = recordingMic == .external && mediaPlaying
            ? -40 + (bypassAudioProcessing ? 0 : 20 * log10(AudioSignalProcessor.inputGain))
            : nil
        smartTurnEndpointDetector = useSmartTurnEndpoint
            ? SmartTurnEndpointDetector(
                startTime: sessionStart,
                config: smartTurnConfig,
                ignoredLeadingSeconds: ignoredLeadingSeconds,
                farSoundFloorDB: farSoundFloorDB
            )
            : nil
        if let farSoundFloorDB {
            owLog(String(format: "[SmartTurn] External mic over media: sound under %.0f dBFS counts as silence", farSoundFloorDB))
        }
    }

    /// Arms the gate that ends a voice session once someone else is talking.
    private func armOwnVoiceStopGate(
        sessionStart: TimeInterval,
        mic recordingMic: TargetSpeakerMic,
        profile sessionProfile: TargetSpeakerProfile?,
        armVoiceAutoStop: Bool,
        wakeLikeSession: Bool,
        overReply: Bool
    ) {
        // Over a video or song only the user's voice keeps the session open, filter on or off:
        // the speakers' residual after echo cancellation keeps Silero hearing "speech" forever.
        // Not for buds (the music is paused, and their mic isn't the enrolled one) or over
        // Jarvis's reply (the window waits for it to end).
        // An external mic: media pauses at once, and a YouTube video it leaves playing stays
        // under `farSoundFloorDB`.
        let watchesPlayback = mediaPlaying && recordingMic == .mac && !overReply
        // The gate scores against the session mic's profile every 0.5 s and cuts the session after
        // ~2 s of "someone else". Scoring only, so the raw mic runs it too. On an external mic it
        // only logs until its profile is checked in noise; the buds' call-mode mic is left out.
        ownVoiceStopGate = armVoiceAutoStop && wakeLikeSession && [.mac, .external].contains(recordingMic)
            && (targetSpeakerEnabled || watchesPlayback) && sessionProfile != nil
            && !VoiceTestInjector.shared.bypassesSpeakerChecks
            ? OwnVoiceStopGate(startTime: sessionStart, watchesPlayback: watchesPlayback)
            : nil
        ownVoiceCheckInFlight = false
        lastOwnVoiceCheck = sessionStart
        ownVoiceProfile = sessionProfile
        ownVoiceGateLogsOnly = recordingMic != .mac
        if ownVoiceStopGate != nil {
            owLog("[OwnVoiceStop] Armed for wake-word session" + (watchesPlayback ? " (media playing: only your voice keeps it open)" : "")
                  + (ownVoiceGateLogsOnly ? " (\(recordingMic) mic: log only)" : ""))
        }
    }

    /// Pauses media for the recording (or holds the pause while a wake over media is on
    /// probation). Returns whether the media pause applies to this recording.
    private func pauseMediaForRecording(
        sessionStart: TimeInterval,
        trigger recordingTrigger: RecordingTrigger,
        mic recordingMic: TargetSpeakerMic,
        profile sessionProfile: TargetSpeakerProfile?,
        followsCommand: Bool
    ) -> Bool {
        // The Settings switch decides for every trigger, voice sessions included. Buds are the
        // exception: their mic hears the music played into the ear (measured 16 Oct 2026: SNR
        // −2 dB under Spotify, transcribed as Icelandic), so it pauses at once whatever the switch.
        // So does an external mic, which Mac playback must not reach either.
        // Not after a command: the user is judging the song or video it just started. Screen
        // mode does: its steps type and press, and playback must never reach them.
        // A spoken "Jarvis" (often a false wake over the video) never pauses YouTube.
        let pausesMedia = (!followsCommand || screenModeActive) && (audioDuckingEnabled || (recordingMic != .mac && mediaPlaying))
        // A "Jarvis" over media whose voice hasn't matched yet pauses nothing until it does.
        let probationProfile = pausesMedia && recordingTrigger == .wakeWord && mediaPlaying
            && !pendingWakeSpeakerVerified && targetSpeakerGuardsWakeWord
            && !VoiceTestInjector.shared.bypassesSpeakerChecks ? sessionProfile : nil
        wakeProbation = probationProfile.map { WakeProbation(startTime: sessionStart, profile: $0) }
        // Scoring only, the audio is left alone: runs on the raw mic too.
        lateWakeVoiceProfile = recordingTrigger == .wakeWord && !pendingWakeSpeakerVerified && targetSpeakerGuardsWakeWord
            && !VoiceTestInjector.shared.bypassesSpeakerChecks ? sessionProfile : nil
        lateWakeVoiceCheckInFlight = false
        lastLateWakeVoiceCheck = sessionStart
        lateWakeVoiceMatches = 0
        wakeProbationCheckInFlight = false
        lastWakeProbationCheck = sessionStart
        if wakeProbation != nil {
            owLog(String(format: "[WakeProbation] Media playing and the voice not matched yet: nothing paused, %.0f s for your voice", WakeProbation.window))
        }
        // A hidden session leaves the Mac's playback alone until it is shown. Buds and external
        // mics still pause at once: their recording can't have the music in it.
        hiddenWakeMediaHold = nil
        if pausesMedia && wakeSessionHidden && recordingMic == .mac {
            hiddenWakeMediaHold = wakeProbation != nil
        } else if pausesMedia {
            recordingMedia.begin(immediately: recordingMic != .mac, sparingYouTube: recordingTrigger == .wakeWord,
                                 holdingPause: wakeProbation != nil)
        }
        return pausesMedia
    }

    /// Queues the session behind the previous one and transcribes its batches as they arrive.
    private func startTranscriptionQueue(for session: RecordingTranscriptionSession) {
        let previousTask = transcriptionQueueTail
        let transcriptionTask = Task { @MainActor [weak self] in
            let queueStartedAt = session.latency.timestamp()
            if let previousTask {
                await previousTask.value
            }
            session.latency.record(.queueWait, since: queueStartedAt)

            guard let self else { return }
            for await segment in session.stream {
                if Task.isCancelled || session.isCancelled { break }
                if !session.historySaveFailed {
                    do {
                        try await self.recordingHistoryStore.append(segment, sessionID: session.id, startedAt: session.startedAt)
                    } catch {
                        session.historySaveFailed = true
                        owLog("[RecordingHistory] Save failed: \(error)")
                        self.lastError = String(format: loc("Ses geçmişi kaydedilemedi: %@"), error.localizedDescription)
                    }
                }
                await self.transcribeStreamingSegment(segment, session: session)
            }
            await self.finishTranscription(session)
        }
        session.task = transcriptionTask
        transcriptionQueueTail = transcriptionTask
        transcriptionQueueTailID = session.id
    }

    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingState == .recording else { return }
                self.recordingDuration += 0.25
                self.enqueueCompletedAudioSegments()
                self.checkOwnVoiceEndpoint()
                self.checkWakeProbation()
                self.checkLateWakeVoice()
                self.checkSpokenDoneEndpoint()
                self.checkCommandOverReply()
                self.updateFollowUpLiveText()
            }
        }
    }

    /// Schedules stopRecording() after a short tail delay (default 0.40s / 400ms) so that speech spoken
    /// right as the hotkey/Fn key is released is not truncated from the audio buffer. Visually,
    /// the UI transitions to `.transcribing` immediately on key release so the user feels an instant response.
    func stopRecordingWithTail(delay requestedDelay: TimeInterval = 0.40) {
        guard recordingState == .recording else { return }
        // Speech that ended before the release has nothing left to catch; a short tail still
        // covers audio in flight (Bluetooth) and a quiet last consonant the level missed.
        var delay = requestedDelay
        if let speechTime = activeTranscriptionSession?.doneLastSpeechTime, speechTime > 0,
           CACurrentMediaTime() - speechTime >= 0.30 {
            delay = min(delay, 0.15)
        }
        voiceEndpointDetector = nil
        smartTurnEndpointDetector = nil
        ownVoiceStopGate = nil
        wakeProbation = nil
        delayedStopWorkItem?.cancel()
        recordingState = .transcribing
        owLog("[OpenWhisper] Hotkey released; UI transitioned to transcribing, keeping mic open for \(Int(delay * 1000))ms tail buffer...")
        let workItem = DispatchWorkItem { [weak self] in
            self?.stopRecording()
        }
        delayedStopWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func stopRecording() {
        delayedStopWorkItem?.cancel()
        delayedStopWorkItem = nil
        voiceEndpointDetector = nil
        smartTurnEndpointDetector = nil
        ownVoiceStopGate = nil
        wakeProbation = nil

        if targetSpeakerEnrollmentIsRecording {
            stopTargetSpeakerEnrollmentRecording()
            return
        }
        guard recordingState == .recording || (recordingState == .transcribing && activeTranscriptionSession != nil) else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        guard let audioEngine, let session = activeTranscriptionSession else {
            recordingMedia.end()
            owLog("[OpenWhisper] No audio engine")
            recordingState = pendingTranscriptionCount > 0 ? .transcribing : .idle
            return
        }
        let segments = audioEngine.stopRecording()
        if session.queuedSampleCount == 0, segments.count == 1,
           let segment = segments.first, segment.overlapSampleCount == 0 {
            session.previewEndpointDetector?.finishForPreview(with: segment.samples)
        }
        noteRecordingNoiseFloor(audioEngine)
        session.latency.markRecordingStopped()
        session.stoppedAt = CACurrentMediaTime()
        // A voice command keeps media paused until it has run (see finishTranscription).
        if !session.isVoiceCommand {
            recordingMedia.end()
        } else {
            prefetchJarvisContext()
        }

        // Batches already drained during recording are queued before the final tail returned by
        // stopRecording(), so the per-session stream preserves the original recording order.
        for segment in segments {
            enqueueAudioSegment(segment, for: session)
        }
        session.continuation.finish()
        activeTranscriptionSession = nil

        // If total audio duration is under 0.4 seconds (6400 samples at 16kHz),
        // skip entering the .transcribing state completely and return to idle.
        if session.queuedSampleCount < 6400 {
            owLog("[OpenWhisper] Audio too short (\(session.queuedSampleCount) samples < 0.4s); skipping transcribing UI")
            session.isCancelled = true
            recordingState = pendingTranscriptionCount > 1 ? .transcribing : .idle
            return
        }

        recordingState = .transcribing
        owLog("[OpenWhisper] Finishing recording; waiting for background batches...")
    }

    func enqueueCompletedAudioSegments() {
        guard let audioEngine, let session = activeTranscriptionSession else { return }
        for segment in audioEngine.takeCompletedSegments() {
            enqueueAudioSegment(segment, for: session)
        }
    }

    func enqueueAudioSegment(_ segment: CompletedAudioSegment, for session: RecordingTranscriptionSession) {
        session.enqueue(segment)
    }

    func transcribeStreamingSegment(
        _ segment: CompletedAudioSegment,
        session: RecordingTranscriptionSession
    ) async {
        await AudioSignalProcessor.$bypassProcessing.withValue(session.bypassAudioProcessing) {
            await transcribeStreamingSegmentWithSessionSettings(segment, session: session)
        }
    }

    private func transcribeStreamingSegmentWithSessionSettings(
        _ segment: CompletedAudioSegment,
        session: RecordingTranscriptionSession
    ) async {
        guard !session.isCancelled else { return }
        lastWhisperActivity = Date()
        let transcriptionStartedAt = session.latency.timestamp()
        defer { session.latency.record(.transcription, since: transcriptionStartedAt) }
        session.nextSegmentNumber += 1
        let segmentNumber = session.nextSegmentNumber

        if whisperSuspendedForIdle {
            await resumeIdleWhisperIfNeeded()
            guard !session.isCancelled, modelLoaded else {
                session.isCancelled = true
                lastError = "Konuşma modeli yüklenemedi. Kaydı yeniden deneyin."
                return
            }
        }
        guard !session.isCancelled else { return }
        guard let transcriber = activeTranscriptionService else {
            owLog("[OpenWhisper] No transcriber for background batch \(segmentNumber)")
            return
        }

        // The batch's entry in `session.speakerBatches`; written to /tmp/openwhisper.log on every exit.
        let (filtered, speakerLogIndex) = await filterTargetSpeaker(segment, segmentNumber: segmentNumber, session: session)
        func noteSpeakers(_ update: (inout SpeakerBatchLog) -> Void) {
            noteSpeakerBatch(session, at: speakerLogIndex, update)
        }
        defer {
            if let speakerLogIndex {
                owLog("[Speakers] " + session.speakerBatches[speakerLogIndex].lines.joined(separator: " /"))
            }
        }

        let gate = gateDecision(for: filtered, session: session)
        let isFailClosedPassthrough = gate.isFailClosedPassthrough
        let isBelowThresholdRejection = gate.isBelowThresholdRejection
        let shouldUseDiarization = gate.shouldUseDiarization

        guard await admitBatch(
            segment, filtered: filtered, gate: gate, segmentNumber: segmentNumber, session: session,
            transcriber: transcriber, speakerLogIndex: speakerLogIndex
        ) else { return }

        do {
            let segmentText: String
            if shouldUseDiarization {
                guard let diarizedText = try await transcribeDiarized(
                    segment, filtered: filtered, segmentNumber: segmentNumber, session: session,
                    transcriber: transcriber, isAmbiguousTargetMatch: gate.isAmbiguousTargetMatch,
                    speakerLogIndex: speakerLogIndex
                ) else { return }
                segmentText = diarizedText
            } else {
                segmentText = try await transcribeMasked(
                    segment, filtered: filtered, segmentNumber: segmentNumber, session: session,
                    transcriber: transcriber, useOriginalAudio: isFailClosedPassthrough || isBelowThresholdRejection
                )
            }
            guard !session.isCancelled else { return }
            owLog("[OpenWhisper] Batch \(segmentNumber) overlap=\(segment.overlapSampleCount) samples text=\(segmentText)")
            guard !segmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            session.allSegmentTexts.append(segmentText)
            noteBatchText(segmentText, gate: gate, session: session, speakerLogIndex: speakerLogIndex)
            if isBelowThresholdRejection {
                session.unmatchedSegmentTexts.append(segmentText)
            } else {
                session.segmentTexts.append(segmentText)
            }
        } catch {
            guard !session.isCancelled else { return }
            owLog("[OpenWhisper] Background batch \(segmentNumber) failed: \(error)")
            noteSpeakers { $0.notes.append("Whisper failed: \(error)") }
            lastError = error.localizedDescription
        }
    }

    // Three distinct outcomes once the target-speaker gate is in play -- kept as separate
    // booleans (rather than folded into one branch) so the fail-closed path and the
    // below-threshold path can never accidentally share behavior:
    //   1. wasFailClosed: the gate itself errored (nil/incompatible profile, model
    //      preparation/embedding failure). It made no decision at all, so a transient
    //      failure must not cost the user their dictation -- treat exactly like the
    //      feature-disabled path below.
    //   2. below-threshold rejection: the gate ran fine and decided this isn't the target
    //      speaker. Still transcribe (unless there was no voice at all) so the text can be
    //      salvaged onto the clipboard, but keep it out of `segmentTexts` -- it must never
    //      reach the normal paste/post-processing path.
    //   3. accepted (or feature disabled): existing normal path.
    private func gateDecision(
        for filtered: TargetSpeakerFilterResult,
        session: RecordingTranscriptionSession
    ) -> BatchGate {
        let isFailClosedPassthrough = session.targetSpeakerEnabled && filtered.wasFailClosed
        let isAmbiguousTargetMatch = session.targetSpeakerEnabled
            && !filtered.wasFailClosed
            && filtered.decision == .ambiguous
        let isSingleSpeakerUncertain = session.targetSpeakerEnabled
            && !filtered.wasFailClosed
            && filtered.decision == .singleSpeakerUncertain
        let canUseDiarizationDecision: Bool
        switch filtered.decision {
        case .accepted, .partial, .ambiguous:
            canUseDiarizationDecision = true
        default:
            canUseDiarizationDecision = false
        }
        // A short-bypass batch had no run long enough to score, so diarization cannot name the
        // speaker either (60 of 61 failed, 14–15 Oct 2026) and its fallback decoded the masked
        // audio a second time. Go straight to that masked decode: same text, ~0.7 s sooner.
        // Confirmations keep the timed decode, whose full text they use as a heard variant.
        let skipsUnscorableDiarization = filtered.shortBypass && session.trigger != .confirmation
        // A screen-mode step is a few words: diarization failed to name the speaker on 7 of 13
        // (1 Nov 2026) and then decoded again, ~1.3 s after the mic stopped. With nothing
        // playing, the gate's masked audio is enough. Ambiguous batches have no accepted
        // samples and still need diarization.
        let skipsScreenStepDiarization = screenModeActive && session.followsCommand
            && !session.speakersPlayed && filtered.decision != .ambiguous
        let shouldUseDiarization = session.targetSpeakerEnabled
            && !filtered.wasFailClosed
            && targetSpeakerDiarizationReady
            && filtered.hadVoiceActivity
            && canUseDiarizationDecision
            && !skipsUnscorableDiarization
            && !skipsScreenStepDiarization
        if session.targetSpeakerEnabled && filtered.decision == .partial {
            session.hadPartialTargetSpeech = true
        }
        let isBelowThresholdRejection = session.targetSpeakerEnabled
            && !filtered.wasFailClosed
            && (filtered.decision == .rejected || filtered.decision == .noVoice)
        return BatchGate(
            isFailClosedPassthrough: isFailClosedPassthrough, isAmbiguousTargetMatch: isAmbiguousTargetMatch,
            isSingleSpeakerUncertain: isSingleSpeakerUncertain, isBelowThresholdRejection: isBelowThresholdRejection,
            shouldUseDiarization: shouldUseDiarization, skipsScreenStepDiarization: skipsScreenStepDiarization
        )
    }

    /// False when the batch ends here and is not transcribed by the normal path.
    private func admitBatch(
        _ segment: CompletedAudioSegment,
        filtered: TargetSpeakerFilterResult,
        gate: BatchGate,
        segmentNumber: Int,
        session: RecordingTranscriptionSession,
        transcriber: WhisperTranscriptionService,
        speakerLogIndex: Int?
    ) async -> Bool {
        let (isAmbiguousTargetMatch, shouldUseDiarization) = (gate.isAmbiguousTargetMatch, gate.shouldUseDiarization)
        let (isSingleSpeakerUncertain, isBelowThresholdRejection) = (gate.isSingleSpeakerUncertain, gate.isBelowThresholdRejection)
        let isFailClosedPassthrough = gate.isFailClosedPassthrough
        if isAmbiguousTargetMatch {
            session.hadAmbiguousTargetSpeech = true
            guard filtered.hadVoiceActivity else {
                owLog("[OpenWhisper] Batch \(segmentNumber) has no voice activity; Whisper skipped")
                noteSpeakerBatch(session, at: speakerLogIndex) { $0.notes.append("no voice activity, Whisper skipped") }
                return false
            }
            guard shouldUseDiarization else {
                owLog("[OpenWhisper] Batch \(segmentNumber) ambiguous speech withheld because diarization is not ready")
                noteSpeakerBatch(session, at: speakerLogIndex) { $0.notes.append("ambiguous speech withheld, not transcribed (diarization not ready)") }
                return false
            }
            owLog("[OpenWhisper] Batch \(segmentNumber) has unresolved target-speaker ambiguity; trying timed overlap filtering")
        } else if isSingleSpeakerUncertain {
            session.hadSingleSpeakerUncertain = true
            await holdSingleSpeakerCandidate(
                segment, filtered: filtered, segmentNumber: segmentNumber, session: session,
                transcriber: transcriber, speakerLogIndex: speakerLogIndex
            )
            return false
        } else if isBelowThresholdRejection {
            guard await keepRejectedBatchForSalvage(
                segment, filtered: filtered, segmentNumber: segmentNumber, session: session,
                transcriber: transcriber, speakerLogIndex: speakerLogIndex
            ) else { return false }
        } else if isFailClosedPassthrough {
            owLog("[OpenWhisper] Batch \(segmentNumber) target-speaker gate failed closed; transcribing as normal dictation")
        }
        return true
    }

    private func noteBatchText(
        _ segmentText: String,
        gate: BatchGate,
        session: RecordingTranscriptionSession,
        speakerLogIndex: Int?
    ) {
        let (isBelowThresholdRejection, isFailClosedPassthrough) = (gate.isBelowThresholdRejection, gate.isFailClosedPassthrough)
        let (skipsScreenStepDiarization, shouldUseDiarization) = (gate.skipsScreenStepDiarization, gate.shouldUseDiarization)
        let trimmedSegmentText = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        noteSpeakerBatch(session, at: speakerLogIndex) { entry in
            if isBelowThresholdRejection {
                entry.othersText = trimmedSegmentText
            } else {
                entry.ownText = trimmedSegmentText
                if isFailClosedPassthrough {
                    entry.notes.append("filter error — whole text kept as normal dictation, not split")
                } else if skipsScreenStepDiarization && entry.levels.others.seconds >= 0.3 {
                    entry.notes.append("other voices masked out, their words not transcribed (screen step, diarization skipped)")
                } else if !shouldUseDiarization && entry.levels.others.seconds >= 0.3 {
                    entry.notes.append("other voices masked out, their words not transcribed (diarization not ready)")
                }
            }
        }
    }

    private func noteSpeakerBatch(
        _ session: RecordingTranscriptionSession,
        at speakerLogIndex: Int?,
        _ update: (inout SpeakerBatchLog) -> Void
    ) {
        guard let speakerLogIndex else { return }
        update(&session.speakerBatches[speakerLogIndex])
    }

    /// Runs the target-speaker gate on one batch. Returns its result and the batch's entry in
    /// `session.speakerBatches` (nil when the gate is off).
    private func filterTargetSpeaker(
        _ segment: CompletedAudioSegment,
        segmentNumber: Int,
        session: RecordingTranscriptionSession
    ) async -> (TargetSpeakerFilterResult, Int?) {
        let filtered: TargetSpeakerFilterResult
        guard session.targetSpeakerEnabled else {
            owLog("[TargetSpeaker] Batch \(segmentNumber) targetSpeakerEnabled=false, bypassing filter")
            filtered = TargetSpeakerFilterResult(
                samples: segment.samples,
                acceptedSampleCount: segment.samples.count,
                hadVoiceActivity: true,
                decision: .disabled,
                wasFailClosed: false,
                errorDescription: nil
            )
            session.acceptedTargetSpeechSamples += filtered.acceptedSampleCount
            return (filtered, nil)
        }
        owLog("[TargetSpeaker] Batch \(segmentNumber) filtering segment: samples=\(segment.samples.count), targetSpeakerEnabled=true, profileEmbeddings=\(session.targetSpeakerProfile?.embeddings.count ?? 0)")
        let result = await targetSpeakerFilter.filter(
            samples: segment.samples,
            profile: session.targetSpeakerProfile,
            enabled: true,
            overPlayback: session.speakersPlayed
        )
        // The filter's own verdict, before the wake-verified override below.
        WakeClipLog.shared.update(session.wakeClipID) {
            $0.filterDecisions.append(result.shortBypass ? "shortBypass" : "\(result.decision)")
        }
        // One coherent voice in a session whose "Jarvis" already matched the user: that
        // voice is the user. Holding it for a "Bu benim sesimdi" tap only lost commands.
        if session.wakeSpeakerVerified, result.decision == .singleSpeakerUncertain, !result.wasFailClosed {
            owLog("[TargetSpeaker] Batch \(segmentNumber) single speaker, voice already matched at the wake word — accepting")
            filtered = TargetSpeakerFilterResult(
                samples: segment.samples,
                acceptedSampleCount: segment.samples.count,
                hadVoiceActivity: result.hadVoiceActivity,
                decision: .accepted,
                wasFailClosed: false,
                errorDescription: nil,
                acceptedSampleRanges: [TargetSpeakerAcceptedRange(start: 0, end: segment.samples.count)]
            )
        } else {
            filtered = result
        }
        owLog("[TargetSpeaker] Batch \(segmentNumber) filter result: decision=\(filtered.decision), acceptedSamples=\(filtered.acceptedSampleCount)/\(segment.samples.count), hadVoice=\(filtered.hadVoiceActivity), wasFailClosed=\(filtered.wasFailClosed)")
        if filtered.wasFailClosed, let error = filtered.errorDescription {
            lastError = error
            targetSpeakerProfileStatus = "Filtre hata verdi — bu kayıt işlenmedi"
            session.hadFailClosedPassthrough = true
            owLog("[OpenWhisper] Target speaker filter failed closed: \(error)")
        }
        session.acceptedTargetSpeechSamples += filtered.acceptedSampleCount
        let ownRanges: [TargetSpeakerAcceptedRange]?
        switch filtered.decision {
        case .accepted, .partial, .rejected, .noVoice: ownRanges = filtered.wasFailClosed ? nil : filtered.acceptedSampleRanges
        default: ownRanges = nil
        }
        session.speakerBatches.append(SpeakerBatchLog(
            batch: segmentNumber,
            decision: filtered.wasFailClosed ? "filter error" : "\(filtered.decision)",
            levels: SpeakerSplitLevels.measure(samples: segment.samples, overlapSampleCount: segment.overlapSampleCount, ownRanges: ownRanges)
        ))
        return (filtered, session.speakerBatches.count - 1)
    }

    /// A single voice the profile couldn't place: transcribed only to be offered for the
    /// "Bu benim sesimdi" confirmation, never pasted.
    private func holdSingleSpeakerCandidate(
        _ segment: CompletedAudioSegment,
        filtered: TargetSpeakerFilterResult,
        segmentNumber: Int,
        session: RecordingTranscriptionSession,
        transcriber: WhisperTranscriptionService,
        speakerLogIndex: Int?
    ) async {
        func noteSpeakers(_ update: (inout SpeakerBatchLog) -> Void) {
            noteSpeakerBatch(session, at: speakerLogIndex, update)
        }
        guard let candidate = filtered.confirmationCandidate else {
            owLog("[OpenWhisper] Batch \(segmentNumber) was single-speaker uncertain without a candidate")
            noteSpeakers { $0.notes.append("single speaker, uncertain, no candidate — not transcribed") }
            return
        }
        if session.confirmationCandidate == nil {
            session.confirmationCandidate = candidate
        }
        guard filtered.hadVoiceActivity else {
            owLog("[OpenWhisper] Batch \(segmentNumber) has no voice activity; confirmation transcription skipped")
            noteSpeakers { $0.notes.append("no voice activity, Whisper skipped") }
            return
        }
        do {
            let candidateText = try await transcriber.transcribe(
                audioData: candidate.samples,
                language: language,
                overlapSampleCount: segment.overlapSampleCount
            )
            guard !session.isCancelled else { return }
            let trimmedCandidateText = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCandidateText.isEmpty,
                  !trimmedCandidateText.hasPrefix("[BLANK"),
                  !trimmedCandidateText.hasPrefix("(BLANK") else { return }
            session.confirmationTranscriptTexts.append(trimmedCandidateText)
            noteSpeakers {
                $0.uncertainText = trimmedCandidateText
                $0.notes.append("single speaker, not matched to profile — held for \"Bu benim sesimdi\" confirmation")
            }
            owLog("[OpenWhisper] Batch \(segmentNumber) retained a single-speaker confirmation candidate")
        } catch {
            owLog("[OpenWhisper] Batch \(segmentNumber) confirmation transcription failed: \(error)")
            noteSpeakers { $0.notes.append("confirmation transcription failed: \(error)") }
        }
    }

    /// A batch the gate rejected. Returns true when it should still be transcribed for
    /// clipboard salvage.
    private func keepRejectedBatchForSalvage(
        _ segment: CompletedAudioSegment,
        filtered: TargetSpeakerFilterResult,
        segmentNumber: Int,
        session: RecordingTranscriptionSession,
        transcriber: WhisperTranscriptionService,
        speakerLogIndex: Int?
    ) async -> Bool {
        func noteSpeakers(_ update: (inout SpeakerBatchLog) -> Void) {
            noteSpeakerBatch(session, at: speakerLogIndex, update)
        }
        // Retain the original (unfiltered) audio in case the *whole* recording ends up
        // rejected and needs explicit clipboard fallback. Capped here,
        // streaming-style, at `maximumEnrollmentDuration` worth of samples (keeping the most
        // recent audio) so a long multi-batch recording can't grow this without bound.
        session.belowThresholdRejectedSamples.append(contentsOf: segment.samples)
        let maxRetainedSamples = Int(
            TargetSpeakerFilterConfiguration.maximumEnrollmentDuration
                * Double(TargetSpeakerFilterConfiguration.sampleRate)
        )
        if session.belowThresholdRejectedSamples.count > maxRetainedSamples {
            session.belowThresholdRejectedSamples.removeFirst(
                session.belowThresholdRejectedSamples.count - maxRetainedSamples
            )
        }
        // --- Early rejection UI: show "Ses eşleşmedi" IMMEDIATELY ---
        // Don't wait for Whisper transcription; give the user instant feedback.
        // Transcription still continues in the background for clipboard salvage.
        if !session.earlyRejectionShown {
            session.earlyRejectionShown = true
            owLog("[TargetSpeaker] Batch \(segmentNumber) below threshold — processing for confirmation/salvage")
            if recordingState == .transcribing {
                recordingState = pendingTranscriptionCount > 1 ? .transcribing : .idle
            }
        }
        guard filtered.hadVoiceActivity else {
            owLog("[OpenWhisper] Batch \(segmentNumber) has no voice activity; Whisper skipped")
            noteSpeakers { $0.notes.append("no voice activity, Whisper skipped") }
            return false
        }
        // What the Mac plays is never transcribed, shown or offered as "Bu benim sesimdi".
        guard !session.speakersPlayed else {
            // A called "Jarvis" (the speakers didn't say it, and Whisper confirmed a weak
            // one): look for the user's command in the words. Nothing else is taken from it.
            if session.trigger == .wakeWord, !session.wakeUnconfirmed {
                do {
                    let heard = try await transcriber.transcribe(
                        audioData: segment.samples,
                        language: language,
                        overlapSampleCount: segment.overlapSampleCount
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !session.isCancelled else { return false }
                    if !heard.isEmpty, !heard.hasPrefix("[BLANK"), !heard.hasPrefix("(BLANK") {
                        session.playbackCommandTexts.append(heard)
                    }
                    owLog("[OpenWhisper] Batch \(segmentNumber) rejected while media played; transcribed for a command only: '\(heard)'")
                    noteSpeakers { $0.notes.append("rejected while media played, transcribed for a command only") }
                } catch {
                    owLog("[OpenWhisper] Batch \(segmentNumber) command transcription over media failed: \(error)")
                }
                return false
            }
            owLog("[OpenWhisper] Batch \(segmentNumber) rejected while media played; Whisper skipped (speaker audio is never salvaged)")
            noteSpeakers { $0.notes.append("rejected while media played, Whisper skipped") }
            return false
        }
        owLog("[OpenWhisper] Batch \(segmentNumber) below target-speaker threshold; transcribing for clipboard salvage only")
        return true
    }

    /// Word-level decode that keeps only the target speaker's words. Returns nil when the
    /// batch has nothing safe to keep.
    private func transcribeDiarized(
        _ segment: CompletedAudioSegment,
        filtered: TargetSpeakerFilterResult,
        segmentNumber: Int,
        session: RecordingTranscriptionSession,
        transcriber: WhisperTranscriptionService,
        isAmbiguousTargetMatch: Bool,
        speakerLogIndex: Int?
    ) async throws -> String? {
        func noteSpeakers(_ update: (inout SpeakerBatchLog) -> Void) {
            noteSpeakerBatch(session, at: speakerLogIndex, update)
        }
        var timedTranscription: TimedTranscriptionResult?
        // The speaker half of diarization needs only the audio: run it during the decode.
        // On a 23 s dictation the two took 1.5 s and 1.4 s one after the other.
        let diarization = targetSpeakerDiarization
        let speakerAnalysis = session.targetSpeakerProfile.map { profile in
            Task {
                try await diarization.analyzeSpeakers(
                    audioData: segment.samples,
                    profile: profile
                )
            }
        }
        defer { speakerAnalysis?.cancel() }
        do {
            let timed = try await transcriber.transcribeTimed(
                audioData: segment.samples,
                language: language,
                overlapSampleCount: segment.overlapSampleCount
            )
            timedTranscription = timed
            guard let profile = session.targetSpeakerProfile else {
                throw TargetSpeakerDiarizationError.incompatibleProfile(
                    expected: FluidAudioTargetSpeakerDiarizationService.modelIdentifier,
                    actual: "missing"
                )
            }
            session.hadDiarizationAttempt = true
            let diarized = try await targetSpeakerDiarization.diarizeAndFilter(
                audioData: segment.samples,
                transcription: timed,
                profile: profile,
                segmentAcceptedRanges: filtered.acceptedSampleRanges,
                analysis: try await speakerAnalysis?.value
            )
            let diarizedText = diarized.text.trimmingCharacters(in: .whitespacesAndNewlines)
            noteSpeakers {
                let others = TargetSpeakerDiarizationResult.render(words: diarized.rejectedWords)
                let uncertain = TargetSpeakerDiarizationResult.render(words: diarized.uncertainWords)
                $0.othersText = others.isEmpty ? nil : others
                $0.uncertainText = uncertain.isEmpty ? nil : uncertain
                $0.notes.append("word-level diarization: own \(diarized.acceptedWordCount), others \(diarized.rejectedWordCount), uncertain \(diarized.uncertainWordCount) words, overlap=\(diarized.hadOverlap)")
            }
            if diarized.acceptedWordCount > 0,
               !diarizedText.isEmpty,
               !diarizedText.hasPrefix("[BLANK"),
               !diarizedText.hasPrefix("(BLANK") {
                session.hadDiarizationTargetSpeech = true
                session.hadDiarizedOverlap = session.hadDiarizedOverlap || diarized.hadOverlap
                owLog("[OpenWhisper] Batch \(segmentNumber) diarized target words=\(diarized.acceptedWordCount) overlap=\(diarized.hadOverlap)")
                return diarizedText
            }
            owLog("[OpenWhisper] Batch \(segmentNumber) diarization found no safe target words")
            // No word timings means diarization never judged a single word, so an
            // ambiguous batch must not lose all its speech: use the target-only audio.
            let hadNoTimings = timed.words.isEmpty
                && !timed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hadNoTimings {
                owLog("[OpenWhisper] Batch \(segmentNumber) had text but no word timings; transcribing accepted target audio")
            }
            guard !isAmbiguousTargetMatch || hadNoTimings,
                  filtered.hasAcceptedTargetSpeech else { return nil }
            return try await transcriber.transcribe(
                audioData: TargetSpeakerSegmentFiltering.apply(segment, result: filtered).samples,
                language: language,
                overlapSampleCount: segment.overlapSampleCount
            )
        } catch {
            session.hadDiarizationFailure = true
            lastError = error.localizedDescription
            owLog("[OpenWhisper] Batch \(segmentNumber) diarization failed; preserving masked target-speaker safety: \(error)")
            noteSpeakers {
                let heard = timedTranscription?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !heard.isEmpty { $0.uncertainText = heard }
                $0.notes.append("diarization failed, words not split: \(error)")
            }
            let heard = timedTranscription?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A held Fn key is a deliberate dictation: when no speaker could be told apart
            // at all, the gate made no decision, so the text is pasted like a gate failure
            // instead of being lost (31.9 s Fn hold, 10 Oct 2026, 0 words pasted).
            if isAmbiguousTargetMatch, !heard.isEmpty,
               TargetSpeakerOutputGate.keepsUnidentifiedSpeech(trigger: session.trigger, error: error) {
                owLog("[OpenWhisper] Batch \(segmentNumber) no speaker identified in a deliberate dictation; keeping the whole text")
                noteSpeakers { $0.notes.append("no speaker identified — deliberate dictation, whole text kept") }
                session.hadFailClosedPassthrough = true
                return heard
            }
            // A partial result still has a safe identity-masked path. An ambiguous result
            // has no accepted target samples, so never transcribe its original mixed audio
            // and never offer it for confirmation.
            guard !isAmbiguousTargetMatch,
                  filtered.hasAcceptedTargetSpeech else { return nil }
            if session.trigger != .confirmation, !heard.isEmpty,
               filtered.decision == .accepted, filtered.acceptedAllVoice {
                // The mask removed only silence, so it holds the same speech the first
                // decode heard: decoding it again cost ~0.5 s on short wake commands.
                owLog("[OpenWhisper] Batch \(segmentNumber) gate kept every voice run; reusing the first decode")
                return WhisperTranscriber.deduplicateRepetitivePhrases(in: heard)
            }
            if session.trigger != .confirmation, segment.overlapSampleCount == 0,
               filtered.decision == .accepted, let timed = timedTranscription,
               TargetSpeakerDiarizationResult.allWordsInAcceptedRanges(timed.words, ranges: filtered.acceptedSampleRanges) {
                // The mask dropped only voice no word came from (a short noise run): the timed
                // words are the masked decode's speech, so a second decode only costs ~0.45 s.
                let kept = TargetSpeakerDiarizationResult.render(words: timed.words)
                if !kept.isEmpty {
                    owLog("[OpenWhisper] Batch \(segmentNumber) every word is in accepted audio; reusing the timed decode")
                    return WhisperTranscriber.deduplicateRepetitivePhrases(in: kept)
                }
            }
            if session.trigger == .confirmation, !heard.isEmpty {
                // A one-word answer is too short for diarization; masking its gaps turns
                // "Onaylıyorum" into noise. Keep the full decode of the accepted voice.
                session.heardVariants.append(heard)
            }
            let maskedText = try await transcriber.transcribe(
                audioData: TargetSpeakerSegmentFiltering.apply(segment, result: filtered).samples,
                language: language,
                overlapSampleCount: segment.overlapSampleCount
            )
            if session.trigger == .confirmation, !heard.isEmpty {
                session.heardVariants.append(maskedText)
                return heard
            }
            return maskedText
        }
    }

    /// Decode without diarization, reusing the speech preview when it heard the same audio.
    private func transcribeMasked(
        _ segment: CompletedAudioSegment,
        filtered: TargetSpeakerFilterResult,
        segmentNumber: Int,
        session: RecordingTranscriptionSession,
        transcriber: WhisperTranscriptionService,
        useOriginalAudio: Bool
    ) async throws -> String {
        // Fail-closed and below-threshold results transcribe the original only in their
        // established fallback paths. Normal accepted output uses identity-masked audio.
        let samplesToTranscribe: [Float]
        if useOriginalAudio {
            samplesToTranscribe = segment.samples
        } else {
            samplesToTranscribe = TargetSpeakerSegmentFiltering.apply(segment, result: filtered).samples
        }
        // The preview decoded the unmasked audio. When the mask removed only silence (every
        // voice run kept), that audio holds the same speech: compare it with the original, or
        // the zeroed gaps never match and a short command is decoded twice (~0.45 s, 27 Nov 2026).
        let maskKeptAllVoice = !useOriginalAudio && filtered.decision == .accepted && filtered.acceptedAllVoice
        let previewTarget = maskKeptAllVoice ? segment.samples : samplesToTranscribe
        if let preview = session.speechPreview, segmentNumber == 1, segment.overlapSampleCount == 0,
           let detector = session.previewEndpointDetector {
            let reason = preview.mismatch(previewTarget, language: language, modelID: transcriptionModel,
                                          speechTime: session.doneLastSpeechTime,
                                          coverage: await detector.completedPreviewCoverage())
            if reason == nil, let prepared = await preview.task.value, !session.isCancelled,
               preview.matches(previewTarget, language: language, modelID: transcriptionModel,
                               speechTime: session.doneLastSpeechTime, coverage: detector.previewCoverage) {
                owLog("[SpeechPreview] Reused confident decode; final \(maskKeptAllVoice ? "audio (mask removed only silence)" : "speaker-filtered audio") matched")
                return prepared
            }
            owLog("[SpeechPreview] Not reused: \(reason ?? "preview unusable or changed while waiting"); decoding again")
        }
        return try await transcriber.transcribe(
            audioData: samplesToTranscribe,
            language: language,
            overlapSampleCount: segment.overlapSampleCount
        )
    }

    /// Stops the microphone and throws the audio away: no transcription, no injection.
    func discardActiveRecording(reason: String) {
        voiceEndpointDetector = nil
        smartTurnEndpointDetector = nil
        ownVoiceStopGate = nil
        wakeProbation = nil
        guard recordingState == .recording, let session = activeTranscriptionSession else { return }
        if session.trigger == .confirmation {
            reminderManager?.cancelPendingDeletion()
            whatsAppSender.cancel()
        }
        recordingTimer?.invalidate()
        recordingTimer = nil
        session.isCancelled = true
        session.continuation.finish()
        session.task?.cancel()
        activeTranscriptionSession = nil
        _ = audioEngine?.stopRecording()  // discard captured samples — no transcription
        if let audioEngine { noteRecordingNoiseFloor(audioEngine) }
        recordingMedia.end()
        recordingState = pendingTranscriptionCount > 1 ? .transcribing : .idle
        recordingDuration = 0
        audioLevel = 0
        owLog("[OpenWhisper] Recording cancelled (\(reason))")
    }

    /// Voice-started sessions (Vocal Shortcuts, openwhisper://start) have nobody at the keyboard, so unlike
    /// Fn they end themselves on silence. Start-only: no-op while anything is recording.
    func startVoiceSession(trigger: RecordingTrigger = .external) {
        guard let hotkey, hotkey.isIdle else { return }
        armVoiceAutoStopForNextRecording = true
        hotkey.externalStartHandsFree(trigger: trigger)
        // A short ping so the user hears that "Hey Jarvis" was caught and it's listening.
        if trigger == .wakeWord, !nextWakeSessionHidden { WakeChime.play() }
        // Load the model while the user is still speaking; after an idle night Ollama has
        // unloaded it and the cold load alone outlasts a command's wait.
        // With the chat on the cloud, commands are parsed there too and Gemma isn't needed.
        if ollamaAvailable && !JarvisChat.cloudReady {
            let model = SpotifyManager.selectedOllamaModel
            Task.detached { await LLMCleanup.warmUp(model: model) }
        }
        if ollamaAvailable && SpotifyManager.parserInstalled {
            Task.detached { await LLMCleanup.warmUp(model: SpotifyRequestParser.parserModel) }
        }
        JarvisVoice.shared.warmUp()
    }

    /// Jarvis key: idle → start a session like "Hey Jarvis"; during a hands-free recording
    /// (the one it started, or any other) → finish it like Enter. A live Fn hold is left alone.
    func handleJarvisKey(cancelledFnHold: Bool) {
        guard let hotkey else { return }
        if cancelledFnHold {
            // fn+F5: the Fn half already started a dictation; drop it and run Jarvis instead.
            discardActiveRecording(reason: "Fn hold → Jarvis key")
        }
        if hotkey.isIdle {
            guard recordingState != .recording else { return }
            owLog("[OpenWhisper] Voice session requested (Jarvis key)")
            pendingWakeSpeakerVerified = false
            startVoiceSession(trigger: .jarvisKey)
        } else {
            // No-op during a Fn hold.
            hotkey.externalStopHandsFree()
        }
    }

    /// FlowBar stop button: finish and process, exactly like Enter/Space.
    func finishHandsFreeRecording() {
        hotkey?.externalStopHandsFree()
    }

    func feedVoiceEndpoint(rawRMS: Float, at time: TimeInterval) {
        if recordingState == .recording, rawRMS >= 0.008 {
            activeTranscriptionSession?.doneLastSpeechTime = time
        }
        guard recordingState == .recording, var detector = voiceEndpointDetector else { return }
        let levelDecision = detector.process(rms: rawRMS, at: time)
        voiceEndpointDetector = detector
        if detector.speechDetected != recordingHeardSpeech { recordingHeardSpeech = detector.speechDetected }
        // Relative to the room, not to the user's loudness: a quieter second voice still counts.
        if ownVoiceStopGate != nil, let floor = detector.floorDB {
            let loud = VoiceEndpointDetector.dBFS(fromRMS: rawRMS) >= floor + detector.config.onsetMarginDB
            ownVoiceStopGate?.noteLevel(loud: loud, at: time)
        }
        let smartDecision = smartTurnEndpointDetector?.decision(
            at: time,
            levelSpeechDetected: detector.speechDetected
        ) ?? .useLevelFallback(reason: "not armed")

        let decision: VoiceEndpointDetector.Decision
        switch smartDecision {
        case .continueRecording:
            guard let gate = ownVoiceStopGate, let smart = smartTurnEndpointDetector,
                  let endpoint = smart.lastEndpoint,
                  gate.endsTurnOverPlayback(endpointAt: endpoint.time,
                                            requiredSilence: smart.requiredSilence(after: endpoint),
                                            now: time) else { return }
            guard !ownVoiceGateLogsOnly else {
                owLog("[OwnVoiceStop] Would stop here (turn complete, your voice hasn't come back) — log only")
                return
            }
            owLog(String(format: "[OwnVoiceStop] Turn complete %.3f %.1f s ago and your voice hasn't come back — the rest is the media, stopping",
                         endpoint.probability, time - endpoint.time))
            decision = .stop
        case .stop(let probability):
            owLog(String(format: "[SmartTurn] complete %.3f — stopping", probability))
            decision = .stop
        case .stopAfterIncompleteTimeout:
            owLog("[SmartTurn] incomplete turn stayed silent for 3 s — stopping")
            decision = .stop
        case .stopMaxDuration:
            decision = .stopMaxDuration
        case .cancelNoSpeech:
            decision = .cancelNoSpeech
        case .useLevelFallback(let reason):
            guard levelDecision != .continueRecording else { return }
            owLog("[SmartTurn] level fallback used: \(reason)")
            decision = levelDecision
        }

        owLog(String(format: "[VoiceAutoStop] \(decision) — level %.1f dBFS, ", VoiceEndpointDetector.dBFS(fromRMS: rawRMS))
            + detector.summary + " smart={\(smartTurnEndpointDetector?.summary ?? "disabled")}")
        voiceEndpointDetector = nil
        smartTurnEndpointDetector = nil
        ownVoiceStopGate = nil
        switch decision {
        case .stop, .stopMaxDuration:
            // No release tail: the speaker has already been quiet for `silenceToStop`.
            hotkey?.externalCancelHandsFree()
            stopRecording()
        case .cancelNoSpeech:
            hotkey?.externalCancelHandsFree()
            // Over the reply the window's level detector seeds its floor at the reply's end: a
            // fix said right as Jarvis finishes becomes that floor and never counts as speech
            // (18 Nov 2026: "sesi biraz daha kıs" dropped). Loud sound after the reply means
            // the user spoke; the follow-up still takes only the user's commands from it.
            if commandFollowUpAfterReply, let session = activeTranscriptionSession,
               session.followsCommand, session.doneLastSpeechTime > followUpLiveStart {
                owLog("[FollowUp] Sound after the reply though no speech onset; processing it")
                stopRecording()
            } else {
                discardActiveRecording(reason: "voice trigger, no speech")
            }
        case .continueRecording:
            break
        }
    }

    /// Scores the last 1.5 s against the enrolled voice (one check at a time, every 0.5 s) and
    /// stops the session once someone other than the user has been talking for about 2 s, or,
    /// over media, once no window has been the user's for `noUserVoiceLimit`.
    /// Pauses are Smart Turn's call, not this gate's.
    func checkOwnVoiceEndpoint() {
        guard recordingState == .recording, ownVoiceStopGate != nil, !ownVoiceCheckInFlight,
              let profile = ownVoiceProfile, let audioEngine else { return }
        let now = CACurrentMediaTime()
        guard now - lastOwnVoiceCheck >= OwnVoiceStopGate.checkInterval else { return }
        let samples = audioEngine.recentSamples(count: OwnVoiceStopGate.windowSamples)
        guard samples.count >= OwnVoiceStopGate.windowSamples else { return }
        lastOwnVoiceCheck = now
        ownVoiceCheckInFlight = true
        let filter = targetSpeakerFilter
        let sessionID = activeTranscriptionSession?.id
        Task { [weak self] in
            let score: Float?
            do {
                score = try await filter.wakeSpeakerScore(samples: samples, profile: profile)
            } catch {
                owLog("[OwnVoiceStop] Speaker check failed, disarming: \(error)")
                score = nil
            }
            guard let self else { return }
            self.ownVoiceCheckInFlight = false
            guard self.recordingState == .recording, self.activeTranscriptionSession?.id == sessionID,
                  var gate = self.ownVoiceStopGate else { return }
            guard let score else {
                self.ownVoiceStopGate = nil
                return
            }
            let speech = gate.speechDuration(endingAt: now)
            let verdict = gate.record(score: score, at: now)
            self.ownVoiceStopGate = gate
            // Every check, so a wrong "not your voice" can be traced to its window: when it was,
            // how loud, how much of it counted as speech and what the score made of it.
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
            let counted = speech < gate.minSpeechInWindow
                ? String(format: "ignored, speech < %.1fs", gate.minSpeechInWindow)
                : score >= gate.userThreshold ? "you" : score < gate.otherThreshold ? "not you" : "unsure"
            owLog(String(format: "[OwnVoiceStop] window %.1f–%.1fs score %.3f speech %.1fs level %.1f dBFS%@ → %@",
                         now - gate.startTime - OwnVoiceStopGate.windowDuration, now - gate.startTime, score, speech,
                         VoiceEndpointDetector.dBFS(fromRMS: rms), self.mediaPlaying ? " media" : "", counted))
            WakeClipLog.shared.update(self.activeTranscriptionSession?.wakeClipID) { $0.ownVoiceScores.append(score) }
            guard verdict != .keep else { return }
            let outcome = switch verdict {
            case .keep: ""
            case .otherVoice: " — someone else is talking, stopping"
            case .noUserVoice: String(format: " — no window was your voice for %.0f s over the media, stopping", gate.noUserVoiceLimit)
            }
            owLog(String(format: "[OwnVoiceStop] score %.3f speech %.1fs (user ≥%.2f, other <%.2f)%@",
                         score, gate.speechDuration(endingAt: now), gate.userThreshold, gate.otherThreshold, outcome))
            if self.ownVoiceGateLogsOnly {
                owLog("[OwnVoiceStop] Would stop here — log only, the session goes on")
                gate = OwnVoiceStopGate(startTime: now, watchesPlayback: gate.watchesPlayback)
                self.ownVoiceStopGate = gate
                return
            }
            // A weak wake Whisper didn't confirm, with no word of the user's: the video called.
            if verdict == .noUserVoice, !gate.userHeard, self.activeTranscriptionSession?.wakeUnconfirmed == true {
                self.hotkey?.externalCancelHandsFree()
                self.discardActiveRecording(reason: "unconfirmed wake over media, never your voice")
                return
            }
            self.voiceEndpointDetector = nil
            self.smartTurnEndpointDetector = nil
            self.ownVoiceStopGate = nil
            self.hotkey?.externalCancelHandsFree()
            self.stopRecording()
        }
    }

    /// Scores the last 1.5 s against the session mic's profile every 0.5 s while a wake over
    /// media is on probation. The user's voice pauses the media; none within the window drops the
    /// session, with nothing paused. A check in flight at the deadline is waited for.
    func checkWakeProbation() {
        guard recordingState == .recording, let probation = wakeProbation, !wakeProbationCheckInFlight else { return }
        let now = CACurrentMediaTime()
        if probation.expired(at: now) {
            wakeProbation = nil
            owLog(String(format: "[WakeProbation] No voice of yours within %.0f s — dropping the session, nothing was paused", WakeProbation.window))
            hotkey?.externalCancelHandsFree()
            discardActiveRecording(reason: "unconfirmed wake, never your voice")
            return
        }
        guard now - lastWakeProbationCheck >= WakeProbation.checkInterval, let audioEngine else { return }
        let samples = audioEngine.recentSamples(count: OwnVoiceStopGate.windowSamples)
        guard samples.count >= OwnVoiceStopGate.windowSamples else { return }
        lastWakeProbationCheck = now
        wakeProbationCheckInFlight = true
        let filter = targetSpeakerFilter
        let sessionID = activeTranscriptionSession?.id
        Task { [weak self] in
            let score: Float?
            do {
                score = try await filter.wakeSpeakerScore(samples: samples, profile: probation.profile)
            } catch {
                owLog("[WakeProbation] Speaker check failed, letting the wake through: \(error)")
                score = nil
            }
            guard let self else { return }
            self.wakeProbationCheckInFlight = false
            guard self.recordingState == .recording, self.activeTranscriptionSession?.id == sessionID,
                  var current = self.wakeProbation else { return }
            guard let score else {
                self.confirmWakeProbation("speaker check unavailable")
                return
            }
            let threshold = TargetSpeakerFilter.wakeThreshold
            owLog(String(format: "[WakeProbation] score %.3f (yours ≥%.2f)", score, threshold))
            if current.record(score: score, threshold: threshold) {
                self.wakeProbation = current
                self.confirmWakeProbation(String(format: "command scored %.2f", score))
            }
        }
    }

    /// The "Jarvis" clip is short and often scores under the threshold (0.399 against 0.40 over
    /// music, 28 Oct 2026), so what the user says next is scored too. Two matching windows (media
    /// once scored 0.419 against the profile) mark the wake as the user's: a weak wake Whisper didn't confirm is no longer commands-only, and a held
    /// media pause runs. A miss changes nothing.
    func checkLateWakeVoice() {
        guard recordingState == .recording, let profile = lateWakeVoiceProfile, !lateWakeVoiceCheckInFlight,
              let session = activeTranscriptionSession, session.trigger == .wakeWord else { return }
        let now = CACurrentMediaTime()
        if session.wakeSpeakerVerified || Date().timeIntervalSince(session.startedAt) > Self.lateWakeVoiceWindow {
            lateWakeVoiceProfile = nil
            return
        }
        guard now - lastLateWakeVoiceCheck >= Self.lateWakeVoiceCheckInterval, let audioEngine else { return }
        let samples = audioEngine.recentSamples(count: OwnVoiceStopGate.windowSamples)
        guard samples.count >= OwnVoiceStopGate.windowSamples else { return }
        lastLateWakeVoiceCheck = now
        lateWakeVoiceCheckInFlight = true
        let filter = targetSpeakerFilter
        Task { [weak self] in
            let score = try? await filter.wakeSpeakerScore(samples: samples, profile: profile)
            guard let self else { return }
            self.lateWakeVoiceCheckInFlight = false
            guard let score, self.recordingState == .recording, self.activeTranscriptionSession === session,
                  !session.wakeSpeakerVerified else { return }
            let threshold = TargetSpeakerFilter.wakeThreshold
            guard score >= threshold else { return }
            owLog(String(format: "[LateWakeVoice] score %.3f (yours ≥%.2f)", score, threshold))
            self.lateWakeVoiceMatches += 1
            guard self.lateWakeVoiceMatches >= Self.lateWakeVoiceMatchesNeeded else { return }
            self.lateWakeVoiceProfile = nil
            session.wakeSpeakerVerified = true
            self.revealWakeSession("your voice after the wake word")
            if session.wakeUnconfirmed {
                session.wakeUnconfirmed = false
                owLog("[LateWakeVoice] Your voice after the wake word — the session stays open, for commands only")
            }
            self.confirmWakeProbation(String(format: "speech after the wake scored %.2f", score))
        }
    }

    /// How long into a wake session `checkLateWakeVoice` keeps scoring, and how often.
    static let lateWakeVoiceWindow: TimeInterval = 5
    static let lateWakeVoiceCheckInterval: TimeInterval = 1
    static let lateWakeVoiceMatchesNeeded = 2

    /// A hidden weak wake turned out to be a call (the user's voice, or Whisper heard the word):
    /// the bar, the chime and the media handling it put off start now.
    func revealWakeSession(_ why: String) {
        guard wakeSessionHidden else { return }
        wakeSessionHidden = false
        owLog("[WakeWord] Hidden session shown — \(why)")
        guard recordingState == .recording else { return }
        WakeChime.play()
        if let hold = hiddenWakeMediaHold {
            hiddenWakeMediaHold = nil
            recordingMedia.begin(sparingYouTube: true, holdingPause: hold && wakeProbation != nil)
        }
    }

    /// The user's voice confirmed a wake on probation: the held pause runs now.
    func confirmWakeProbation(_ why: String) {
        guard wakeProbation != nil else { return }
        revealWakeSession("your voice")
        wakeProbation = nil
        // A weak wake also needs the word: the user talking to someone isn't a call.
        if weakWakeWordPending {
            heldPauseAwaitsWord = true
            owLog("[WakeProbation] Your voice (\(why)) — the pause waits for Whisper to hear the word")
            return
        }
        if activeTranscriptionSession?.wakeWordUnheard == true {
            owLog("[WakeProbation] Your voice (\(why)), but no wake word — the media keeps playing")
            return
        }
        owLog("[WakeProbation] Your voice (\(why)) — pausing the media")
        recordingMedia.confirmPause()
    }

    /// Whether this recording runs DeepFilterNet (`DeepFilterAutoDecider`), logged with its inputs.
    func decideDeepFilter(inputDeviceUID: String?, inputIsBluetooth: Bool, echoCancellation: Bool) -> Bool {
        let device = inputDeviceUID ?? AudioEngine.defaultInputDeviceUID() ?? "default"
        let floor = deepFilterAuto.floor(for: device)
        let decision = deepFilterAuto.decide(
            setting: deepFilterSetting,
            device: device,
            mediaPlaying: mediaPlaying,
            echoCancellation: echoCancellation,
            measuresRoom: !VoiceTestInjector.shared.isActive
        )
        let floorText = floor.map { String(format: "%.1f dBFS (%.1f s, %.0f s ago)", $0.dbfs, $0.seconds, Date().timeIntervalSince($0.measuredAt)) } ?? "none"
        owLog("[DeepFilterAuto] \(decision.enabled ? "ON" : "OFF") (\(decision.reason)) | setting=\(deepFilterSetting.rawValue) device=\(device) bluetooth=\(inputIsBluetooth) media=\(mediaPlaying) aec=\(echoCancellation) floor=\(floorText)"
            + String(format: " thresholds off<%.0f on>=%.0f", DeepFilterAutoDecider.cleanBelowDBFS, DeepFilterAutoDecider.noisyFromDBFS))
        activeDeepFilterDecision = decision
        return decision.enabled
    }

    /// Files the stopped recording's raw noise floor for the next decision on the same input.
    func noteRecordingNoiseFloor(_ audioEngine: AudioEngine) {
        let floor = audioEngine.lastRawNoiseFloor
        guard !VoiceTestInjector.shared.isActive else {
            deepFilterAuto.recordingStopped(floorDBFS: nil, measuredSeconds: 0)
            return
        }
        if deepFilterAuto.recordingStopped(floorDBFS: floor.dbfs, measuredSeconds: floor.seconds) {
            owLog(String(format: "[DeepFilterAuto] Noted floor %.1f dBFS over %.1f s", floor.dbfs ?? .nan, floor.seconds))
        }
    }

    /// Returns true when the resolved dictation input is a Bluetooth device.
    /// Echo-cancel this recording against what the Mac plays (`RecordingEchoCanceller`): only
    /// when opted in, something is playing, and there is a way to get the reference. Only the
    /// Mac mic: buds sit in the ear (no speaker echo), an external mic sits close to the mouth and
    /// its recordings pause the music at once.
    func recordingEchoCancellationWanted(mic: TargetSpeakerMic) -> Bool {
        guard EchoCancellationSettings.recordingIsEnabled else { return false }
        if mic == .external, mediaPlaying {
            owLog("[AEC] External mic — recording without echo cancellation")
        }
        let wanted = mediaPlaying && mic == .mac
        guard wanted else { return false }
        guard SystemOutputReference.hasPermission else {
            owLog("[AEC] No Screen Recording permission — recording without echo cancellation")
            return false
        }
        return true
    }

    /// The Bluetooth mic is live: from here on the user can speak (a tick says so), so the auto-stop timeouts
    /// (no-speech window, max duration) start now instead of at the key press.
    func markRecordingInputReady(sessionID: UInt64) {
        guard !recordingInputReady, nextTranscriptionID == sessionID, recordingState == .recording else { return }
        recordingInputReady = true
        // Heard in the buds: speak now, without looking at the bar.
        if !wakeSessionHidden { WakeChime.play() }
        let now = CACurrentMediaTime()
        // Over Jarvis's reply the window starts when he is done, not when the mic is live.
        if !commandFollowUpAwaitingReplyEnd, let detector = voiceEndpointDetector {
            voiceEndpointDetector = VoiceEndpointDetector(
                startTime: now,
                config: detector.config,
                ignoreUntil: recordingIgnoredLeadingSeconds > 0 ? now + recordingIgnoredLeadingSeconds : nil
            )
        }
        smartTurnEndpointDetector?.restartClock(at: now)
        lastOwnVoiceCheck = now
    }

    /// Jarvis finished the reply a command follow-up opened over: the window for a fix
    /// ("sonrakine geç") starts now. Speech that began during the reply and runs on is kept
    /// (the recording is processed if sound followed the reply, see `.cancelNoSpeech`).
    func commandFollowUpReplyEnded() {
        // A recording not started yet opens as an ordinary window, counted from its start.
        commandFollowUpOverReply = false
        guard commandFollowUpAwaitingReplyEnd else { return }
        commandFollowUpAwaitingReplyEnd = false
        guard recordingState == .recording, activeTranscriptionSession?.followsCommand == true,
              let detector = voiceEndpointDetector else { return }
        commandFollowUpAfterReply = true
        let now = CACurrentMediaTime()
        followUpLiveStart = now + Self.replyFollowUpEchoGuard
        followUpLiveText = nil
        var config = detector.config
        config.noSpeechTimeout = screenModeActive ? screenModeWindow : Self.commandFollowUpWindow
        config.maxDuration = screenModeActive ? ScreenMode.maxDuration : Self.commandFollowUpMaxDuration
        voiceEndpointDetector = VoiceEndpointDetector(
            startTime: now, config: config, ignoreUntil: now + Self.replyFollowUpEchoGuard)
        owLog(String(format: "[FollowUp] Reply finished; listening %.1f s more for a fix", Self.commandFollowUpWindow))
    }
}
