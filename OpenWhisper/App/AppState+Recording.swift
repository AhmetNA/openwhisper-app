import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    func startRecording() {
        recordingPreviewTask?.cancel()
        let tStart = CACurrentMediaTime()
        let elapsedFromFn = (tStart - GlobalHotkey.lastFnPressUptime) * 1000
        owLog("[Perf] [StartRecordingEnter] startRecording() entered (+\(String(format: "%.2f", elapsedFromFn))ms from Fn press)")
        // A new command cuts Jarvis off, and his voice must not end up in the recording. Not a
        // command follow-up opened over his reply: it listens while he finishes.
        if !(hotkey?.trigger == .followUp && commandFollowUpOverReply) { JarvisVoice.shared.stop() }

        if targetSpeakerEnrollmentActive {
            if targetSpeakerEnrollmentIsRecording {
                stopTargetSpeakerEnrollmentRecording()
            } else {
                startTargetSpeakerEnrollmentRecording()
            }
            return
        }
        // Cancel any pending tail-stop work item and finish previous recording if a new recording starts immediately
        if delayedStopWorkItem != nil {
            delayedStopWorkItem?.cancel()
            delayedStopWorkItem = nil
            stopRecording()
        }

        let armVoiceAutoStop = armVoiceAutoStopForNextRecording
        armVoiceAutoStopForNextRecording = false
        let recordingTrigger = hotkey?.trigger ?? .fnHold
        let commandFollowUp = recordingTrigger == .followUp ? pendingCommandFollowUp : nil
        pendingCommandFollowUp = nil
        let overReply = commandFollowUp != nil && commandFollowUpOverReply
        commandFollowUpOverReply = false
        commandFollowUpAwaitingReplyEnd = overReply

        // A previous session may still be transcribing. Only an already-active microphone
        // session blocks a new recording.
        guard recordingState != .recording else { return }
        clearFlowBarMessage()
        guard modelLoaded else {
            owLog("[OpenWhisper] Cannot record — model not loaded yet")
            return
        }
        let sessionStart = CACurrentMediaTime()
        // A reply follow-up behaves like "Hey Jarvis" once the user speaks (full command,
        // Smart Turn endpoint); only its no-speech window is short.
        let wakeLikeSession = [.wakeWord, .jarvisKey, .followUp].contains(recordingTrigger)
        // Smart Turn would take Jarvis's reply for the user's speech, and its clock can't be
        // moved past the reply: a follow-up over the reply uses the level detector alone.
        let useSmartTurnEndpoint = armVoiceAutoStop && wakeLikeSession && !overReply
        let isDeletionConfirmation = armVoiceAutoStop && recordingTrigger == .confirmation
        let isReplyFollowUp = armVoiceAutoStop && recordingTrigger == .followUp
        var smartTurnConfig = SmartTurnEndpointDetector.Config()
        // Jarvis's own voice tail (or its echo on the Mac speakers) must not count as an answer.
        let ignoredLeadingSeconds: TimeInterval = mediaPlaying ? 0.8 : isReplyFollowUp ? Self.replyFollowUpEchoGuard : 0
        recordingIgnoredLeadingSeconds = ignoredLeadingSeconds
        let recordingInputDeviceUID = resolvedInputDeviceUID(for: recordingTrigger)
        let recordingInputIsBluetooth = Self.inputIsBluetooth(uid: recordingInputDeviceUID)
        if ![.confirmation, .followUp].contains(recordingTrigger) {
            chainedBluetoothInputUID = recordingInputIsBluetooth ? recordingInputDeviceUID : nil
        }
        // A handed-over wake stream is already live; a fresh Bluetooth capture is not.
        let waitsForLinkAudio = recordingInputIsBluetooth
        var endpointFallbackConfig: VoiceEndpointDetector.Config = recordingInputIsBluetooth ? .closeTalk : .init()
        // Smart Turn normally answers at the first real endpoint. Three seconds is its documented
        // incomplete-turn safety limit and also keeps a model failure bounded.
        if useSmartTurnEndpoint { endpointFallbackConfig.silenceToStop = 3 }
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
            let window = commandFollowUp != nil ? Self.commandFollowUpWindow : Self.replyFollowUpWindow
            endpointFallbackConfig.noSpeechTimeout = window
            smartTurnConfig.noSpeechTimeout = window
            if commandFollowUp != nil {
                // A fix is a few words; vocals of the song just started must not keep it open.
                endpointFallbackConfig.maxDuration = Self.commandFollowUpMaxDuration
                smartTurnConfig.maxDuration = Self.commandFollowUpMaxDuration
            }
            if overReply {
                // Jarvis is still speaking: nothing counts until `commandFollowUpReplyEnded`
                // starts the window. These only bound a reply that never reports its end.
                endpointFallbackConfig.noSpeechTimeout = 60
                endpointFallbackConfig.maxDuration = 90
            }
            owLog(String(format: "[FollowUp] Listening for %@ (%.1f s window)",
                         commandFollowUp != nil ? "a fix to the command" : "an answer", window))
        }
        voiceEndpointDetector = armVoiceAutoStop
            ? VoiceEndpointDetector(
                startTime: sessionStart,
                config: endpointFallbackConfig,
                ignoreUntil: overReply ? sessionStart + 60
                    : ignoredLeadingSeconds > 0 ? sessionStart + ignoredLeadingSeconds : nil
            )
            : nil
        smartTurnEndpointDetector = useSmartTurnEndpoint
            ? SmartTurnEndpointDetector(
                startTime: sessionStart,
                config: smartTurnConfig,
                ignoredLeadingSeconds: ignoredLeadingSeconds
            )
            : nil
        // Over a video or song only the user's voice keeps the session open, filter on or off:
        // the speakers' residual after echo cancellation keeps Silero hearing "speech" forever.
        // Not for buds (the music is paused, and their mic isn't the enrolled one) or over
        // Jarvis's reply (the window waits for it to end).
        let watchesPlayback = mediaPlaying && !recordingInputIsBluetooth && !overReply
        // The buds' call-mode mic scores 0.2–0.35 against the Mac-mic profile, so every batch was
        // rejected: buds recordings are filtered only against their own profile.
        let sessionProfile = Self.sessionTargetSpeakerProfile(
            inputIsBluetooth: recordingInputIsBluetooth, mac: targetSpeakerProfile, buds: budsTargetSpeakerProfile
        )
        let targetSpeakerFiltersSession = targetSpeakerEnabled && sessionProfile != nil
        if targetSpeakerEnabled && recordingInputIsBluetooth {
            owLog(sessionProfile == nil
                ? "[TargetSpeaker] Bluetooth input: speaker filter off (no buds profile)"
                : "[TargetSpeaker] Bluetooth input: filtering against the buds profile")
        }
        // Not on buds yet: the stop gate scores every 0.5 s and cuts the session after ~2 s of
        // "someone else", too risky before the buds profile has been checked in noise.
        ownVoiceStopGate = armVoiceAutoStop && wakeLikeSession && !recordingInputIsBluetooth
            && (targetSpeakerFiltersSession || watchesPlayback) && targetSpeakerProfile != nil
            && !VoiceTestInjector.shared.bypassesSpeakerChecks
            ? OwnVoiceStopGate(startTime: sessionStart, watchesPlayback: watchesPlayback)
            : nil
        ownVoiceCheckInFlight = false
        lastOwnVoiceCheck = sessionStart
        if ownVoiceStopGate != nil {
            owLog("[OwnVoiceStop] Armed for wake-word session" + (watchesPlayback ? " (media playing: only your voice keeps it open)" : ""))
        }

        // The Settings switch decides for every trigger, voice sessions included. Buds are the
        // exception: their mic hears the music played into the ear (measured 16 Oct 2026: SNR
        // −2 dB under Spotify, transcribed as Icelandic), so it pauses at once whatever the switch.
        // Not after a command: the user is judging the song or video it just started.
        let pausesMedia = commandFollowUp == nil && (audioDuckingEnabled || (recordingInputIsBluetooth && mediaPlaying))
        if pausesMedia {
            recordingMedia.begin(immediately: recordingInputIsBluetooth)
        }

        // 1. Start microphone recording asynchronously off main thread FIRST — before any UI
        // work (flow bar appearance, NSWorkspace query) gets a chance to occupy the main thread
        // and delay this dispatch. Read everything the background block needs up front so the
        // dispatch itself has zero main-thread work between it and the guards above.
        // Apple voice processing needs AVAudioEngine, which falls back to the wrong mic around
        // Bluetooth buds; their in-ear mic has no speaker echo and call mode already denoises.
        var processingMode: AudioProcessingMode = recordingInputIsBluetooth && audioProcessingMode == .appleVoiceProcessing
            ? .off : audioProcessingMode
        if processingMode != audioProcessingMode {
            owLog("[AudioEngine] Bluetooth input: recording without Apple voice processing")
        }
        let echoCancellation = recordingEchoCancellationWanted(inputIsBluetooth: recordingInputIsBluetooth)
        // Decided once here for the whole recording, never switched while it runs.
        if processingMode != .appleVoiceProcessing {
            processingMode = decideDeepFilter(
                inputDeviceUID: recordingInputDeviceUID,
                inputIsBluetooth: recordingInputIsBluetooth,
                echoCancellation: echoCancellation
            ) ? .deepFilterNet : .off
        }
        let sessionID = nextTranscriptionID &+ 1
        let playbackHeard = OSAllocatedUnfairLock(initialState: false)
        let audioEngineRef = audioEngine
        let smartEndpoint = smartTurnEndpointDetector
        let endpointSampleCallback: (([Float]) -> Void)? = smartEndpoint.map { endpoint in
            { samples in endpoint.feed(samples) }
        }
        let pickedNote = inputDeviceUID.map { uid in
            uid == recordingInputDeviceUID ? " (picked mic)" : " (picked mic \(inputDeviceName ?? uid) not connected; fallback)"
        } ?? " (automatic)"
        owLog("[OpenWhisper] Resolved recording input: \(recordingInputDeviceUID ?? "system default")\(pickedNote)")
        activeRecordingInputUID = recordingInputDeviceUID ?? AudioEngine.defaultInputDeviceUID()
        // Voice sessions continue the wake listener's running mic stream (same device only)
        // instead of restarting the hardware; after "Hey Jarvis" the audio since the wake comes
        // along, so a command said without a pause keeps its first words. Taken here, before
        // `recordingState` below stops the listener.
        let captureHandoff: WakeCaptureHandoff? = wakeLikeSession && processingMode != .appleVoiceProcessing
            ? wakeWordListener?.handOffCapture(
                toDeviceID: recordingInputDeviceUID.flatMap(AudioEngine.audioDeviceID(forUID:)) ?? AudioEngine.defaultInputDeviceID(),
                wakePreroll: recordingTrigger == .wakeWord,
                echo: echoCancellation)
            : nil
        if audioEngineRef == nil {
            captureHandoff?.capture.stop()
            captureHandoff?.echo?.release()
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let didFallBackFromDeepFilter = audioEngineRef?.startRecording(
                deviceUID: recordingInputDeviceUID,
                audioProcessingMode: processingMode,
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

            let tAudioDone = CACurrentMediaTime()
            let audioElapsed = (tAudioDone - GlobalHotkey.lastFnPressUptime) * 1000
            owLog("[Perf] [AudioEngineStarted] Mic recording started (+\(String(format: "%.2f", audioElapsed))ms from Fn press)")

            // Non-blocking: this recording is already under way by the time this lands, so it
            // can never delay the Fn->audio path -- it only informs the user after the fact.
            if didFallBackFromDeepFilter {
                Task { @MainActor in
                    self?.showFlowBarMessage("Gürültü engelleme henüz hazır değildi, bu kayıt engelsiz işlendi")
                }
            }
        }

        // 2. Update recordingState so flow bar UI appears
        recordingInputReady = !waitsForLinkAudio
        if waitsForLinkAudio {
            // A link that never delivers audio must not leave the bar on "connecting".
            DispatchQueue.main.asyncAfter(deadline: .now() + AudioEngine.linkAudioWaitLimit + 0.5) { [weak self] in
                guard let self, !self.recordingInputReady, self.nextTranscriptionID == sessionID else { return }
                owLog("[AudioEngine] Bluetooth mic sent no audio; showing the recording as live anyway")
                self.markRecordingInputReady(sessionID: sessionID)
            }
        }
        recordingState = .recording
        recordingDuration = 0
        audioLevel = 0
        lastError = nil

        // Save the currently focused app (instant NSWorkspace query)
        targetApp = NSWorkspace.shared.frontmostApplication
        owLog("[OpenWhisper] Target app: \(targetApp?.localizedName ?? "unknown")")

        // 3. Create session immediately with non-blocking initial context (AX details captured in background)
        nextTranscriptionID &+= 1
        let initialContext = PasteContext.initial(targetApp: targetApp)
        let session = RecordingTranscriptionSession(
            id: nextTranscriptionID,
            targetApp: targetApp,
            targetSpeakerEnabled: targetSpeakerFiltersTranscription && sessionProfile != nil,
            targetSpeakerProfile: sessionProfile,
            pasteContext: initialContext
        )
        session.isVoiceCommand = armVoiceAutoStop
        session.trigger = recordingTrigger
        session.mediaWasPlaying = mediaPlaying
        session.targetSpeakerMic = recordingInputIsBluetooth ? .buds : .mac
        if recordingInputIsBluetooth && pausesMedia {
            let media = recordingMedia
            session.playbackSurvivedPause = { media.playbackLeftRunning }
        }
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
        activeTranscriptionSession = session
        pendingTranscriptionCount += 1

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
                        self.lastError = "Ses geçmişi kaydedilemedi: \(error.localizedDescription)"
                    }
                }
                await self.transcribeStreamingSegment(segment, session: session)
            }
            await self.finishTranscription(session)
        }
        session.task = transcriptionTask
        transcriptionQueueTail = transcriptionTask
        transcriptionQueueTailID = session.id

        // 4. Start duration timer
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingState == .recording else { return }
                self.recordingDuration += 0.25
                self.enqueueCompletedAudioSegments()
                self.checkOwnVoiceEndpoint()
            }
        }

        // Dictation snapshot reset (instant if no active snapshot)
        DictationSnapshot.shared.handleNewDictationStarting()

        // 5. Perform non-essential background tasks asynchronously:
        // Async paste context capture off main thread
        let currentTargetApp = targetApp
        Task.detached(priority: .userInitiated) {
            let capturedContext = PasteContext.capture(targetApp: currentTargetApp)
            await MainActor.run { [weak session] in
                session?.pasteContext = capturedContext
            }
        }
    }

    /// Schedules stopRecording() after a short tail delay (default 0.40s / 400ms) so that speech spoken
    /// right as the hotkey/Fn key is released is not truncated from the audio buffer. Visually,
    /// the UI transitions to `.transcribing` immediately on key release so the user feels an instant response.
    func stopRecordingWithTail(delay: TimeInterval = 0.40) {
        guard recordingState == .recording else { return }
        voiceEndpointDetector = nil
        smartTurnEndpointDetector = nil
        ownVoiceStopGate = nil
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
        noteRecordingNoiseFloor(audioEngine)
        session.latency.markRecordingStopped()
        // A voice command keeps media paused until it has run (see finishTranscription).
        if !session.isVoiceCommand {
            recordingMedia.end()
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
        guard !session.isCancelled else { return }
        let transcriptionStartedAt = session.latency.timestamp()
        defer { session.latency.record(.transcription, since: transcriptionStartedAt) }
        session.nextSegmentNumber += 1
        let segmentNumber = session.nextSegmentNumber

        guard let transcriber = activeTranscriptionService else {
            owLog("[OpenWhisper] No transcriber for background batch \(segmentNumber)")
            return
        }

        let filtered: TargetSpeakerFilterResult
        // The batch's entry in `session.speakerBatches`; written to /tmp/openwhisper.log on every exit.
        var speakerLogIndex: Int?
        func noteSpeakers(_ update: (inout SpeakerBatchLog) -> Void) {
            guard let speakerLogIndex else { return }
            update(&session.speakerBatches[speakerLogIndex])
        }
        defer {
            if let speakerLogIndex {
                owLog("[Speakers] " + session.speakerBatches[speakerLogIndex].lines.joined(separator: " /"))
            }
        }
        if session.targetSpeakerEnabled {
            owLog("[TargetSpeaker] Batch \(segmentNumber) filtering segment: samples=\(segment.samples.count), targetSpeakerEnabled=true, profileEmbeddings=\(session.targetSpeakerProfile?.embeddings.count ?? 0)")
            let result = await targetSpeakerFilter.filter(
                samples: segment.samples,
                profile: session.targetSpeakerProfile,
                enabled: true,
                audioProcessingMode: audioProcessingMode
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
            speakerLogIndex = session.speakerBatches.count - 1
        } else {
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
        let shouldUseDiarization = session.targetSpeakerEnabled
            && !filtered.wasFailClosed
            && targetSpeakerDiarizationReady
            && filtered.hadVoiceActivity
            && canUseDiarizationDecision
            && !skipsUnscorableDiarization
        if session.targetSpeakerEnabled && filtered.decision == .partial {
            session.hadPartialTargetSpeech = true
        }
        let isBelowThresholdRejection = session.targetSpeakerEnabled
            && !filtered.wasFailClosed
            && (filtered.decision == .rejected || filtered.decision == .noVoice)

        if isAmbiguousTargetMatch {
            session.hadAmbiguousTargetSpeech = true
            guard filtered.hadVoiceActivity else {
                owLog("[OpenWhisper] Batch \(segmentNumber) has no voice activity; Whisper skipped")
                noteSpeakers { $0.notes.append("no voice activity, Whisper skipped") }
                return
            }
            guard shouldUseDiarization else {
                owLog("[OpenWhisper] Batch \(segmentNumber) ambiguous speech withheld because diarization is not ready")
                noteSpeakers { $0.notes.append("ambiguous speech withheld, not transcribed (diarization not ready)") }
                return
            }
            owLog("[OpenWhisper] Batch \(segmentNumber) has unresolved target-speaker ambiguity; trying timed overlap filtering")
        } else if isSingleSpeakerUncertain {
            session.hadSingleSpeakerUncertain = true
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
            return
        } else if isBelowThresholdRejection {
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
                return
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
                        guard !session.isCancelled else { return }
                        if !heard.isEmpty, !heard.hasPrefix("[BLANK"), !heard.hasPrefix("(BLANK") {
                            session.playbackCommandTexts.append(heard)
                        }
                        owLog("[OpenWhisper] Batch \(segmentNumber) rejected while media played; transcribed for a command only: '\(heard)'")
                        noteSpeakers { $0.notes.append("rejected while media played, transcribed for a command only") }
                    } catch {
                        owLog("[OpenWhisper] Batch \(segmentNumber) command transcription over media failed: \(error)")
                    }
                    return
                }
                owLog("[OpenWhisper] Batch \(segmentNumber) rejected while media played; Whisper skipped (speaker audio is never salvaged)")
                noteSpeakers { $0.notes.append("rejected while media played, Whisper skipped") }
                return
            }
            owLog("[OpenWhisper] Batch \(segmentNumber) below target-speaker threshold; transcribing for clipboard salvage only")
        } else if isFailClosedPassthrough {
            owLog("[OpenWhisper] Batch \(segmentNumber) target-speaker gate failed closed; transcribing as normal dictation")
        }

        do {
            let segmentText: String
            if shouldUseDiarization {
                var timedTranscription: TimedTranscriptionResult?
                // The speaker half of diarization needs only the audio: run it during the decode.
                // On a 23 s dictation the two took 1.5 s and 1.4 s one after the other.
                let diarization = targetSpeakerDiarization
                let speakerAnalysis = session.targetSpeakerProfile.map { profile in
                    Task {
                        try await diarization.analyzeSpeakers(
                            audioData: segment.samples,
                            profile: profile,
                            audioProcessingMode: audioProcessingMode
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
                        audioProcessingMode: audioProcessingMode,
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
                        segmentText = diarizedText
                        owLog("[OpenWhisper] Batch \(segmentNumber) diarized target words=\(diarized.acceptedWordCount) overlap=\(diarized.hadOverlap)")
                    } else {
                        owLog("[OpenWhisper] Batch \(segmentNumber) diarization found no safe target words")
                        // No word timings means diarization never judged a single word, so an
                        // ambiguous batch must not lose all its speech: use the target-only audio.
                        let hadNoTimings = timed.words.isEmpty
                            && !timed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        if hadNoTimings {
                            owLog("[OpenWhisper] Batch \(segmentNumber) had text but no word timings; transcribing accepted target audio")
                        }
                        guard !isAmbiguousTargetMatch || hadNoTimings,
                              filtered.hasAcceptedTargetSpeech else { return }
                        segmentText = try await transcriber.transcribe(
                            audioData: TargetSpeakerSegmentFiltering.apply(segment, result: filtered).samples,
                            language: language,
                            overlapSampleCount: segment.overlapSampleCount
                        )
                    }
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
                        segmentText = heard
                    } else {
                        // A partial result still has a safe identity-masked path. An ambiguous result
                        // has no accepted target samples, so never transcribe its original mixed audio
                        // and never offer it for confirmation.
                        guard !isAmbiguousTargetMatch,
                              filtered.hasAcceptedTargetSpeech else { return }
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
                            segmentText = heard
                        } else {
                            segmentText = maskedText
                        }
                    }
                }
            } else {
                // Fail-closed and below-threshold results transcribe the original only in their
                // established fallback paths. Normal accepted output uses identity-masked audio.
                let samplesToTranscribe: [Float]
                if isFailClosedPassthrough || isBelowThresholdRejection {
                    samplesToTranscribe = segment.samples
                } else {
                    samplesToTranscribe = TargetSpeakerSegmentFiltering.apply(segment, result: filtered).samples
                }
                segmentText = try await transcriber.transcribe(
                    audioData: samplesToTranscribe,
                    language: language,
                    overlapSampleCount: segment.overlapSampleCount
                )
            }
            guard !session.isCancelled else { return }
            owLog("[OpenWhisper] Batch \(segmentNumber) overlap=\(segment.overlapSampleCount) samples text=\(segmentText)")
            guard !segmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            session.allSegmentTexts.append(segmentText)
            let trimmedSegmentText = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
            noteSpeakers { entry in
                if isBelowThresholdRejection {
                    entry.othersText = trimmedSegmentText
                } else {
                    entry.ownText = trimmedSegmentText
                    if isFailClosedPassthrough {
                        entry.notes.append("filter error — whole text kept as normal dictation, not split")
                    } else if !shouldUseDiarization && entry.levels.others.seconds >= 0.3 {
                        entry.notes.append("other voices masked out, their words not transcribed (diarization not ready)")
                    }
                }
            }
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

    /// Stops the microphone and throws the audio away: no transcription, no injection.
    func discardActiveRecording(reason: String) {
        voiceEndpointDetector = nil
        smartTurnEndpointDetector = nil
        ownVoiceStopGate = nil
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
        if trigger == .wakeWord { WakeChime.play() }
        // Load the model while the user is still speaking; after an idle night Ollama has
        // unloaded it and the cold load alone outlasts a command's wait.
        // With the chat on the cloud, commands are parsed there too and Gemma isn't needed.
        if ollamaAvailable && !JarvisChat.cloudReady {
            let model = SpotifyManager.selectedOllamaModel
            Task.detached { await LLMCleanup.warmUp(model: model) }
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
        guard recordingState == .recording, var detector = voiceEndpointDetector else { return }
        let levelDecision = detector.process(rms: rawRMS, at: time)
        voiceEndpointDetector = detector
        // Relative to the room, not to the user's loudness: a quieter second voice still counts.
        if ownVoiceStopGate != nil, let floor = detector.floorDB {
            let loud = VoiceEndpointDetector.dBFS(fromRMS: rawRMS) >= floor + detector.config.onsetMarginDB
            ownVoiceStopGate?.noteLevel(loud: loud, at: time)
        }
        let smartDecision = smartTurnEndpointDetector?.decision(
            at: time,
            levelSpeechDetected: detector.speechDetected
        ) ?? .useLevelFallback(reason: "not armed")
        // Tuning aid: once a second, the level against the floor and end threshold.
        if time - lastVoiceEndpointTrace >= 1 {
            lastVoiceEndpointTrace = time
            let smartSummary = smartTurnEndpointDetector?.summary ?? "disabled"
            owLog(String(format: "[VoiceAutoStop] level %.1f dBFS — ", VoiceEndpointDetector.dBFS(fromRMS: rawRMS)) + detector.summary + " smart={\(smartSummary)}")
        }

        let decision: VoiceEndpointDetector.Decision
        switch smartDecision {
        case .continueRecording:
            guard let gate = ownVoiceStopGate, let smart = smartTurnEndpointDetector,
                  let endpoint = smart.lastEndpoint,
                  gate.endsTurnOverPlayback(endpointAt: endpoint.time,
                                            requiredSilence: smart.requiredSilence(after: endpoint),
                                            now: time) else { return }
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

        owLog("[VoiceAutoStop] \(decision) — \(detector.summary)")
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
            discardActiveRecording(reason: "voice trigger, no speech")
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
              let profile = targetSpeakerProfile, let audioEngine else { return }
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
            let verdict = gate.record(score: score, at: now)
            self.ownVoiceStopGate = gate
            WakeClipLog.shared.update(self.activeTranscriptionSession?.wakeClipID) { $0.ownVoiceScores.append(score) }
            let outcome = switch verdict {
            case .keep: ""
            case .otherVoice: " — someone else is talking, stopping"
            case .noUserVoice: String(format: " — no window was your voice for %.0f s over the media, stopping", gate.noUserVoiceLimit)
            }
            owLog(String(format: "[OwnVoiceStop] score %.3f speech %.1fs (user ≥%.2f, other <%.2f)%@",
                         score, gate.speechDuration(endingAt: now), gate.userThreshold, gate.otherThreshold, outcome))
            guard verdict != .keep else { return }
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
    /// when opted in, something is playing, and there is a way to get the reference. Bluetooth
    /// mics sit in the ear (no speaker echo); voice processing already cancels echo itself.
    func recordingEchoCancellationWanted(inputIsBluetooth: Bool) -> Bool {
        guard EchoCancellationSettings.recordingIsEnabled else { return false }
        let wanted = mediaPlaying && audioProcessingMode != .appleVoiceProcessing && !inputIsBluetooth
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
        WakeChime.play()
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
    /// ("sonrakine geç") starts now. Speech that began during the reply and runs on is kept.
    func commandFollowUpReplyEnded() {
        // A recording not started yet opens as an ordinary window, counted from its start.
        commandFollowUpOverReply = false
        guard commandFollowUpAwaitingReplyEnd else { return }
        commandFollowUpAwaitingReplyEnd = false
        guard recordingState == .recording, activeTranscriptionSession?.followsCommand == true,
              let detector = voiceEndpointDetector else { return }
        let now = CACurrentMediaTime()
        var config = detector.config
        config.noSpeechTimeout = Self.commandFollowUpWindow
        config.maxDuration = Self.commandFollowUpMaxDuration
        voiceEndpointDetector = VoiceEndpointDetector(
            startTime: now, config: config, ignoreUntil: now + Self.replyFollowUpEchoGuard)
        owLog(String(format: "[FollowUp] Reply finished; listening %.1f s more for a fix", Self.commandFollowUpWindow))
    }
}
