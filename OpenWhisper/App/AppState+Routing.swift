import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

/// One `finishTranscription` run: the transcript, and what its steps leave for the `defer`s
/// at the top of that function, which run after all of them.
@MainActor
private final class FinishRun {
    let session: RecordingTranscriptionSession
    var traceID: UUID?
    var text = ""
    var trimmed = ""
    var generation: UInt64 = 0
    var focus: AppFocus?
    var agentDeliveryFailure: String?
    /// Jarvis opened the app or chat it sends to: the Flow bar keeps saying so.
    var jarvisChangedScreen = false
    // Set when a command ran: listen a moment longer for a fix ("sonrakine geç").
    var commandFollowUp: CommandFollowUp.Domain?? = nil
    // An agent app or a new chat was opened: listen for commands or dictation there.
    var conversationContinuationApp: NSRunningApplication?
    // Opened already as Jarvis's reply started (`speakAfterCommand`).
    var followUpOpenedOverReply = false
    // Media paused when a voice session started plays again only after its command
    // (or dictation) is done, on every exit path below. A recording started meanwhile
    // owns the pause now and releases it when it stops.
    var resumeMediaAfterCommand = true
    // A follow-up question (deletion confirmation) keeps the music paused through the
    // answer; that session's own finish resumes it.
    var holdMediaForFollowUp = false
    // Same for a chat answer that asks something back (see `listenForReplyAnswer`).
    var holdMediaForReplyAnswer = false
    /// The cloud was already asked for another way (`CommandRescue`): a failure now is final.
    var isRescue = false

    init(session: RecordingTranscriptionSession) {
        self.session = session
    }
}

extension AppState {
    /// An explicit recording must not look successful when recognition produced no usable text.
    /// Passive command follow-ups may legitimately contain only silence or playback.
    func reportUnrecognizedRecording(_ session: RecordingTranscriptionSession) async {
        session.latency.markOutput("konuşma anlaşılamadı; gönderilmedi")
        guard !session.isCancelled, !session.takesOnlyCommands else { return }
        let message = L("Anlayamadım, tekrar dene.", "I didn't catch that, try again.")
        lastError = message
        showFlowBarMessage(message, durationMs: 3000)
        owLog("[Result] Recognition failed; user notified, nothing pasted or copied")
        if session.isVoiceCommand, recordingState != .recording {
            await speakReply(message)
        }
    }

    func finishTranscription(_ session: RecordingTranscriptionSession) async {
        guard !session.hasFinished else { return }
        session.hasFinished = true
        let run = FinishRun(session: session)
        // Declared first so it runs last, once the media and recording state below are settled.
        defer { continueListening(run) }
        defer { settleMedia(run) }
        let traceID = await closeRecordingHistory(session)
        run.traceID = traceID
        defer { releaseSession(run) }

        await VoiceTrace.$current.withValue(traceID) {
            defer { session.latency.finishIfNeeded() }
            guard !session.isCancelled else { return }
            // The weak-wake check may fail after a batch was already transcribed: the video called.
            if session.segmentTexts.isEmpty, !session.playbackCommandTexts.isEmpty, !session.hadFailClosedPassthrough,
               !session.wakeUnconfirmed {
                session.segmentTexts = session.playbackCommandTexts
                session.heardOnlyOverPlayback = true
                owLog("[OpenWhisper] No batch matched your voice over the media; taking a command only")
            }
            if await settleUnverifiedSpeech(session) { return }
            guard !session.appliesSpeechChecks || session.queuedSampleCount >= 6400 else {
                owLog("[OpenWhisper] Audio too short (\(session.queuedSampleCount) samples < 0.4s)")
                return
            }

            guard let text = correctedTranscript(run) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard await acceptsTranscript(run, trimmed) else { return }

            owLog("[OpenWhisper] Raw: \(text)")
            session.latency.beginDecision()
            // Claude asked for a permission out loud: this is the answer.
            if session.trigger == .confirmation, let permission = pendingClaudePermission {
                session.latency.finishDecision(route: "Claude izin cevabı")
                await answerClaudePermission(permission, with: trimmed)
                return
            }
            correctionGeneration &+= 1
            run.generation = correctionGeneration
            run.text = text
            run.trimmed = trimmed

            await routeTranscript(run)
        }
    }

    private func continueListening(_ run: FinishRun) {
        let session = run.session
        if let app = run.conversationContinuationApp, !session.isCancelled,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
           recordingState != .recording, hotkey?.isIdle == true, microphoneGranted {
            pendingCommandFollowUp = nil
            pendingClaudeMessage = nil
            pendingWakeSpeakerVerified = session.wakeSpeakerVerified
            startVoiceSession(trigger: .jarvisKey)
        } else if let commandFollowUp = run.commandFollowUp, !run.followUpOpenedOverReply {
            if !listenAfterCommand(domain: commandFollowUp, after: session) { endScreenMode("the mic did not reopen") }
        } else if screenModeActive, !run.followUpOpenedOverReply {
            // No step this time (silence, noise, not a command): listen on until
            // `ScreenMode.silence` after the last step. Any other session ends the mode.
            if !(session.followsCommand && Date().timeIntervalSince(screenModeLastAction) < ScreenMode.silence - 1
                 && listenAfterCommand(domain: nil, after: session, keepAlive: true)) {
                endScreenMode(session.followsCommand ? "nothing for \(Int(ScreenMode.silence)) s" : "another recording")
            }
        }
    }

    private func settleMedia(_ run: FinishRun) {
        let session = run.session
        // The follow-up opened over the reply leaves media alone; this session still owns it.
        let recordingIsOwnFollowUp = run.followUpOpenedOverReply && activeTranscriptionSession?.followsCommand == true
        if session.isVoiceCommand && (recordingState != .recording || recordingIsOwnFollowUp)
            && !run.holdMediaForFollowUp && !run.holdMediaForReplyAnswer {
            recordingMedia.end(resuming: run.resumeMediaAfterCommand)
        }
    }

    private func closeRecordingHistory(_ session: RecordingTranscriptionSession) async -> UUID? {
        let recordingID = await recordingHistoryStore.activeRecordingID(sessionID: session.id)
        do {
            savedRecordings = try await recordingHistoryStore.finish(
                sessionID: session.id,
                // A command's follow-up window heard the song or video it started: never kept.
                keep: !session.isCancelled && !session.historySaveFailed && session.queuedSampleCount >= 6_400
                    && !(session.followsCommand && (session.mediaWasPlaying || session.speakersPlayed)),
                previewText: AudioSegmentation.joinTranscripts(session.segmentTexts),
                whisperSegments: session.allSegmentTexts.count,
                trigger: session.trigger
            )
        } catch {
            lastError = String(format: loc("Ses geçmişi tamamlanamadı: %@"), error.localizedDescription)
            owLog("[RecordingHistory] Finish failed: \(error)")
        }
        // Only kept recordings get a trace: it lives and is pruned next to their audio.
        let traceID = recordingID.flatMap { id in savedRecordings.contains { $0.id == id } ? id : nil }
        if let traceID {
            VoiceEventLog.shared.begin(traceID, header: [
                "Recording \(traceID.uuidString)",
                "Started: \(session.startedAt.formatted(date: .numeric, time: .standard))",
                "Source: \(session.trigger.rawValue) — \(session.trigger.title)",
                "Target app: \(session.targetApp?.bundleIdentifier ?? "unknown")",
                String(format: "Duration: %.1f s", Double(session.queuedSampleCount) / 16_000),
                "Whisper segments: \(session.allSegmentTexts)",
            ] + (savedRecordings.first { $0.id == traceID }?.stats?.logLines ?? [])
              + SpeakerBatchLog.headerLines(targetSpeakerEnabled: session.targetSpeakerEnabled, batches: session.speakerBatches))
        }
        owLog("[TargetSpeaker] finishTranscription starting for session \(session.id): targetSpeakerEnabled=\(session.targetSpeakerEnabled), acceptedSamples=\(session.acceptedTargetSpeechSamples), hadSingleSpeakerUncertain=\(session.hadSingleSpeakerUncertain), hadFailClosed=\(session.hadFailClosedPassthrough), segmentTextsCount=\(session.segmentTexts.count), unmatchedSegmentTextsCount=\(session.unmatchedSegmentTexts.count)")
        WakeClipLog.shared.finish(
            session.wakeClipID,
            outcome: session.isCancelled ? "discarded" : "transcribed",
            transcript: AudioSegmentation.joinTranscripts(session.allSegmentTexts)
        )
        return traceID
    }

    private func releaseSession(_ run: FinishRun) {
        let session = run.session
        // A re-asked confirmation (holdMediaForFollowUp) keeps its plan for the next answer.
        if session.trigger == .confirmation && !run.holdMediaForFollowUp {
            self.reminderManager?.cancelPendingDeletion()
            self.whatsAppSender.cancel()
        }
        if session.trigger == .confirmation { self.endClaudePermission(reason: "no answer") }
        // Break the session ↔ worker reference cycle once the worker has drained the
        // session's stream and the final output step is complete.
        session.task = nil
        session.speechPreview = nil
        session.previewEndpointDetector = nil
        pendingTranscriptionCount = max(0, pendingTranscriptionCount - 1)
        if transcriptionQueueTailID == session.id {
            transcriptionQueueTail = nil
            transcriptionQueueTailID = nil
        }
        if recordingState != .recording {
            recordingState = pendingTranscriptionCount > 0 ? .transcribing : .idle
        }
    }

    /// True when no batch was accepted as the user's voice and this handled what was heard.
    private func settleUnverifiedSpeech(_ session: RecordingTranscriptionSession) async -> Bool {
        if !session.hadFailClosedPassthrough && !session.heardOnlyOverPlayback &&
            (session.hadSingleSpeakerUncertain ||
             (session.hadDiarizationAttempt && session.segmentTexts.isEmpty) ||
             TargetSpeakerOutputGate.shouldSkipPostProcessing(
                 featureEnabled: session.targetSpeakerEnabled,
                 acceptedSampleCount: session.acceptedTargetSpeechSamples
             )) {
            let rawCandidateText: String = {
                let confirmationText = AudioSegmentation.joinTranscripts(session.confirmationTranscriptTexts).trimmingCharacters(in: .whitespacesAndNewlines)
                if !confirmationText.isEmpty && !confirmationText.hasPrefix("[BLANK") && !confirmationText.hasPrefix("(BLANK") {
                    return confirmationText
                }
                let unmatchedText = AudioSegmentation.joinTranscripts(session.unmatchedSegmentTexts).trimmingCharacters(in: .whitespacesAndNewlines)
                if !unmatchedText.isEmpty && !unmatchedText.hasPrefix("[BLANK") && !unmatchedText.hasPrefix("(BLANK") {
                    return unmatchedText
                }
                let allText = AudioSegmentation.joinTranscripts(session.allSegmentTexts).trimmingCharacters(in: .whitespacesAndNewlines)
                if !allText.isEmpty && !allText.hasPrefix("[BLANK") && !allText.hasPrefix("(BLANK") {
                    return allText
                }
                return ""
            }()

            // After a command the mic was open for a fix only: whatever else it heard (the
            // song just started, a TV) never reaches the clipboard or an offer.
            if session.followsCommand {
                owLog("[FollowUp] Not the user's voice after the command; ignored")
                dismissFlowBarMessage()
            } else if !rawCandidateText.isEmpty, !TargetSpeakerOutputGate.retainsRejectedCandidate(
                trigger: session.trigger, hadSingleSpeakerUncertain: session.hadSingleSpeakerUncertain
            ) {
                owLog("[FollowUp] Only other voices heard; nothing kept for confirmation")
                dismissFlowBarMessage()
            } else if !rawCandidateText.isEmpty {
                let candidateSamples = !session.ambiguousTargetSamples.isEmpty
                    ? session.ambiguousTargetSamples
                    : session.belowThresholdRejectedSamples
                let candidate = session.confirmationCandidate ?? TargetSpeakerConfirmationCandidate(
                    samples: candidateSamples,
                    windows: [],
                    internalCoherence: 0.5,
                    anchorProfileScore: 0.5,
                    separation: nil,
                    separationReason: "fallback candidate"
                )
                retainConfirmation(
                    candidate: candidate,
                    text: rawCandidateText,
                    pasteContext: session.pasteContext,
                    targetApp: session.targetApp,
                    mic: session.targetSpeakerMic
                )
                textInjector?.copyToClipboard(rawCandidateText)
                showTargetSpeakerAppendOffer(message: "")
                owLog("[OpenWhisper] Near-threshold candidate retained for 'Bu benim sesimdi' confirmation without showing error warning")
            } else if session.hadDiarizationFailure && !session.followsCommand {
                let status = L("Sesini doğrulayamadım; mesaj gönderilmedi. Fn tuşuyla tekrar deneyebilirsin.", "I couldn't verify your voice; nothing was sent. You can try again with the Fn key.")
                lastError = status
                session.latency.markOutput("konuşmacı doğrulanamadı; gönderilmedi")
                owLog("[TargetSpeaker] No output after diarization failure; notifying the user")
                showFlowBarMessage(status, durationMs: 6000)
                if session.isVoiceCommand { await speakReply(status) }
            } else {
                dismissFlowBarMessage()
            }
            return true
        }
        return false
    }

    /// The transcript after the wake word and sound-alike fixes; nil for a bare finish word.
    private func correctedTranscript(_ run: FinishRun) -> String? {
        let session = run.session
        // Mangled names ("Sputfayda" → "Spotify'da") fixed before routing, so a command is
        // still recognized; the list is the user's ses-benzerleri.txt.
        // Wake sessions now start at the wake itself, so the tail of "Jarvis" can be heard.
        let rawJoined = AudioSegmentation.joinTranscripts(session.segmentTexts)
        let joined = session.appliesSpeechChecks
            ? SpokenDoneEndpoint.removingSuffix(from: rawJoined) ?? rawJoined : rawJoined
        // A bare finish word closes the microphone without creating an empty request.
        if session.appliesSpeechChecks, joined.isEmpty,
           SpokenDoneEndpoint.removingSuffix(from: rawJoined) != nil { return nil }
        // A follow-up opened over Jarvis's reply heard the reply first, and may itself
        // start with "Hey Jarvis," (voice test 2026-10-22).
        let spoken = session.trigger == .wakeWord ? WakeWordVerifier.strippingLeadingWakeWord(joined)
            : session.followsCommand
                ? WakeWordVerifier.strippingLeadingWakeWord(JarvisEchoFilter.removingEcho(of: session.precedingReply, from: joined))
            : joined
        if spoken != joined { owLog("[WakeWord] Removed the wake word from the transcript start: \(joined)") }
        // The app in front comes first: its ses-benzerleri.txt section ("cloud" → Claude in
        // Claude), its name in app matching and in the cleanup model's terms.
        let soundAlikeEntries = SoundAlikeCorrector.loadEntries()
        let focus = AppFocus(app: session.targetApp, entries: soundAlikeEntries)
        run.focus = focus
        let (soundAlikeText, soundAlikes) = session.appliesSpeechChecks
            ? SoundAlikeCorrector.correct(spoken, entries: AppFocus.soundAlikeEntries(soundAlikeEntries, focus: focus),
                                          keeping: GlossaryStore.multiWordTerms())
            : (spoken, [])
        var text = soundAlikeText
        for (heard, written) in soundAlikes { owLog("[SoundAlike] \(heard) → \(written)") }
        // A word neither Turkish nor English that sounds like a glossary name is that name.
        if session.appliesSpeechChecks {
            let locale = Locale(identifier: "tr_TR")
            let unknown = Set(misheardWords(in: text).map { $0.text.lowercased(with: locale) })
            let glossaryFixes: [(String, String)]
            (text, glossaryFixes) = SoundAlikeCorrector.correct(text, glossary: GlossaryStore.spokenEntries()) { word in
                MisheardWordDetector.words(in: word).first.map { unknown.contains($0.lowercased(with: locale)) } ?? false
            }
            for (heard, written) in glossaryFixes { owLog("[Glossary] \(heard) → \(written)") }
        }
        return text
    }

    /// False when the transcript is blank, noise or not a language the app takes.
    private func acceptsTranscript(_ run: FinishRun, _ trimmed: String) async -> Bool {
        let session = run.session
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("[BLANK"),
              !trimmed.hasPrefix("(BLANK") else {
            owLog("[OpenWhisper] Empty/blank transcription, skipping")
            await reportUnrecognizedRecording(session)
            return false
        }
        guard !session.appliesSpeechChecks || !AudioSegmentation.isRepetitionHallucination(trimmed) else {
            owLog("[OpenWhisper] Repeated-word hallucination, skipping: \(trimmed)")
            await reportUnrecognizedRecording(session)
            return false
        }
        guard !session.appliesSpeechChecks
                || !ForeignTranscriptGuard.isForeign(trimmed, misheardCount: misheardWords(in: trimmed).count) else {
            owLog("[OpenWhisper] Not Turkish or English, nothing pasted or run: \(trimmed)")
            if session.followsCommand {
                dismissFlowBarMessage()
            } else {
                // A voice session that asks "tekrar söyler misin?" must also listen for it.
                let ask = L("Anlaşılamadı, tekrar söyler misin?", "I didn't catch that, could you say it again?")
                lastError = ask
                session.latency.markOutput("konuşma anlaşılamadı; gönderilmedi")
                if listenForReplyAnswer(ask, heard: false, after: session) {
                    run.holdMediaForReplyAnswer = true
                } else {
                    showFlowBarMessage(ask, durationMs: 8000)
                }
            }
            return false
        }
        return true
    }

    private func routeTranscript(_ run: FinishRun) async {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        // The rules decide where the transcript goes (`VoiceRouter`, in their order); this
        // runs the decision.
        if let pending = self.pendingScreenPress, pending.expiresAt <= Date() { self.pendingScreenPress = nil }
        var facts = routingFacts(run)
        if await handleBeforeRouting(run, facts: facts) { return }
        var route = session.sendsToRecappedSession.map {
            .agent(AgentDictation(target: $0, body: trimmed, send: true, session: .last))
        } ?? VoiceRouter.route(text, facts: facts)

        if await settleConfirmation(run, route: &route, facts: &facts) { return }

        if await typeIntoNamedField(run) { return }

        // Screen mode: "tamamdır", "harikasın" end it, whatever else they would route to.
        if screenModeActive, session.followsCommand, ScreenMode.isCloser(trimmed) {
            session.latency.finishDecision(route: "ekran modu, bitti")
            owLog("[ScreenMode] Closer: '\(trimmed)'")
            self.lastTranscription = text
            endScreenMode("closer")
            await say(run, self.jarvisReply.ack(), durationMs: 1500)
            return
        }

        if await handlePointerStep(run) { return }

        if await handleEditKey(run, route: route) { return }

        if await handleCommandOnlySession(run, route: &route) { return }

        // Locked: nothing can be typed into an app or done on screen. Say so instead of
        // failing silently (or typing into the lock screen); the rest runs as usual.
        if RemoteControl.needsUnlockedScreen(route), RemoteControl.screenIsLocked {
            session.latency.finishDecision(route: "Mac kilitli")
            owLog("[Route] Screen locked; not running: '\(trimmed)'")
            self.lastTranscription = text
            await say(run, self.jarvisReply.answer(RemoteControl.lockedAnswer), durationMs: 5000)
            return
        }

        await executeRoute(run, route)
    }

    private func routingFacts(_ run: FinishRun) -> VoiceRouter.Facts {
        let session = run.session
        return VoiceRouter.Facts(
            isVoiceCommand: session.isVoiceCommand,
            acceptsCommands: session.acceptsCommands,
            focus: session.routingFocus,
            hasTargetApp: session.targetApp != nil,
            targetBundleID: session.targetApp?.bundleIdentifier,
            pendingDeletion: self.reminderManager?.hasPendingDeletion ?? false,
            pendingWhatsAppSend: self.whatsAppSender.hasPending,
            pendingScreenPress: self.pendingScreenPress != nil,
            voiceTestActive: self.voiceTest.isActive,
            commandAmongPlayback: session.heardOnlyOverPlayback,
            lastDictation: self.editableDictation(in: session.targetApp),
            commandContext: { self.commandContext(run) })
    }

    private func executeRoute(_ run: FinishRun, _ route: VoiceRouter.Route) async {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        switch route {
        case .agentWithoutForeground:
            let status = L("Önde bir uygulama bulamadım; mesaj gönderilmedi.", "No app in front; nothing was sent.")
            owLog("[Agent] Send skipped: no foreground application")
            self.showFlowBarMessage(status, durationMs: 4500)
            await self.speakReply(status)

        case .agent(let agent):
            await handleAgentRoute(run, agent)
        case .dictationEdit(let edit):
            session.latency.finishDecision(route: "dikte düzeltme")
            owLog("[Route] dictation edit (\(edit))")
            let result = await runDictationEdit(edit, targetApp: session.targetApp)
            owLog("[Result] Dictation edit: \(result.status)")
            self.showFlowBarMessage(result.status, durationMs: result.done ? 1000 : 3000)
            if session.isVoiceCommand, !result.done { await self.speakReply(result.status) }

        case .typed(let typed):
            owLog("[Route] explicit dictation override: '\(typed)'")
            await pasteAsDictation(run, typed, targetApp: session.targetApp, pasteContext: session.pasteContext, send: false)
            if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: false)) }

        case .chat(let chatText):
            session.latency.finishDecision(route: "Jarvis sohbet")
            owLog("[Route] explicit Jarvis chat: '\(chatText)'")
            await chat(run, chatText, detail: "Jarvis sohbet")

        // "Günaydın", "Selam Jarvis", "Nasılsın?": answered at once by the clock, no LLM.
        case .greeting(let greeting):
            await handleGreeting(run, greeting)
        // "Ne dedin?" repeats the last reply; "Ne yapabilirsin?" lists what Jarvis does.
        case .meta(let meta):
            await handleMeta(run, meta)
        // "Bunu hatırla: …", "benim adım …", "hakkımda ne biliyorsun?", "… unut".
        case .memory(let memoryCommand):
            await handleMemory(run, memoryCommand)
        // Test mode: the next untested TODO.md item is read aloud; the answer is written back.
        case .voiceTest(let command):
            await handleVoiceTest(run, command)
        // "Geçen hafta ne demiştim?", "dün ne konuşmuştuk?": only now is the journal read,
        // and only that time's lines go to the model.
        case .pastConversation(let query):
            await handlePastConversation(run, query)
        // "Claude'da son session'ı özetle" / "Codex'te son sohbeti özetle": two sentences on
        // screen and aloud, then the mic stays open and whatever the user says goes there.
        case .agentSessionRecap(let agent):
            await handleAgentSessionRecap(run, agent)
        // "Biten sohbete geç", "yanıtı gelene geç": opens the chat whose answer came in last;
        // the mic then stays open there, so the next words are written without "Hey Jarvis".
        case .finishedAgentChat(let target):
            await handleFinishedAgentChat(run, target)
        case .deletionConfirmation, .whatsAppConfirmation, .screenPressConfirmation:
            // Answered above; a non-answer was routed again without it.
            break

        case .whatsAppSend(let outgoing):
            owLog("[Route] WhatsApp send (\(outgoing.body.isEmpty ? "open chat" : "\(outgoing.body.count) chars"))")
            session.latency.finishDecision(route: "WhatsApp mesajı")
            self.lastTranscription = text
            await sayWhatsApp(run, await self.whatsAppSender.prepare(outgoing))

        // "sesi kıs ve Bluetooth'u kapat", "Wi-Fi'yi aç, sonra 10 dakikalık alarm kur".
        case .commands(let steps):
            session.latency.finishDecision(route: "çoklu komut")
            owLog("[Route] multi-command (\(steps.count)): \(steps.map { "'\($0.text)' → \($0.command)" }.joined(separator: ", "))")
            await runCommands(run, steps, output: "çoklu komut")

        // "20 dakikalık alarm kur", "Bluetooth'u kapat", "videoyu durdur", "YouTube'da lofi
        // ara", "yarın 3'te toplantı ekle".
        case .command(.system(.clipboard(.sendWhatsApp(let name)))):
            // "Kopyaladığımı Ali'ye at": read back and sent only after "evet", like a dictated message.
            owLog("[Route] clipboard to WhatsApp")
            session.latency.finishDecision(route: "WhatsApp mesajı")
            self.lastTranscription = text
            guard let body = ClipboardHistory.shared.latest else {
                await say(run, self.jarvisReply.failure("Panoda metin yok"), durationMs: 3000)
                return
            }
            await sayWhatsApp(run, await self.whatsAppSender.prepare(WhatsAppOutgoing(recipient: name, body: body)))

        case .command(let command):
            let isTimer: Bool
            switch command {
            case .timer(let timerCommand):
                isTimer = true
                owLog("[Route] timer (\(timerCommand))")
            case .system(let systemCommand):
                isTimer = false
                owLog("[Route] system (\(systemCommand))")
            default:
                isTimer = false
                owLog("[Route] command (\(command))")
            }
            let output = isTimer ? "zamanlayıcı" : "sistem komutu"
            session.latency.finishDecision(route: output)
            await runCommands(run, [MultiCommandSplitter.Step(text: trimmed, command: command)], output: output)

        case .reminderDeletion(let reminderDeletion):
            await handleReminderDeletion(run, reminderDeletion)
        case .reminder:
            await handleReminder(run)
        case .spotifyOrConversation(let firstSentence):
            await handleSpotifyOrConversation(run, firstSentence: firstSentence)
        }
    }

    /// True when the transcript was taken before the rules got to see it.
    private func handleBeforeRouting(_ run: FinishRun, facts: VoiceRouter.Facts) async -> Bool {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        // The mic opened after a Claude / Codex recap: all of it is the message for that
        // chat, unless the user called it off ("boş ver", "vazgeç").
        if session.sendsToRecappedSession != nil, ClaudeSessionRecap.isCancel(trimmed) {
            session.latency.finishDecision(route: "Claude mesajı iptal")
            owLog("[Agent] Recap message called off: '\(trimmed)'")
            await say(run, L("Tamam, göndermedim.", "Okay, I didn't send it."), durationMs: 3000)
            return true
        }
        if session.acceptsCommands, session.sendsToRecappedSession == nil,
           !facts.pendingDeletion, !facts.pendingWhatsAppSend, !RemoteControl.screenIsLocked,
           let reply = await CloudSessionNavigation.handle(trimmed, front: session.targetApp) {
            session.latency.finishDecision(route: "sohbet geçişi")
            self.lastTranscription = text
            if reply == CloudSessionNavigation.newChatOpened || reply == CloudSessionNavigation.switchedChat, session.isVoiceCommand {
                run.conversationContinuationApp = NSWorkspace.shared.frontmostApplication
            }
            await say(run, reply, durationMs: 5000)
            return true
        }
        // After "ne yazayım?" all of it is the message, never a command or dictation.
        if self.whatsAppSender.awaitsBody, let answer = await self.whatsAppSender.handleConfirmation(trimmed) {
            session.latency.finishDecision(route: "WhatsApp mesaj metni")
            owLog("[Route] WhatsApp message body")
            self.lastTranscription = text
            await sayWhatsApp(run, answer)
            return true
        }
        return false
    }

    /// True when `route` was the answer to a pending question; otherwise routes again without it.
    private func settleConfirmation(_ run: FinishRun, route: inout VoiceRouter.Route, facts: inout VoiceRouter.Facts) async -> Bool {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        // While a deletion confirmation is pending, only an explicit approval can execute the
        // already-resolved plan; any other ordinary voice response discards it without
        // touching reminders. No answer at all (a new delete command, an expired plan):
        // the transcript is routed as usual.
        if case .deletionConfirmation = route {
            if let confirmation = await self.reminderManager?.handleDeletionConfirmation(
                trimmed, alternatives: session.heardVariants
            ) {
                session.latency.finishDecision(route: "hatırlatıcı silme onayı")
                owLog("[Route] reminder deletion confirmation")
                owLog("[Result] Reminder deletion confirmation: \(String(describing: confirmation))")
                self.lastTranscription = text
                let reply = self.jarvisReply.reminderDeletion(confirmation)
                let heard = await self.speakReply(reply)
                if confirmation == .confirmationUnclear { askFollowUp(run, reply, heard: heard) }
                return true
            }
            facts.pendingDeletion = false
            route = VoiceRouter.route(text, facts: facts)
        }

        // Only a plain yes sends the pending WhatsApp message; anything unclear is asked once
        // more, then dropped. A new message request replaces it and is routed as usual.
        if case .whatsAppConfirmation = route {
            if let answer = await self.whatsAppSender.handleConfirmation(trimmed) {
                session.latency.finishDecision(route: "WhatsApp gönderme onayı")
                owLog("[Route] WhatsApp send confirmation")
                self.lastTranscription = text
                await sayWhatsApp(run, answer)
                return true
            }
            facts.pendingWhatsAppSend = false
            route = VoiceRouter.route(text, facts: facts)
        }

        if case .screenPressConfirmation = route {
            if let pending = self.pendingScreenPress, let approved = ScreenActions.confirmation(trimmed) {
                self.pendingScreenPress = nil
                session.latency.finishDecision(route: "ekran onayı")
                owLog("[Route] screen press confirmation: \(approved)")
                self.lastTranscription = text
                guard approved else {
                    await say(run, L("Tamam, basmadım.", "Okay, I didn't press it."), durationMs: 2500)
                    return true
                }
                guard pending.expiresAt > Date(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pending.app.processIdentifier else {
                    await say(run, L("Ekran değişti, basmadım.", "The screen changed, I didn't press it."), durationMs: 3000)
                    return true
                }
                let pressed = ScreenActions.perform(pending.target)
                self.showFlowBarMessage(pressed ? "“\(pending.target.label)” ✓" : L("Basılamadı", "Couldn't press it"), durationMs: 1500)
                if !pressed { await self.speakReply(self.jarvisReply.failure(L("Basamadım", "I couldn't press it"))) }
                // A multi-step task asked it: go on from here.
                if pressed, let task = pending.task, let (client, model) = CloudLLM.client() {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    await runScreenTask(run, goal: task.goal, spoken: task.spoken, history: task.history + [ScreenTask.pressed(pending.target)],
                                        client: client, model: model)
                    return true
                }
                if pressed, session.isVoiceCommand {
                    self.noteScreenModeAction()
                    run.commandFollowUp = .some(nil)
                }
                return true
            }
            self.pendingScreenPress = nil
            facts.pendingScreenPress = false
            route = VoiceRouter.route(text, facts: facts)
        }
        return false
    }

    /// "Numaraları göster", "beş", "Kaydet'e sağ tıkla": the screen used as with
    /// a mouse. Under the same guards as a press on screen.
    private func handlePointerStep(_ run: FinishRun) async -> Bool {
        let session = run.session
        guard session.isVoiceCommand, session.acceptsCommands, !session.heardOnlyOverPlayback, !RemoteControl.screenIsLocked,
              let command = ScreenPointer.parse(run.trimmed), let app = session.targetApp, !app.isTerminated,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        owLog("[Pointer] '\(run.trimmed)' → \(command)")
        switch await runPointerCommand(command, session: session, app: app) {
        case .notHandled:
            return false
        case .step:
            self.lastTranscription = run.text
            run.commandFollowUp = .some(nil)
        case .noStep:
            self.lastTranscription = run.text
        }
        return true
    }

    /// "Kopyala", "tümünü seç", "vazgeç": what the keyboard does in any app. A command of its own
    /// or an edit of the last dictation ("geri al" right after one) goes first.
    private func handleEditKey(_ run: FinishRun, route: VoiceRouter.Route) async -> Bool {
        let session = run.session
        switch route {
        case .command, .commands, .dictationEdit, .meta, .voiceTest: return false
        default: break
        }
        guard session.isVoiceCommand, session.acceptsCommands, !session.heardOnlyOverPlayback, !RemoteControl.screenIsLocked,
              let key = EditKeys.parse(run.trimmed), let app = session.targetApp, !app.isTerminated,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        let started = CACurrentMediaTime()
        session.latency.finishDecision(route: "düzenleme tuşu")
        owLog("[Route] edit key: '\(run.trimmed)' → \(key)")
        self.lastTranscription = run.text
        self.lastCommandUndo = []
        EditKeys.press(key)
        self.logScreenStep(session, "tuş", startedAt: started, [("tuş", CACurrentMediaTime() - started)])
        self.showFlowBarMessage(EditKeys.done(key), durationMs: 1200)
        self.noteScreenModeAction()
        run.commandFollowUp = .some(nil)
        return true
    }

    private func typeIntoNamedField(_ run: FinishRun) async -> Bool {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        // "Arama kısmına kedi videoları yaz": find the field, type, search, in one step.
        if session.isVoiceCommand, session.acceptsCommands, !session.heardOnlyOverPlayback,
           let request = ScreenMode.fieldTypeRequest(trimmed), let app = session.targetApp, !app.isTerminated,
           app.bundleIdentifier != Bundle.main.bundleIdentifier,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            let started = CACurrentMediaTime()
            owLog("[ScreenMode] Type into '\(request.field)'\(request.send ? " and send" : ""): \(request.text.count) chars")
            self.lastTranscription = text
            guard await ScreenActions.focusField(named: request.field, in: app) else {
                session.latency.finishDecision(route: "alana yazma, alan bulunamadı")
                self.logScreenStep(session, "alan bulunamadı", startedAt: started, [("alan arama", CACurrentMediaTime() - started)])
                if await rescue(run, failure: L("“\(request.field)” alanını bulamadım", "I couldn't find the “\(request.field)” field")) { return true }
                await say(run, self.jarvisReply.failure(L("“\(request.field)” alanını bulamadım", "I couldn't find the “\(request.field)” field")), durationMs: 3000)
                return true
            }
            let focused = CACurrentMediaTime()
            // The click or focus needs a moment before the field takes the paste.
            try? await Task.sleep(for: .milliseconds(150))
            let delivered = await pasteAsDictation(run, request.text, targetApp: app, pasteContext: session.pasteContext,
                                                   send: request.send)
            self.logScreenStep(session, delivered ? "alana yazıldı" : "yazılamadı", startedAt: started,
                               [("alan bulma", focused - started), ("yazma", CACurrentMediaTime() - focused)])
            if delivered {
                self.noteScreenModeAction()
                run.commandFollowUp = .some(nil)
            } else {
                await say(run, self.jarvisReply.failure(L("Yazamadım", "I couldn't type it")), durationMs: 3000)
            }
            return true
        }
        return false
    }

    private func handleCommandOnlySession(_ run: FinishRun, route: inout VoiceRouter.Route) async -> Bool {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        // The mic stayed open after a command: only a command is taken from it, never
        // dictation or chat (a TV, the song's lyrics, someone else in the room). A bare
        // "sonrakine geç" is about what the command just did.
        if session.takesOnlyCommands {
            var isCommand: Bool {
                switch route { case .command, .commands: true; default: false }
            }
            if !isCommand, let domain = session.commandFollowUpDomain,
               let fix = CommandFollowUp.resolve(trimmed, after: domain, listed: YouTubeList.listed) {
                owLog("[FollowUp] '\(trimmed)' after a \(domain.rawValue) command → \(fix)")
                route = .command(fix)
            }
            switch route {
            // Spotify asks the models ("biraz rock bir şey aç"); its dictation and chat
            // fallback is dropped in `dictateOrChat`.
            case .command, .commands, .meta, .voiceTest, .spotifyOrConversation: break
            default:
                // Screen mode: not a command, so a step on screen ("… yaz", "şuna bas").
                if screenModeActive, session.followsCommand, !session.heardOnlyOverPlayback {
                    if let typing = ScreenMode.typeRequest(trimmed) {
                        owLog("[ScreenMode] Type\(typing.send ? " and send" : ""): \(typing.text.count) chars")
                        self.lastTranscription = text
                        let typeStarted = CACurrentMediaTime()
                        let delivered = await pasteAsDictation(run, typing.text, targetApp: session.targetApp,
                                                               pasteContext: session.pasteContext, send: typing.send)
                        self.logScreenStep(session, delivered ? (typing.send ? "yazıldı, gönderildi" : "yazıldı") : "yazılamadı",
                                           startedAt: typeStarted, [("yazma", CACurrentMediaTime() - typeStarted)])
                        if delivered, typing.send {
                            endScreenMode("sent")
                            await say(run, self.jarvisReply.agent(sent: true), durationMs: 1500)
                        } else if delivered {
                            self.noteScreenModeAction()
                            run.commandFollowUp = .some(nil)
                        } else {
                            await say(run, self.jarvisReply.failure(L("Yazamadım", "I couldn't type it")), durationMs: 3000)
                        }
                        return true
                    }
                    if await screenAction(run) { return true }
                } else if session.followsCommand, !session.heardOnlyOverPlayback, ScreenActions.saysClick(trimmed) {
                    // "Kapatma butonuna bas" right after a command: said outright, so it counts.
                    if await screenAction(run) { return true }
                }
                owLog("[FollowUp] No command after the command; ignored: '\(trimmed)'")
                session.latency.finishDecision(route: "komut sonrası, komut değil")
                dismissFlowBarMessage()
                return true
            }
        }
        return false
    }

    private func handleAgentRoute(_ run: FinishRun, _ agent: AgentDictation) async {
        let session = run.session
        owLog("[Route] agent (\(agent.target?.displayName ?? "frontmost app"), send: \(agent.send), session: \(agent.session.rawValue))")
        // "Claude Code'da yeni session aç" / "Bitirme projesine geç" alone just open it.
        guard !agent.body.isEmpty || agent.session == .new || agent.project != nil else {
            owLog("[Agent] Nothing to write after the command words, skipping")
            return
        }
        @MainActor func fail(_ status: String, spoken: String) async {
            if !agent.body.isEmpty { self.textInjector?.copyToClipboard(agent.body) }
            self.showFlowBarMessage(agent.body.isEmpty ? status : status + L(", panoya kopyalandı", ", copied to the clipboard"), durationMs: 4500)
            if session.isVoiceCommand { await self.speakReply(self.jarvisReply.failure(spoken)) }
        }
        @MainActor func jarvisChangesScreen() {
            guard agent.send, !agent.body.isEmpty else { return }
            run.jarvisChangedScreen = true
            self.showFlowBarMessage(L("Jarvis ekranı değiştirdi, bekleyin", "Jarvis changed the screen, please wait"), durationMs: 8000)
        }
        if let project = agent.project {
            jarvisChangesScreen()
            switch await AgentProjectNavigator.open(project, target: agent.target ?? .claudeCode,
                                                    assumed: agent.targetAssumed, newSession: agent.session == .new) {
            case .failed(let status, let spoken):
                await fail(status, spoken: spoken)
            case .opened(let app, let projectAgent, let found, let isNew):
                guard !agent.body.isEmpty else {
                    if session.isVoiceCommand { run.conversationContinuationApp = app }
                    if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agentProject(found.name, isNew: isNew)) }
                    return
                }
                let delivered = await pasteAsDictation(run, agent.body, targetApp: app, pasteContext: PasteContext.capture(targetApp: app), send: agent.send)
                guard delivered else {
                    owLog("[Agent] Not delivered to \(found.name) in \(projectAgent.displayName); not reporting success")
                    await fail(agent.send ? L("Mesaj gönderilemedi", "Couldn't send the message") : L("Mesaj yazılamadı", "Couldn't write the message"),
                               spoken: agent.send ? L("mesajı gönderemedim", "I couldn't send the message") : L("mesajı yazamadım", "I couldn't write the message"))
                    return
                }
                if agent.send, projectAgent == .claudeCode { ClaudeSessionNavigator.rememberSession(app, wasNew: isNew) }
                if agent.send, projectAgent != .claudeCode { CodexSessionNavigator.rememberThread(shownIn: app) }
                if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: agent.send)) }
            }
            return
        }
        // Spoken "son session'a …": the chat whose answer came in last, also one written to
        // by hand. After a recap the recapped session stays the target.
        if agent.session == .last, session.sendsToRecappedSession == nil, let target = agent.target {
            let chats = await Task.detached { AgentFinishedChat.load(target) }.value
            if let chat = AgentFinishedChat.newest(chats, excluding: nil) {
                owLog("[Agent] Last session → \"\(chat.title)\" (finished \(chat.finishedAt))")
                if target == .claudeCode {
                    ClaudeSessionNavigator.rememberSession(id: chat.id, title: chat.title)
                } else {
                    CodexSessionNavigator.rememberThread(id: chat.id, title: chat.title)
                }
            }
        }
        if agent.session == .last, agent.target != .claudeCode, CodexSessionNavigator.lastThread == nil {
            await fail("Son sohbeti bilmiyorum", spoken: "son sohbeti bilmiyorum")
            return
        }
        var targetApp = session.targetApp
        var pasteContext = session.pasteContext
        if let target = agent.target,
           !(targetApp?.bundleIdentifier.map(target.bundleIdentifiers.contains) ?? false)
            || agent.session != .current {
            jarvisChangesScreen()
            guard let app = await AgentAppActivator.activate(target) else {
                await fail(L("\(target.displayName) açılamadı", "Couldn't open \(target.displayName)"), spoken: L("\(target.displayName) açılamadı", "Couldn't open \(target.displayName)"))
                return
            }
            targetApp = app
            pasteContext = PasteContext.capture(targetApp: app)
        }
        // Never fall back to whatever session happens to be open: a message meant
        // for a new or earlier conversation would land in the wrong one.
        if agent.session != .current, let app = targetApp {
            let switched: Bool
            switch agent.session {
            case .new:
                switched = agent.target == .claudeCode
                    ? await ClaudeSessionNavigator.openNewSession(app)
                    : await CodexSessionNavigator.openNewThread(app, folder: nil)
            case .last where agent.target != .claudeCode:
                let thread = CodexSessionNavigator.lastThread!
                switched = await CodexSessionNavigator.openThread(app, id: thread.id, title: thread.title)
            case .last:
                guard let name = ClaudeSessionNavigator.lastSessionTitle else {
                    await fail(L("Son session'ı bilmiyorum", "I don't know the last session"), spoken: L("son session'ı bilmiyorum", "I don't know the last session"))
                    return
                }
                switched = if let id = ClaudeSessionNavigator.lastSessionID {
                    await ClaudeSessionNavigator.openSession(app, id: id, title: name)
                } else {
                    await ClaudeSessionNavigator.selectSession(app, titled: name)
                }
            case .current:
                switched = true
            }
            guard switched else {
                let what = agent.session == .new ? L("Yeni session açılamadı", "Couldn't open a new session") : L("Son session bulunamadı", "Last session not found")
                await fail(what, spoken: what.lowercased(with: Locale(identifier: "tr_TR")))
                return
            }
            pasteContext = PasteContext.capture(targetApp: app)
            if agent.body.isEmpty {
                if agent.session == .new, session.isVoiceCommand { run.conversationContinuationApp = app }
                if session.isVoiceCommand { await self.speakReply(self.jarvisReply.newAgentSession()) }
                return
            }
        }
        let delivered = await pasteAsDictation(run, agent.body, targetApp: targetApp, pasteContext: pasteContext, send: agent.send)
        guard delivered else {
            owLog("[Agent] Not delivered to \(targetApp?.localizedName ?? "?"); not reporting success")
            await fail(run.agentDeliveryFailure ?? (agent.send ? L("Mesaj gönderilemedi", "Couldn't send the message") : L("Mesaj yazılamadı", "Couldn't write the message")),
                       spoken: run.agentDeliveryFailure ?? (agent.send ? L("mesajı gönderemedim", "I couldn't send the message") : L("mesajı yazamadım", "I couldn't write the message")))
            return
        }
        if agent.send, let app = targetApp,
           app.bundleIdentifier.map(AgentApp.claudeCode.bundleIdentifiers.contains) ?? false {
            ClaudeSessionNavigator.rememberSession(app, wasNew: agent.session == .new)
        } else if agent.send, let app = targetApp,
                  app.bundleIdentifier.map(AgentApp.codex.bundleIdentifiers.contains) ?? false {
            CodexSessionNavigator.rememberThread(shownIn: app)
        }
        if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: agent.send)) }

    }

    private func handleGreeting(_ run: FinishRun, _ greeting: JarvisReply.Greeting) async {
        let session = run.session
        let text = run.text
        session.latency.finishDecision(route: "selamlama")
        owLog("[Route] greeting (\(greeting))")
        self.lastTranscription = text
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        var reply = self.jarvisReply.greet(greeting, hour: hour)
        // The first "günaydın" / "selam" of the morning brings the day's summary.
        let today = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        if [.goodMorning, .hello, .howAreYou].contains(greeting), (5..<12).contains(hour),
           UserDefaults.standard.double(forKey: "jarvisLastMorningBriefing") != today,
           let summary = await JarvisContext.withTimeout(.seconds(3), { await DailyBriefing.build(dayOffset: 0, now: now) }) {
            UserDefaults.standard.set(today, forKey: "jarvisLastMorningBriefing")
            reply = reply.replacingOccurrences(of: " Nasıl yardımcı olabilirim?", with: "")
                .replacingOccurrences(of: " Emrinizdeyim.", with: "")
                .replacingOccurrences(of: " Buradayım.", with: "")
                .replacingOccurrences(of: " How can I help?", with: "")
                .replacingOccurrences(of: " At your service.", with: "")
                .replacingOccurrences(of: " I'm here.", with: "")
                + " " + summary.morningLine(now: now)
            owLog("[Briefing] Morning: \(summary.headline)")
        }
        await say(run, reply, durationMs: 6000)

    }

    private func handleMeta(_ run: FinishRun, _ meta: JarvisReply.Meta) async {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        session.latency.finishDecision(route: "Jarvis hakkında")
        owLog("[Route] meta (\(meta))")
        let heard = self.lastTranscription
        let reply: String
        switch meta {
        case .repeatLast: reply = self.lastSpokenReply ?? L("Henüz bir şey söylemedim.", "I haven't said anything yet.")
        case .help: reply = JarvisReply.helpText
        case .whatCanISay:
            reply = JarvisReply.whatCanISay(frontBundleID: session.targetApp?.bundleIdentifier,
                                            inTextField: session.routingFocus == .editable)
        case .whatDidYouHear:
            // Not a transcript of its own: asked twice, it still reads the request before.
            reply = heard.isEmpty ? L("Henüz bir şey duymadım.", "I haven't heard anything yet.") : L("“\(heard)” diye duydum.", "I heard “\(heard)”.")
            await say(run, reply, durationMs: 8000)
            return
        case .undoLastCommand:
            self.lastTranscription = text
            let undo = self.lastCommandUndo
            guard !undo.isEmpty else {
                await say(run, L("Geri alabileceğim bir komut yok.", "There is no command I can undo."), durationMs: 3000)
                return
            }
            owLog("[Route] undo last command: \(undo)")
            await runCommands(run, undo.map { MultiCommandSplitter.Step(text: trimmed, command: $0) }, output: "komut geri alma")
            return
        }
        self.lastTranscription = text
        await say(run, reply, durationMs: 8000)

    }

    private func handleMemory(_ run: FinishRun, _ memoryCommand: UserMemoryCommand) async {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        session.latency.finishDecision(route: "kişisel hafıza")
        owLog("[Route] memory (\(memoryCommand))")
        self.lastTranscription = text
        let memory = UserMemory.shared
        var removed = 0
        switch memoryCommand {
        case .remember(let fact): memory.remember(fact)
        case .recall: break
        case .forget(let topic): removed = memory.forget(topic)
        case .forgetLast: removed = memory.forgetLast() == nil ? 0 : 1
        case .forgetAll: removed = memory.facts.count; memory.forgetAll()
        }
        let reply = self.jarvisReply.memory(memoryCommand, facts: memory.facts.map(\.text), removed: removed)
        JarvisJournal.shared.append(user: trimmed, reply: reply)
        await say(run, reply, durationMs: 5000)

    }

    private func handleVoiceTest(_ run: FinishRun, _ command: VoiceTestCommand) async {
        let session = run.session
        let text = run.text
        session.latency.finishDecision(route: "test modu")
        owLog("[Route] voice test (\(command))")
        self.lastTranscription = text
        let outcome: VoiceTestOutcome
        switch command {
        case .start: outcome = self.voiceTest.start()
        case .passed: outcome = self.voiceTest.pass()
        case .failed(let note): outcome = self.voiceTest.fail(note: note)
        case .skip: outcome = self.voiceTest.skip()
        case .repeatItem:
            outcome = self.voiceTest.current.map { .next($0, remaining: 0) } ?? self.voiceTest.start()
        case .stop: outcome = self.voiceTest.stop()
        }
        let reply = self.jarvisReply.voiceTest(command, outcome: outcome)
        if case .next = outcome { self.showFlowBarMessage(reply, durationMs: 12000) }
        await say(run, reply, durationMs: 8000)

    }

    private func handlePastConversation(_ run: FinishRun, _ query: TimeQuery) async {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        session.latency.finishDecision(route: "geçmiş sohbet")
        self.lastTranscription = text
        let recalled = JarvisJournal.shared.recall(query, facts: UserMemory.shared.facts)
        owLog("[Route] memory-time (\(query.label), \(recalled.count) line(s))")
        guard !recalled.isEmpty else {
            await say(run, self.jarvisReply.nothingRecalled(query.label), durationMs: 5000)
            return
        }
        await chat(run, trimmed, recalled: recalled, detail: "geçmiş sohbet")

    }

    private func handleAgentSessionRecap(_ run: FinishRun, _ agent: AgentApp) async {
        let session = run.session
        let text = run.text
        session.latency.finishDecision(route: "\(agent.displayName) oturum özeti")
        self.lastTranscription = text
        let recapped: (id: String, title: String, storedRecap: String?, lastMessage: String?)?
        if agent == .claudeCode {
            recapped = await Task.detached { () -> (String, String, String?, String?)? in
                guard let found = ClaudeSessionRecap.recapSession() else { return nil }
                return (found.id, found.title, found.storedRecap,
                        found.transcriptID.flatMap(ClaudeSessionRecap.lastAssistantText(transcriptID:)))
            }.value.map { (id: $0.0, title: $0.1, storedRecap: $0.2, lastMessage: $0.3) }
        } else {
            recapped = await Task.detached { ClaudeSessionRecap.codexRecapChat() }.value
                .map { (id: $0.chat.id, title: $0.chat.title, storedRecap: nil, lastMessage: $0.lastMessage) }
        }
        guard let recapped else {
            owLog("[Agent] \(agent.displayName) recap: no session found")
            await say(run, L("\(agent.locative) cevabı gelmiş bir sohbet bulamadım.", "I found no answered chat in \(agent.displayName)."), durationMs: 4000)
            return
        }
        owLog("[Route] \(agent.displayName) recap of \"\(recapped.title)\" (stored recap: \(recapped.storedRecap != nil))")
        self.jarvisActivity = .thinking
        let summary = await ClaudeSessionRecap.summary(
            title: recapped.title, storedRecap: recapped.storedRecap, lastMessage: recapped.lastMessage,
            appName: agent == .claudeCode ? "Claude Code" : "Codex",
            ollamaModel: self.ollamaModel, ollamaAvailable: self.ollamaAvailable)
        self.jarvisActivity = .none
        guard let summary else {
            await say(run, L("\(recapped.title) oturumunda özetlenecek bir şey bulamadım.", "I found nothing to summarize in \(recapped.title)."), durationMs: 4000)
            return
        }
        if agent == .claudeCode {
            ClaudeSessionNavigator.rememberSession(id: recapped.id, title: recapped.title)
        } else {
            CodexSessionNavigator.rememberThread(id: recapped.id, title: recapped.title)
        }
        self.showFlowBarMessage(summary, durationMs: Self.flowBarDuration(ofRecap: summary))
        await self.speakReply(summary)
        if self.listenForClaudeMessage(summary, agent: agent == .claudeCode ? .claudeCode : .codex, after: session) {
            run.holdMediaForReplyAnswer = true
        }

    }

    private func handleFinishedAgentChat(_ run: FinishRun, _ target: AgentApp?) async {
        let session = run.session
        let text = run.text
        session.latency.finishDecision(route: "biten sohbete geçiş")
        self.lastTranscription = text
        guard !RemoteControl.screenIsLocked else {
            await say(run, RemoteControl.lockedAnswer + ".", durationMs: 4000)
            return
        }
        let agents: [AgentApp] = target.map { [$0 == .claudeCode ? .claudeCode : .codex] } ?? [.claudeCode, .codex]
        let current = session.targetApp.flatMap { RecordedConversation.capture(app: $0) }?.sessionID
        let chats = await Task.detached { agents.flatMap(AgentFinishedChat.load) }.value
        guard let chat = AgentFinishedChat.newest(chats, excluding: current) else {
            owLog("[Agent] Finished chat: none in \(agents.map(\.displayName))")
            await say(run, L("Cevabı gelmiş başka bir sohbet bulamadım.", "I found no other answered chat."), durationMs: 4000)
            return
        }
        owLog("[Route] finished chat → \(chat.agent.displayName) \"\(chat.title)\" (finished \(chat.finishedAt))")
        guard let app = await AgentAppActivator.activate(chat.agent) else {
            await say(run, self.jarvisReply.failure(L("\(chat.agent.displayName) açılamadı", "Couldn't open \(chat.agent.displayName)")), durationMs: 4000)
            return
        }
        let navigated = chat.agent == .claudeCode
            ? await ClaudeSessionNavigator.openSession(app, id: chat.id, title: chat.title)
            : await CodexSessionNavigator.openThread(app, id: chat.id, title: chat.title)
        // A changed title is not proof: the open mic must never write into another chat.
        guard navigated, RecordedConversation.capture(app: app)?.sessionID == chat.id else {
            owLog("[Agent] Finished chat: could not verify \"\(chat.title)\" opened")
            await say(run, L("Sohbetin açıldığını doğrulayamadım.", "I couldn't confirm the chat opened."), durationMs: 4000)
            return
        }
        if session.isVoiceCommand { run.conversationContinuationApp = app }
        await say(run, self.jarvisReply.finishedChat(chat.title), durationMs: 4000)

    }

    private func handleReminderDeletion(_ run: FinishRun, _ reminderDeletion: ReminderManager.DeletionRequest) async {
        let session = run.session
        let text = run.text
        owLog("[Route] reminder deletion")
        session.latency.finishDecision(route: "hatırlatıcı silme")
        owLog("[OpenWhisper] Reminder deletion detected: \(text)")
        self.lastTranscription = text
        let actionStartedAt = session.latency.timestamp()
        let result = await self.reminderManager?.beginDeletion(reminderDeletion) ?? .failed
        session.latency.record(.action, since: actionStartedAt, detail: "hatırlatıcı silme")
        session.latency.markOutput("hatırlatıcı silme sonucu")
        owLog("[Result] Reminder deletion request: \(String(describing: result))")
        let prompt = self.jarvisReply.reminderDeletion(result)
        let promptWasHeard = await self.speakReply(prompt)
        if case .confirmationRequired = result { askFollowUp(run, prompt, heard: promptWasHeard) }

    }

    private func handleSpotifyOrConversation(_ run: FinishRun, firstSentence: String?) async {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        let generation = run.generation
        // "Yarına takvim etkinliği ekle saat 13'e": SetFit decides, no rule.
        if session.acceptsCommands, let request = await self.calendarEventRequest(text) {
            switch request {
            case .event(let event):
                owLog("[Route] calendar (SetFit)")
                session.latency.finishDecision(route: "takvim")
                await runCommands(run, [MultiCommandSplitter.Step(text: trimmed, command: .system(.calendarEvent(event)))],
                                  output: "takvim")
            case .needsDate:
                owLog("[Route] calendar (SetFit) without a day or time")
                session.latency.finishDecision(route: "takvim, tarih yok")
                await say(run, L("Ne zaman ekleyeyim? Günüyle birlikte tekrar söyler misin?", "When should I add it? Could you say it again with the day?"), durationMs: 6000)
            }
            return
        }
        var commandText = text
        var isSpotifyCommand = await SpotifyManager.isSpotifyCommand(
            text, ollamaAvailable: self.ollamaAvailable, commandMode: session.acceptsCommands
        )
        if !isSpotifyCommand, let firstSentence,
           await SpotifyManager.isSpotifyCommand(firstSentence, ollamaAvailable: self.ollamaAvailable, commandMode: true) {
            owLog("[Route] first sentence is the command: '\(firstSentence)'")
            commandText = firstSentence
            isSpotifyCommand = true
        }
        owLog("[Route] \(isSpotifyCommand ? "spotify" : "dictation")")
        guard isSpotifyCommand else {
            // After Spotify: "Tarkan çal" must not pick a row that says Tarkan.
            if await screenAction(run) { return }
            await dictateOrChat(run)
            return
        }
        session.latency.finishDecision(route: "Spotify")
        owLog("[OpenWhisper] Spotify command detected: \(commandText)")
        let resumesMedia = SpotifyManager.resumesPausedMedia(afterCommand: commandText)
        let likedSongs = SpotifyManager.playsLikedSongs(afterCommand: commandText)
        let speaksResult = SpotifyManager.speaksResult(afterCommand: commandText)
        let speaksFailure = SpotifyManager.speaksFailure(afterCommand: commandText)
        let misheard = self.cleanupAvailable ? self.misheardWords(in: commandText) : []
        let actionStartedAt = session.latency.timestamp()
        // "Sesi kıs": the ack is said at the old level, then the volume goes down.
        SystemVolume.defersLowering = session.isVoiceCommand && self.voiceRepliesEnabled
        let handled = await SpotifyManager.shared.handleCommand(
            text: commandText, targetApp: session.targetApp, recordUndo: !misheard.isEmpty
        )
        SystemVolume.defersLowering = false
        defer { SystemVolume.applyPendingLowering() }
        session.latency.record(.action, since: actionStartedAt, detail: "Spotify")
        let resultMessage = SpotifyManager.shared.takeResultMessage(for: commandText)
        if handled { session.latency.markOutput("Spotify komutu tamamlandı") }
        owLog("[Result] Spotify command \(handled ? "handled" : "not applied")")
        guard handled else {
            // Clearly a command, so typing it out would only hide that nothing plays.
            if speaksFailure {
                owLog("[OpenWhisper] Spotify command failed: \(resultMessage ?? "?")")
                if session.isVoiceCommand {
                    await speakAfterCommand(run, self.jarvisReply.failure(resultMessage ?? L("Spotify komutunu uygulayamadım", "I couldn't apply the Spotify command")))
                }
                return
            }
            owLog("[OpenWhisper] Spotify command not applied, falling back to dictation")
            await dictateOrChat(run)
            return
        }
        run.resumeMediaAfterCommand = resumesMedia
        run.commandFollowUp = .some(.music)
        self.lastTranscription = text
        // Never "şarkı çalınıyor": only a short ack, spoken before the music resumes.
        // Questions ("sıradaki şarkı ne") and timers get their answer instead.
        if session.isVoiceCommand {
            let answer = speaksResult ? resultMessage.map { self.jarvisReply.spotifyResult($0) } : nil
            await speakAfterCommand(run, answer ?? self.jarvisReply.spotify(handled: true, likedSongs: likedSongs))
        }
        if !misheard.isEmpty {
            owLog("[Misheard] Not Turkish or English: \(misheard.map(\.text)); checking the command again")
            Task { @MainActor [weak self] in
                await self?.rerunCorrectedCommand(
                    commandText, misheard: misheard, generation: generation, session: session
                )
            }
        }
    }

    private func handleReminder(_ run: FinishRun) async {
        let session = run.session
        let text = run.text
        owLog("[Route] reminder")
        session.latency.finishDecision(route: "hatırlatıcı")
        owLog("[OpenWhisper] Reminder detected: \(text)")
        self.lastTranscription = text
        // The deterministic parser handles most phrasings; Ollama is only its fallback.
        let actionStartedAt = session.latency.timestamp()
        let reminder = await self.reminderManager?.handleReminder(text: text)
        session.latency.record(.action, since: actionStartedAt, detail: "hatırlatıcı")
        session.latency.markOutput(reminder != nil ? "hatırlatıcı kuruldu" : "hatırlatıcı kurulamadı")
        owLog("[Result] Reminder \(reminder != nil ? "scheduled" : "not scheduled")")
        if reminder == nil, !self.ollamaAvailable {
            owLog("[OpenWhisper] Reminder not understood and Ollama is not available")
        }
        if session.isVoiceCommand {
            await self.speakReply(self.jarvisReply.reminder(at: reminder.map { TimerManager.clock($0.fireDate, sayDay: true) }))
        }

    }

    /// Pastes `rawText` (after learned/phonetic corrections) into `targetApp`. With
    /// `send`, presses Return once the paste landed, for coding agents: the text is
    /// then gone from the field, so the swap, snapshot and LLM cleanup steps are skipped.
    @MainActor
    /// True once the text is in the target, and, with `send`, Return went to it.
    @discardableResult
    private func pasteAsDictation(
        _ run: FinishRun,
        _ rawText: String,
        targetApp: NSRunningApplication?,
        pasteContext: PasteContext,
        send: Bool
    ) async -> Bool {
        let session = run.session
        var pasteContext = pasteContext
        run.agentDeliveryFailure = nil
        // Never type into the lock screen.
        guard !RemoteControl.screenIsLocked else {
            owLog("[Result] Screen locked; nothing pasted")
            session.latency.finishDecision(route: "Mac kilitli")
            await self.speakReply(self.jarvisReply.answer(RemoteControl.lockedAnswer))
            return false
        }
        session.latency.finishDecision(route: send ? "agent yazma" : "dikte")
        let preprocessingStartedAt = session.latency.timestamp()
        let prepared = applyLocalCorrections(rawText)
        var initialText = prepared.text
        let appliedCorrectionPairs = prepared.appliedPairs
        let laughterWasRandomized = prepared.laughterWasRandomized

        initialText = await self.formatTurkishDictation(initialText)
        initialText = TranscriptSanitizer.removeForbiddenArtifacts(from: initialText)
        session.latency.record(.preprocessing, since: preprocessingStartedAt)
        guard !initialText.isEmpty else {
            owLog("[OpenWhisper] Forbidden-only transcript blocked before output")
            return false
        }
        self.lastTranscription = initialText
        let misheard = self.misheardWords(in: initialText)
        if !misheard.isEmpty {
            owLog("[Misheard] Not Turkish or English: \(misheard.map(\.text))")
        }

        // Until Return is pressed the screen must stay put: say so on the Flow bar, and
        // the moment the user moves to another app, tell them the message may not go.
        var watchesScreen = self.autoPasteEnabled && send
        let screenWatch = watchesScreen ? watchForScreenChange(targetApp: targetApp, isWatching: { watchesScreen }) : nil
        defer {
            watchesScreen = false
            if let screenWatch { NSWorkspace.shared.notificationCenter.removeObserver(screenWatch) }
        }
        if watchesScreen, !run.jarvisChangedScreen {
            self.showFlowBarMessage(L("Gönderiyorum, ekranı değiştirmeyin", "Sending, don't change the screen"), durationMs: 8000)
        }

        // Claude still shows the recorded chat behind another app: send it there
        // without switching screens. Anything else takes the hop below.
        if self.autoPasteEnabled, send, let target = targetApp, !target.isTerminated,
           target.bundleIdentifier.map(AgentApp.claudeCode.bundleIdentifiers.contains) ?? false,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processIdentifier,
           let conversation = pasteContext.conversation,
           conversation.isCurrent(in: target) || { owLog("[Agent] Claude: background send skipped (another chat is shown)"); return false }(),
           let sent = await ClaudeSessionNavigator.sendInBackground(target, window: conversation.window, text: initialText) {
            // Once Send was pressed there is no retry: it could post the message twice.
            watchesScreen = false
            noteBackgroundSend(run, sent: sent)
            return sent
        }

        // Return can only be pressed in the frontmost app. If the user moved to another
        // app (or full-screen Space) after "gönder", hop to the target, send there, and
        // go straight back to where they were.
        let hopFrom = await hopToSendTarget(run, targetApp: targetApp, send: send)
        // Remember the conversation visible immediately before the delivery hop,
        // independently of the conversation captured when recording started.
        let deliveryConversation = pasteContext.conversation
        let previousConversation: RecordedConversation?
        if self.autoPasteEnabled, send, let app = targetApp,
           let destination = deliveryConversation,
           let visible = RecordedConversation.capture(app: app),
           visible.sessionID != destination.sessionID {
            previousConversation = visible
        } else {
            previousConversation = nil
        }
        let returnToApp = hopFrom
        @MainActor func goBack() {
            Task { @MainActor in
                // Do not overwrite a new navigation the user made during delivery.
                if let app = targetApp, let previous = previousConversation,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                   deliveryConversation?.isCurrent(in: app) == true {
                    let restored = await previous.restore(in: app)
                    owLog("[Agent] Returned to pre-delivery conversation: \(restored)")
                }
                if let app = returnToApp {
                    _ = await AgentAppActivator.bringToFront(app)
                }
            }
        }

        if self.autoPasteEnabled, RecordedConversation.requiresBinding(pasteContext.bundleIdentifier) {
            if previousConversation != nil {
                self.showFlowBarMessage(L("Jarvis sohbeti değiştirdi, bekleyin", "Jarvis changed the chat, please wait"), durationMs: 8000)
            }
            guard let app = targetApp, let conversation = pasteContext.conversation,
                  await conversation.restore(in: app) else {
                noteDeliveryBlocked(run, text: initialText, hadConversation: pasteContext.conversation != nil)
                goBack()
                return false
            }
            // The old composer may have been destroyed while another chat was open.
            pasteContext = PasteContext.capture(targetApp: app)
            pasteContext.conversation = conversation
        }

        // Opening another chat in the same app is no app switch: watch the chat title.
        var chatWatch: Task<Void, Never>?
        if watchesScreen, let app = targetApp, let conversation = pasteContext.conversation,
           let shown = conversation.shownTitle(in: app) {
            chatWatch = watchForChatChange(in: app, conversation: conversation, shown: shown, isWatching: { watchesScreen })
        }
        defer { chatWatch?.cancel() }

        if self.autoPasteEnabled {
            return await pasteAndWait(
                run, rawText: rawText, text: initialText, targetApp: targetApp, pasteContext: pasteContext, send: send,
                misheard: misheard, appliedPairs: appliedCorrectionPairs, laughterWasRandomized: laughterWasRandomized,
                stopWatching: { watchesScreen = false }, goBack: goBack
            )
        } else {
            self.textInjector?.copyToClipboard(initialText)
            owLog("[Result] Auto-paste off, copied to clipboard: '\(initialText)'")
            session.latency.markOutput("panoya kopyalandı")
            return false
        }
    }

    /// Pastes the text and returns once it is in the target, and, with `send`, Return went to it.
    private func pasteAndWait(
        _ run: FinishRun,
        rawText: String,
        text initialText: String,
        targetApp: NSRunningApplication?,
        pasteContext: PasteContext,
        send: Bool,
        misheard: [MisheardWordDetector.Word],
        appliedPairs appliedCorrectionPairs: [(wrong: String, right: String)],
        laughterWasRandomized: Bool,
        stopWatching: @escaping @MainActor () -> Void,
        goBack: @escaping @MainActor () -> Void
    ) async -> Bool {
        let session = run.session
        let pasteStartedAt = session.latency.timestamp()
        session.latency.expectAsyncOutput()
        guard let textInjector = self.textInjector else {
            session.latency.markOutput("metin enjektörü kullanılamıyor")
            return false
        }
        // Resumed once the paste (and, with `send`, the Return) is done, so a
        // spoken "Gönderdim" never runs ahead of the real send.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        var finished = false
        @MainActor func finish(_ delivered: Bool) {
            guard !finished else { return }
            finished = true
            continuation.resume(returning: delivered)
        }
        // Step 1: Paste raw/corrected text INSTANTLY (3-second path)
        textInjector.pasteTextResult(
            initialText,
            targetApp: targetApp,
            context: pasteContext
        ) { [weak self] outcome in
            // The paste callback runs outside the task: re-bind the trace so the
            // cleanup below (and everything it logs) still lands in it.
            Task { @MainActor in VoiceTrace.$current.withValue(run.traceID) {
                guard let self else { return }
                session.latency.record(.paste, since: pasteStartedAt, detail: "\(outcome)")
                session.latency.markOutput("\(outcome)")
                owLog("[Result] Paste into \(targetApp?.bundleIdentifier ?? "unknown"): \(outcome) — '\(initialText)'")
                switch outcome {
                case .pastedVerified where send, .pastedUnverified where send:
                    self.lastInjectedText = ""
                    self.swapPair = nil
                    self.swapPasteContext = nil
                    self.hotkey?.setSwapAvailable(false)
                    // Electron composers and CLI bracketed paste need a moment to
                    // take the paste before Return, or only part of it is sent.
                    // Claude's composer is watched for the pasted text below instead.
                    let isClaude = targetApp?.bundleIdentifier.map(AgentApp.claudeCode.bundleIdentifiers.contains) ?? false
                    self.pressReturnAfterPaste(
                        run, text: initialText, targetApp: targetApp, pasteContext: pasteContext, delay: isClaude ? 0.05 : 0.25,
                        stopWatching: stopWatching, finish: finish, goBack: goBack
                    )
                case .pastedVerified, .pastedUnverified:
                    self.swapPair = DictationPair(raw: rawText, cleaned: initialText)
                    self.swapTargetApp = targetApp
                    self.swapPasteContext = pasteContext.contextForInjectedText(initialText)
                    self.lastInjectedIsCleaned = initialText != rawText
                    self.lastInjectedText = initialText
                    self.hotkey?.setSwapAvailable(true)
                    DictationSnapshot.shared.capture(
                        pastedText: initialText,
                        targetApp: targetApp,
                        appliedPairs: appliedCorrectionPairs
                    )

                    self.dismissFlowBarMessage()
                    finish(true)

                    // Step 2: Run LLM Cleanup asynchronously in background (7-second path).
                    // Once Ollama finishes, replace the initially pasted text in-place.
                    // Keep the generated keyboard random exact. LLM cleanup can rewrite
                    // or remove a random-looking token, which would defeat this setting.
                    if self.llmCleanupEnabled && self.cleanupAvailable && !laughterWasRandomized {
                        self.cleanUpPastedText(
                            run, initialText, rawText: rawText, targetApp: targetApp,
                            misheard: misheard, appliedPairs: appliedCorrectionPairs
                        )
                    }
                case .clipboardOnly(let reason):
                    self.lastInjectedText = ""
                    self.swapPair = nil
                    self.swapPasteContext = nil
                    self.hotkey?.setSwapAvailable(false)
                    self.showFlowBarMessage(self.clipboardOnlyMessage(for: reason))
                    goBack()
                    finish(false)
                }
            } }
        }
        // Destination resolution and AX verification are bounded well below this.
        // Keep a trace even if an unexpected integration path loses its callback.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            session.latency.markOutput("yapıştırma sonucu zaman aşımı")
            // The send path hops apps and waits, but never this long.
            try? await Task.sleep(for: .seconds(6))
            if !finished { owLog("[Result] Paste result never came back; reporting not delivered") }
            finish(false)
        }
        }
    }

    // What the rules need for the command routes. Built only when one is reached:
    // it lists the installed apps.
    @MainActor private func commandContext(_ run: FinishRun) -> CommandRegistry.Context {
        let timers = TimerManager.shared
        let focus = run.focus
        return CommandRegistry.Context(
            ringing: timers.ringing != nil, timerActive: !timers.timers.isEmpty,
            installedApps: focus.map { $0.frontFirst(SystemController.installedApps()) } ?? SystemController.installedApps(),
            shortcuts: SystemController.shortcutNames,
            scenes: SceneStore.load().map(\.name),
            readingPaused: ArticleReader.shared.isPaused,
            readingJustCut: ArticleReader.shared.wasJustCut)
    }

    /// A scene's steps, each parsed as if it were said on its own; the ones no rule
    /// reads are named in the answer.
    @MainActor private func sceneSteps(_ run: FinishRun, _ name: String) -> (steps: [MultiCommandSplitter.Step<VoiceCommand>], unknown: [String]) {
        let key = DailyCommandParser.sceneKey(name)
        guard let scene = SceneStore.load().first(where: { DailyCommandParser.sceneKey($0.name) == key }) else { return ([], [name]) }
        let context = commandContext(run)
        var steps: [MultiCommandSplitter.Step<VoiceCommand>] = []
        var unknown: [String] = []
        for text in scene.steps {
            let command = CommandRegistry.match(text, context: context)
            // Of the agent commands only "Claude Code'da yeni session aç" runs as a step.
            let runs: Bool
            if case .agent(let dictation)? = command {
                runs = dictation.body.isEmpty && dictation.session == .new && dictation.project == nil
            } else {
                runs = command.map { !$0.isStandalone } ?? false
            }
            if runs, let command {
                steps.append(MultiCommandSplitter.Step(text: text, command: command))
            } else {
                unknown.append(text)
            }
        }
        owLog("[Scene] \(name): \(steps.map { "'\($0.text)' → \($0.command)" }.joined(separator: ", "))\(unknown.isEmpty ? "" : "; unknown: \(unknown)")")
        return (steps, unknown)
    }

    /// Runs the steps in order and answers once for all of them.
    @MainActor private func runCommands(_ run: FinishRun, _ steps: [MultiCommandSplitter.Step<VoiceCommand>], output: String) async {
        let session = run.session
        let text = run.text
        self.lastTranscription = text
        let actionStartedAt = session.latency.timestamp()
        var steps = steps
        var statuses: [String] = []
        var replies: [String?] = []
        // "Çalışma modu": its steps run here in its place, answered with one sentence.
        var scene: (name: String, failed: [String])?
        if steps.count == 1, case .system(.scene(let name)) = steps[0].command {
            let expanded = sceneSteps(run, name)
            steps = expanded.steps
            scene = (name, expanded.unknown)
        }
        var startsReading = false
        // After "Safari'ye geç", later steps belong to the app switched to: Spotify gives
        // focus back to this app if a cold launch stole it.
        var stepTargetApp = session.targetApp
        var ran: [VoiceCommand] = []
        for step in steps {
            switch step.command {
            case .timer(let timerCommand):
                await runTimerStep(step, timerCommand, ran: &ran, statuses: &statuses, replies: &replies)
            case .system(let parsed):
                await runSystemStep(
                    run, step, parsed, allSteps: steps, stepTargetApp: &stepTargetApp, startsReading: &startsReading,
                    ran: &ran, statuses: &statuses, replies: &replies
                )
            case .spotify(let request):
                await runSpotifyStep(
                    run, step, request, targetApp: stepTargetApp, ran: &ran, statuses: &statuses, replies: &replies
                )
            case .agent(let dictation) where dictation.body.isEmpty && dictation.session == .new && dictation.project == nil:
                await runNewAgentChatStep(
                    run, step, dictation, isLast: steps.last?.text == step.text, ran: &ran, statuses: &statuses, replies: &replies
                )
            case .agent:
                // Never a step: `CommandRegistry` keeps agent dictation on its own route.
                owLog("[Route] agent dictation reached the command runner; skipped")
            }
        }
        if let scene {
            let failed = scene.failed + zip(steps, statuses).filter { JarvisReply.isFailure($0.1) }.map(\.0.text)
            replies = [self.jarvisReply.scene(scene.name, failed: failed)]
            if steps.isEmpty { statuses = [L("\(scene.name) sahnesi bulunamadı", "Scene \(scene.name) not found")] }
        }
        self.lastCommandUndo = CommandUndo.steps(undoing: ran)
        session.latency.record(.action, since: actionStartedAt, detail: output)
        session.latency.markOutput("\(output) tamamlandı")
        let summary = statuses.joined(separator: " · ")
        // A lone Mac action is a short confirmation; a timer or a list stays a bit longer.
        let lone: Bool
        if steps.count == 1, case .system = steps[0].command { lone = true } else { lone = false }
        if !summary.isEmpty {
            self.showFlowBarMessage(summary, durationMs: summary.count > 40 ? 6000 : lone ? 2500 : 3500)
        }
        // The Mac stops listening after sleep / lock; a scene is a whole setup, and a
        // reading talks on for minutes.
        if run.conversationContinuationApp == nil, scene == nil, !startsReading, !ran.isEmpty, !ran.contains(where: \.endsSession) {
            run.commandFollowUp = .some(ran.reversed().lazy.compactMap(CommandFollowUp.domain(of:)).first)
        }
        if session.isVoiceCommand { await speakAfterCommand(run, self.jarvisReply.combined(replies)) }
        if startsReading {
            if self.voiceRepliesEnabled {
                ArticleReader.shared.start { [weak self] speaking in self?.jarvisActivity = speaking ? .speaking : .none }
            } else {
                self.showFlowBarMessage(L("Sesli cevap kapalı; okuyamam", "Voice replies are off; I can't read it"), durationMs: 3500)
            }
        }
    }

    /// Says a command's reply; the follow-up window (`commandFollowUp`) opens as the
    /// voice starts and lasts until 2 s after it. Without a voice the defer opens it.
    @MainActor private func speakAfterCommand(_ run: FinishRun, _ reply: String?) async {
        let session = run.session
        await self.speakReply(reply) {
            guard let commandFollowUp = run.commandFollowUp, !run.followUpOpenedOverReply else { return }
            run.followUpOpenedOverReply = self.listenAfterCommand(domain: commandFollowUp, after: session, overReply: true)
        }
        if run.followUpOpenedOverReply { self.commandFollowUpReplyEnded() }
    }

    /// Answers with the chat model and, when the answer asks something back, listens.
    @MainActor private func chat(_ run: FinishRun, _ chatText: String, recalled: [String] = [], detail: String) async {
        let session = run.session
        let text = run.text
        self.lastTranscription = text
        let actionStartedAt = session.latency.timestamp()
        var answer = await self.chatReply(to: chatText, recalled: recalled, deferUnrecognized: canRescue(run))
        session.latency.record(.action, since: actionStartedAt, detail: detail)
        session.latency.markOutput("Jarvis cevabı")
        // No router knew the command: the cloud looks for another way before Jarvis asks again.
        if let unrecognized = JarvisChat.shared.deferredUnrecognizedReply {
            JarvisChat.shared.deferredUnrecognizedReply = nil
            if await rescue(run, failure: unrecognized) { return }
            answer = (unrecognized, await self.speakReply(unrecognized))
            if !answer.heard { self.showFlowBarMessage(unrecognized, durationMs: 4000) }
        }
        if self.listenForReplyAnswer(answer.text, heard: answer.heard, after: session) {
            run.holdMediaForReplyAnswer = true
        }
    }

    /// Speaks `reply`, or shows it when the voice can't be heard.
    @MainActor private func say(_ run: FinishRun, _ reply: String, durationMs: Int) async {
        if !(await self.speakReply(reply)) { self.showFlowBarMessage(reply, durationMs: durationMs) }
    }

    /// Says a WhatsApp status; a read-back draft then listens for "evet" / "hayır".
    @MainActor private func sayWhatsApp(_ run: FinishRun, _ prepared: WhatsAppSender.Prepared) async {
        switch prepared {
        case .confirm(let prompt):
            owLog("[Result] WhatsApp draft read back, awaiting confirmation")
            let heard = await self.speakReply(prompt)
            askFollowUp(run, prompt, heard: heard)
        case .done(let status):
            owLog("[Result] WhatsApp: \(status)")
            await say(run, status, durationMs: 5000)
        }
    }

    /// Keeps the paused media paused while a follow-up question waits for its answer,
    /// with a safety net if the answer's recording never starts.
    @MainActor private func askFollowUp(_ run: FinishRun, _ prompt: String, heard: Bool) {
        let session = run.session
        // Typed: the answer is typed too; closing the panel unanswered drops the plan,
        // as a silent confirmation window does.
        if session.trigger == .typed {
            self.openTypedRequestPanel(prompt: prompt) { [weak self] in
                self?.reminderManager?.cancelPendingDeletion()
                self?.whatsAppSender.cancel()
                self?.pendingScreenPress = nil
            }
            return
        }
        run.holdMediaForFollowUp = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.recordingState != .recording else { return }
            self.recordingMedia.end(resuming: true)
        }
        if !heard {
            // The voice failed; show the question so the listening window isn't a mystery.
            owLog("[Reminders] Confirmation prompt not heard; showing it on screen")
            self.showFlowBarMessage(prompt, durationMs: 6000)
        }
        self.startVoiceSession(trigger: .confirmation)
    }

    /// A goal of several steps on screen (`ScreenTask`): each step is said aloud, Esc stops it
    /// before the next action. A risky step is asked like a single press; on "evet" the task
    /// goes on from `history`.
    @MainActor private func runScreenTask(_ run: FinishRun, goal: String, spoken: String? = nil, history: [String] = [],
                                          client: CloudChatClient, model: String) async {
        let session = run.session
        session.latency.finishDecision(route: "çok adımlı ekran eylemi")
        owLog("[Route] screen task: '\(goal)'\(history.isEmpty ? "" : " (step \(history.count + 1))")")
        self.lastTranscription = run.text
        self.lastCommandUndo = []
        let escHint = L("Esc iptal eder", "Esc cancels")
        self.showFlowBarMessage("\(L("Ekrana bakıyorum…", "Looking at the screen…")) · \(escHint)", durationMs: 30000)
        self.screenTaskCancelled = false
        self.screenTaskRunning = true
        hotkey?.screenTaskEscape = true
        let outcome = await ScreenTask.run(
            goal: goal, spoken: spoken, history: history, client: client, model: model,
            isCancelled: { self.screenTaskCancelled },
            progress: { step in
                self.showFlowBarMessage("\(step) · \(escHint)", durationMs: 30000)
                await self.speakReply(step)
            },
            type: { text, app in
                await withCheckedContinuation { continuation in
                    guard let injector = self.textInjector else { return continuation.resume(returning: false) }
                    injector.pasteTextResult(text, targetApp: app, context: nil) { outcome in
                        if case .clipboardOnly = outcome { continuation.resume(returning: false) } else { continuation.resume(returning: true) }
                    }
                }
            })
        self.screenTaskRunning = false
        hotkey?.screenTaskEscape = false
        switch outcome {
        case .done:
            self.showFlowBarMessage(L("Tamamlandı ✓", "Done ✓"), durationMs: 1500)
            if session.isVoiceCommand { await self.speakReply(self.jarvisReply.ack()) }
        case .notFound(let reason):
            // Nothing was done yet: another way can't repeat a step.
            owLog("[ScreenTask] Found no way: \(reason)")
            if await rescue(run, failure: reason) { return }
            self.showFlowBarMessage(reason, durationMs: 4000)
            if session.isVoiceCommand { await self.speakReply(self.jarvisReply.failure(reason)) }
        case .failed(let reason):
            owLog("[ScreenTask] Stopped: \(reason)")
            self.showFlowBarMessage(reason, durationMs: 4000)
            if session.isVoiceCommand { await self.speakReply(self.jarvisReply.failure(reason)) }
        case .cancelled:
            owLog("[ScreenTask] Stopped by the user")
            self.showFlowBarMessage(L("İptal edildi", "Cancelled"), durationMs: 1500)
        case .confirm(let target, let app, let history):
            self.pendingScreenPress = (target, app, Date().addingTimeInterval(30), (goal, spoken, history))
            let prompt = L("“\(target.label)” \(target.kindDative) basayım mı?", "Shall I press “\(target.label)”?")
            let heard = await self.speakReply(prompt)
            askFollowUp(run, prompt, heard: heard)
        }
    }

    /// Whether a failed Jarvis command may ask the cloud for another way: a spoken Jarvis
    /// command (never Fn dictation or what was heard over playing media), the cloud selected
    /// and set up, and not already a rescue.
    @MainActor private func canRescue(_ run: FinishRun) -> Bool {
        let session = run.session
        return !run.isRescue && session.isVoiceCommand && session.trigger != .typed && !session.heardOnlyOverPlayback
            && ChatBackend.selected == .cloud && CloudLLM.client() != nil
            && !screenTaskRunning && !RemoteControl.screenIsLocked
    }

    /// Jarvis couldn't do or find what was asked (`failure` is what it would say): the cloud is
    /// asked once for another way (`CommandRescue`) and that is done. False when there is none
    /// or it can't be asked; the caller then says its failure.
    @MainActor private func rescue(_ run: FinishRun, failure: String) async -> Bool {
        guard canRescue(run), let (client, model) = CloudLLM.client() else { return false }
        run.isRescue = true
        let request = run.trimmed
        owLog("[Rescue] '\(request)' failed ('\(failure)'); asking the cloud")
        let escHint = L("Esc iptal eder", "Esc cancels")
        self.showFlowBarMessage("\(L("Bir yolunu arıyorum…", "Looking for a way…")) · \(escHint)", durationMs: 30000)
        self.screenTaskCancelled = false
        self.screenTaskRunning = true
        hotkey?.screenTaskEscape = true
        let app = NSWorkspace.shared.frontmostApplication
        let asking = Task { await CommandRescue.ask(request: request, failure: failure, app: app, client: client, model: model) }
        self.rescueAsking = asking
        await self.speakReply(L("Bir yolunu arıyorum.", "Let me find a way."))
        let plan = await asking.value
        self.rescueAsking = nil
        self.screenTaskRunning = false
        hotkey?.screenTaskEscape = false
        if self.screenTaskCancelled {
            owLog("[Rescue] Stopped by the user")
            self.showFlowBarMessage(L("İptal edildi", "Cancelled"), durationMs: 1500)
            return true
        }
        switch plan {
        case .screen(let goal):
            owLog("[Rescue] On screen: '\(goal)'")
            await runScreenTask(run, goal: goal, spoken: request, client: client, model: model)
        case .command(let command):
            // Only a plain command runs; anything that would type, send or answer a question
            // the user didn't is dropped (`CommandRescue.safeCommands`).
            let route = VoiceRouter.route(command, facts: routingFacts(run))
            guard ScreenMode.fieldTypeRequest(command) == nil, CommandRescue.safeCommands(route) != nil else {
                owLog("[Rescue] Rewritten command '\(command)' is not a plain command; not run")
                self.dismissFlowBarMessage()
                return false
            }
            owLog("[Rescue] As a command: '\(command)'")
            run.text = command
            run.trimmed = command
            await executeRoute(run, route)
        case .explain(let answer):
            owLog("[Rescue] Explained")
            self.lastTranscription = run.text
            await say(run, answer, durationMs: 8000)
        case .impossible:
            owLog("[Rescue] No way found")
            self.dismissFlowBarMessage()
            return false
        }
        return true
    }

    /// Esc during a multi-step screen task: it stops before its next action, and a step being
    /// said is cut short.
    func stopScreenTask() {
        guard screenTaskRunning, !screenTaskCancelled else { return }
        owLog("[ScreenTask] Stop requested (Esc)")
        screenTaskCancelled = true
        rescueAsking?.cancel()
        JarvisVoice.shared.stop()
        showFlowBarMessage(L("İptal ediliyor…", "Cancelling…"), durationMs: 8000)
    }

    /// "Kaydet", "izin ver", "sağ üstteki çarpıya bas": something in the front window,
    /// named as the user would to a friend. Not in a text field, unless clicking is said
    /// outright (there "tamam" is dictation), and never from a mic left open after a
    /// command or over playing media, where a TV's "tamam" must not press anything.
    @MainActor private func screenAction(_ run: FinishRun) async -> Bool {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        // Screen mode's open mic is for exactly this.
        let screenModeStep = screenModeActive && session.followsCommand
        let saysClickAfterCommand = session.followsCommand && ScreenActions.saysClick(trimmed)
        guard session.acceptsCommands, !session.takesOnlyCommands || screenModeStep || saysClickAfterCommand, !session.heardOnlyOverPlayback,
              !RemoteControl.screenIsLocked, let app = session.targetApp, !app.isTerminated,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
        // Fn types unless the focus is known not to be a text field (Electron composers
        // report it unknown); a Jarvis session only stays out of a known text field.
        let outsideTextField = session.isVoiceCommand ? session.routingFocus != .editable : session.routingFocus == .notEditable
        if !outsideTextField, !ScreenActions.saysClick(trimmed) { return false }
        // "Analizleri indir", "Ayarlar'da bildirimleri kapat": several presses by the cloud
        // model (`ScreenTask`). Jarvis only, not from screen mode's open mic.
        let taskCloud = session.isVoiceCommand && !screenModeStep && ChatBackend.selected == .cloud
            && ScreenTask.isGoal(trimmed) ? CloudLLM.client() : nil
        guard ScreenActions.worthLooking(trimmed) || taskCloud != nil else { return false }
        let stepStarted = CACurrentMediaTime()
        var stepParts: [(String, TimeInterval)] = []
        // "Mikrofona bas" again, or "tekrar bas": the button pressed last, though pressing
        // may have changed its look (Claude's mic turned into a stop and was not found).
        if screenModeStep, ScreenActions.saysClick(trimmed), let last = screenModeLastPress, ScreenReader.node(last.element.element).frame != nil,
           ScreenMode.isRepeat(trimmed) || (last.iconClass != nil && IconClassifier.iconClass(for: trimmed) == last.iconClass) {
            await pressLastAgain(run, last.element, stepStarted: stepStarted)
            return true
        }
        // "… tuşuna bas" asked for a press: if nothing fits, say so instead of chatting.
        let saysClick = ScreenActions.saysClick(trimmed)
        var mark = CACurrentMediaTime()
        // Up to 400 for matching by name: Spotify shows ~900 once its tree is awake. The
        // language model still reads only the first 150, to keep its prompt short.
        let elements = ScreenActions.elements(of: app, limit: 400)
        stepParts.append(("ekran okuma", CACurrentMediaTime() - mark))
        // On screen first, by its name. Then the app's menus by theirs, ahead of a model's guess
        // among what is on screen: "dışa aktar" means the menu item, whatever else looks close.
        mark = CACurrentMediaTime()
        let onScreenByName = !ScreenActions.exactMatches(trimmed, labels: elements.map(\.label)).isEmpty
        let menuItems = onScreenByName ? [] : MenuCommands.items(of: app)
        var found = MenuCommands.exactMatch(trimmed, in: menuItems)
        stepParts.append(("menü okuma", CACurrentMediaTime() - mark))
        // A goal whose name isn't on screen as it is: the task finds its own way there.
        if found == nil, !onScreenByName, let (client, model) = taskCloud {
            await runScreenTask(run, goal: trimmed, client: client, model: model)
            return true
        }
        var byModel = false
        // The menu model is asked alongside the on-screen pick, not after it; its answer
        // is used only when nothing on screen was picked.
        mark = CACurrentMediaTime()
        let menuModel: Task<ScreenElement?, Never>? = found == nil && (saysClick || screenModeStep || MenuCommands.isShort(trimmed))
            ? Task { await MenuCommands.modelMatch(trimmed, in: menuItems) } : nil
        if found == nil, !elements.isEmpty {
            let (pick, picked) = await pickElement(trimmed, elements: elements, saysClick: saysClick, stepParts: &stepParts)
            found = pick.map { elements[$0] }
            byModel = picked
        }
        if let menuModel {
            if found == nil {
                found = await menuModel.value
                byModel = found != nil
                stepParts.append(("menü modeli", CACurrentMediaTime() - mark))
            } else {
                menuModel.cancel()
            }
        }
        guard let target = found else { return await pressByText(run, app: app, saysClick: saysClick, screenModeStep: screenModeStep, stepStarted: stepStarted, stepParts: stepParts) }
        session.latency.finishDecision(route: "ekran eylemi")
        owLog("[Route] screen action: \(target.kind) '\(target.label)' (\(target.region))\(byModel ? " by the model" : "")")
        self.lastTranscription = text
        self.lastCommandUndo = []
        // "… bas" already is the go-ahead; only a bare name ("Gönder") is asked about.
        if ScreenActions.isRisky(target.label), !saysClick {
            self.pendingScreenPress = (target, app, Date().addingTimeInterval(30), nil)
            let prompt = L("“\(target.label)” \(target.kindDative) basayım mı?", "Shall I press “\(target.label)”?")
            let heard = await self.speakReply(prompt)
            askFollowUp(run, prompt, heard: heard)
            return true
        }
        mark = CACurrentMediaTime()
        let pressed = ScreenActions.perform(target)
        if pressed { self.screenModeLastPress = (target, IconClassifier.iconClass(for: trimmed)) }
        stepParts.append(("basma", CACurrentMediaTime() - mark))
        if session.isVoiceCommand {
            self.logScreenStep(session, pressed ? "basıldı" : "basılamadı", startedAt: stepStarted, stepParts)
        }
        self.showFlowBarMessage(pressed ? "“\(target.label)” ✓" : L("Basılamadı", "Couldn't press it"), durationMs: pressed ? 1500 : 3000)
        // A Jarvis press opens screen mode: the mic stays open for the next step, and
        // a spoken "tamam" would only slow it down.
        if session.isVoiceCommand, pressed {
            self.noteScreenModeAction()
            run.commandFollowUp = .some(nil)
        } else if session.isVoiceCommand {
            await self.speakReply(self.jarvisReply.failure(L("Basamadım", "I couldn't press it")))
        }
        return true
    }

    private func applyLocalCorrections(_ rawText: String) -> (text: String, appliedPairs: [(wrong: String, right: String)], laughterWasRandomized: Bool) {
        var initialText = rawText

        // Tracks which learned pairs actually fired for THIS dictation, so the paste
        // callback below can hand them to DictationSnapshot.capture for reversal detection.
        // Deliberately excludes PhoneticGlossaryCorrector's substitutions (see `phoneticApplied`
        // below) — that corrector has no corresponding CorrectionStore record to penalize.
        var appliedCorrectionPairs: [(wrong: String, right: String)] = []

        let activePairs = CorrectionStore.shared.activePairs
        if !activePairs.isEmpty {
            let (corrected, applied) = CorrectionEngine.applyCorrections(to: initialText, pairs: activePairs)
            if !applied.isEmpty {
                initialText = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                for (wrong, right) in applied {
                    owLog("[Corrections] Applied learned correction: \(wrong) -> \(right)")
                }
                CorrectionStore.shared.recordApplied(pairs: applied)
                appliedCorrectionPairs = applied
            }
        }

        let (phoneticCorrected, phoneticApplied) = PhoneticGlossaryCorrector.correct(initialText)
        if !phoneticApplied.isEmpty {
            initialText = phoneticCorrected.trimmingCharacters(in: .whitespacesAndNewlines)
            for (wrong, right) in phoneticApplied {
                owLog("[PhoneticGlossary] Corrected: \(wrong) -> \(right)")
            }
        }

        var laughterWasRandomized = false
        if self.laughterToRandomEnabled {
            let result = LaughterRandomizer.transform(initialText)
            if result.didTransform {
                initialText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                laughterWasRandomized = true
                owLog("[LaughterRandomizer] Laughter converted to keyboard random")
            }
        }
        return (initialText, appliedCorrectionPairs, laughterWasRandomized)
    }

    private func watchForScreenChange(targetApp: NSRunningApplication?, isWatching: @escaping @MainActor () -> Bool) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard isWatching(), let app, app.processIdentifier != targetApp?.processIdentifier,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                owLog("[Agent] Screen changed to \(app.localizedName ?? "?") before the send")
                self?.showFlowBarMessage(L("Ekran değişti, mesaj gitmeyebilir", "The screen changed, the message may not go through"), durationMs: 8000)
            }
        }
    }

    private func noteBackgroundSend(_ run: FinishRun, sent: Bool) {
        let session = run.session
        self.lastInjectedText = ""
        self.swapPair = nil
        self.swapPasteContext = nil
        self.hotkey?.setSwapAvailable(false)
        let result = sent ? "Agent message sent in background" : "Agent message written in background, send unconfirmed"
        session.latency.markOutput(result)
        owLog("[Result] \(result)")
        if let traceID = run.traceID {
            VoiceEventLog.shared.append(traceID, "[Result] \(result)")
        }
        self.showFlowBarMessage(sent ? L("gönderildi", "sent") : L("yazıldı, gönderilmedi", "written, not sent"), durationMs: 1200)
    }

    /// The app the user was in, when the send target had to be brought to the front.
    private func hopToSendTarget(_ run: FinishRun, targetApp: NSRunningApplication?, send: Bool) async -> NSRunningApplication? {
        var hopFrom: NSRunningApplication?
        if self.autoPasteEnabled, send,
           let target = targetApp, !target.isTerminated,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != target.processIdentifier {
            owLog("[Result] Send target is in the background; switching to \(target.localizedName ?? "?") to send, then back to \(front.localizedName ?? "?")")
            run.jarvisChangedScreen = true
            self.showFlowBarMessage(L("Jarvis ekranı değiştirdi, bekleyin", "Jarvis changed the screen, please wait"), durationMs: 8000)
            // A bound conversation focuses its own composer right after this.
            if await AgentAppActivator.bringToFront(target, settle: !RecordedConversation.requiresBinding(target.bundleIdentifier)) {
                hopFrom = front
            }
        }
        return hopFrom
    }

    private func noteDeliveryBlocked(_ run: FinishRun, text initialText: String, hadConversation: Bool) {
        let session = run.session
        _ = ClipboardHistory.write(initialText)
        let reason = !hadConversation
            ? "Kayıt başında sohbet kimliği alınamadı"
            : "Kaydın başladığı sohbete dönülemedi"
        run.agentDeliveryFailure = reason
        self.lastError = loc(reason) + ". " + loc("Metin panoya kopyalandı.")
        session.latency.markOutput(reason)
        owLog("[Agent] Delivery blocked: \(reason)")
    }

    private func watchForChatChange(in app: NSRunningApplication, conversation: RecordedConversation, shown: String, isWatching: @escaping @MainActor () -> Bool) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard isWatching(), !Task.isCancelled else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      let now = conversation.shownTitle(in: app), now != shown else { continue }
                owLog("[Agent] Chat changed to \"\(now)\" before the send")
                self?.showFlowBarMessage(L("Sohbet değişti, mesaj gitmeyebilir", "The chat changed, the message may not go through"), durationMs: 8000)
                return
            }
        }
    }

    private func pressReturnAfterPaste(
        _ run: FinishRun,
        text initialText: String,
        targetApp: NSRunningApplication?,
        pasteContext: PasteContext,
        delay: TimeInterval,
        stopWatching: @escaping @MainActor () -> Void,
        finish: @escaping @MainActor (Bool) -> Void,
        goBack: @escaping @MainActor () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // A background paste (the hop above failed or the user moved
                // on) still gets sent: hop there for the Return and back.
                var sent = false
                if let app = targetApp, !app.isTerminated,
                   app.bundleIdentifier.map(AgentApp.claudeCode.bundleIdentifiers.contains) ?? false,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                    _ = await ClaudeSessionNavigator.waitForComposerText(app, text: initialText)
                }
                if let pid = pasteContext.targetPID, let injector = self.textInjector as? TextInjector {
                    // From here Jarvis itself may hop to the target and back.
                    stopWatching()
                    sent = await injector.pressReturnBringingToFront(pid: pid, context: pasteContext)
                }
                // A posted Return proves nothing if Claude was not ready:
                // a sent message leaves the composer.
                if sent, let app = targetApp, !app.isTerminated,
                   app.bundleIdentifier.map(AgentApp.claudeCode.bundleIdentifiers.contains) ?? false,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                   await ClaudeSessionNavigator.composerStillHolds(app, text: initialText) {
                    owLog("[Result] Return pressed but the text is still in Claude's composer")
                    sent = false
                }
                owLog("[Result] Agent message \(sent ? "sent" : "pasted, Return skipped")")
                if let traceID = run.traceID {
                    VoiceEventLog.shared.append(traceID, "[Result] Agent message \(sent ? "sent" : "pasted, Return skipped")")
                }
                self.showFlowBarMessage(sent ? L("gönderildi", "sent") : L("yazıldı, gönderilmedi", "written, not sent"), durationMs: 1200)
                finish(sent)
                // Wait a beat so the app takes the Return before losing focus.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { goBack() }
            }
        }
    }

    /// Runs the LLM cleanup in the background and, once it is done, replaces the pasted text in place.
    private func cleanUpPastedText(
        _ run: FinishRun,
        _ initialText: String,
        rawText: String,
        targetApp: NSRunningApplication?,
        misheard: [MisheardWordDetector.Word],
        appliedPairs appliedCorrectionPairs: [(wrong: String, right: String)]
    ) {
        let session = run.session
        let generation = run.generation
        let focus = run.focus
        Task { @MainActor [weak self] in
            guard let self else { return }
            let cleanupStartedAt = session.latency.timestamp()
            let cleaned = await self.llmCleanup?.cleanup(text: initialText, misheard: misheard, focus: focus) ?? initialText
            session.latency.record(.cleanup, since: cleanupStartedAt)
            let formatted = await self.formatTurkishDictation(cleaned)
            let trimmedCleaned = formatted.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedCleaned.isEmpty, trimmedCleaned != initialText else { return }
            // A voice edit, an Option+Z swap or a newer dictation changed
            // the field since: backspacing `initialText` would cut the wrong text.
            guard self.lastInjectedText == initialText else {
                owLog("[OpenWhisper] Pasted text changed before the LLM cleanup finished; not replacing")
                return
            }
            if LLMCleanup.isNoOpCleanup(original: initialText, cleaned: trimmedCleaned) {
                owLog("[OpenWhisper] LLM cleanup only changed spacing/punctuation style; not swapping")
                return
            }
            // A corrected word can reveal a voice command ("Sesifullah"
            // → "Sesi fulle"): take the dictation back out and run it.
            if !misheard.isEmpty,
               !LLMCleanup.sameWords(trimmedCleaned, initialText),
               await self.runCorrectedDictationAsCommand(
                pasted: initialText, corrected: trimmedCleaned,
                generation: generation, session: session, targetApp: targetApp
               ) {
                return
            }
            owLog("[OpenWhisper] Async LLM cleanup complete: '\(trimmedCleaned)'. Replacing initial text...")

            self.textInjector?.replaceInjectedText(
                oldText: initialText,
                newText: trimmedCleaned,
                targetApp: targetApp,
                context: self.swapPasteContext
            ) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.swapPair = DictationPair(raw: rawText, cleaned: trimmedCleaned)
                    self.swapPasteContext = self.swapPasteContext?.contextAfterReplacingInjectedText(with: trimmedCleaned)
                    self.lastTranscription = trimmedCleaned
                    self.lastInjectedIsCleaned = true
                    self.lastInjectedText = trimmedCleaned
                    self.textInjector?.copyToClipboard(rawText)
                    self.showFlowBarMessage("fixed", durationMs: 1000)
                    // The field now holds the LLM-cleaned text, not what
                    // was captured at the raw paste above — without this,
                    // every later diff compares raw-vs-cleaned and can
                    // learn the LLM's own edits as if the user made them.
                    // `capture` re-runs the same suppressNextCapture check
                    // as the original call (see `install`), so an
                    // intervening Option+Z swap still correctly discards
                    // this recapture instead of resurrecting a snapshot
                    // for text the user already threw away.
                    DictationSnapshot.shared.capture(
                        pastedText: trimmedCleaned,
                        targetApp: targetApp,
                        appliedPairs: appliedCorrectionPairs
                    )
                    owLog("[OpenWhisper] Async LLM replacement finished.")
                    if let traceID = run.traceID {
                        VoiceEventLog.shared.append(traceID, "[Result] Replaced pasted text with cleanup: '\(trimmedCleaned)'")
                    }
                }
            }
        }
    }

    private func runTimerStep(
        _ step: MultiCommandSplitter.Step<VoiceCommand>,
        _ timerCommand: TimerCommandParser.Command,
        ran: inout [VoiceCommand],
        statuses: inout [String],
        replies: inout [String?]
    ) async {
        let timers = TimerManager.shared
        let status: String
        // A wall-clock alarm goes to the Clock app, which rings it even without Jarvis;
        // Jarvis keeps it only when that can't be done (no shortcut, more than a day away).
        if case .alarm(let date, let label) = timerCommand, ClockAlarm.canSet(date),
           await ClockAlarm.set(date, label: label) {
            status = L("Saat uygulamasına alarm kurdum: ", "I set an alarm in the Clock app: ") + TimerManager.clock(date, sayDay: true)
        } else {
            status = timers.perform(timerCommand)
        }
        owLog("[Result] Timer: \(status)")
        ran.append(step.command)
        statuses.append(status)
        replies.append(self.jarvisReply.timer(timerCommand, status: status))
    }

    private func runSystemStep(
        _ run: FinishRun,
        _ step: MultiCommandSplitter.Step<VoiceCommand>,
        _ parsed: SystemCommand,
        allSteps steps: [MultiCommandSplitter.Step<VoiceCommand>],
        stepTargetApp: inout NSRunningApplication?,
        startsReading: inout Bool,
        ran: inout [VoiceCommand],
        statuses: inout [String],
        replies: inout [String?]
    ) async {
        let session = run.session
        var command = parsed
        // "Tam ekran yap": the YouTube video in front, else the window ("Claude'u tam
        // ekran yap" names its app).
        if parsed == .video(.fullscreen) {
            let named = DailyCommandParser.fullscreenTarget(step.text, installedApps: SystemController.installedApps())
            if (named != nil && named != "Safari") || !VideoController.youTubeVideoInFront() {
                command = .window(WindowAction(app: named, position: .fullscreen))
            }
        }
        if step.command.endsSession && command != .disableWakeWord {
            // Say everything before the Mac stops listening.
            if session.isVoiceCommand {
                await self.speakReply(self.jarvisReply.combined(replies + [L("Görüşürüz.", "See you.")]))
            }
            replies = []
        }
        // The local model takes several seconds on a long page.
        if command == .browser(.summarize) { self.showFlowBarMessage(L("Sayfa özetleniyor…", "Summarizing the page…"), durationMs: 30000) }
        var youTubeStatus: String?
        if case .video = command, SystemCommandParser.mentionsYouTube(step.text) {
            youTubeStatus = await BrowserController.prepareYouTubeVideo()
        }
        let status: String
        if let youTubeStatus {
            status = youTubeStatus
        } else if case .video(let action) = command, SystemCommandParser.mentionsYouTube(step.text) {
            status = await VideoController.perform(action, onlyYouTube: true)
        } else {
            status = await SystemController.perform(command, disableWakeWord: {
                self.wakeWordEnabled = false
            })
        }
        if command == .disableWakeWord {
            run.commandFollowUp = nil
            run.conversationContinuationApp = nil
        }
        if case .reading(let action) = command, action != .stop, !JarvisReply.isFailure(status) {
            // Jarvis reads over nothing: the paused media stays paused.
            startsReading = true
            run.resumeMediaAfterCommand = false
        }
        // "Videoyu durdur / devam ettir" decided the state; a seek or speed change
        // lets the video the recording paused continue, and so does a failed command.
        if case .video(let action) = command, action.changesPlayback,
           !VideoController.failures.contains(status) { run.resumeMediaAfterCommand = false }
        if command == .video(.play) { ArticleReader.shared.forget() }
        switch command {
        case .switchToAgent(let agent):
            stepTargetApp = NSWorkspace.shared.frontmostApplication
            // Opening an agent invites a message, not just a short command fix.
            // Continue only after a successful final step into the expected app.
            if session.isVoiceCommand, steps.last?.command == step.command,
               status == SystemController.frontStatus(agent.displayName),
               let app = stepTargetApp,
               agent.bundleIdentifiers.contains(app.bundleIdentifier ?? "") {
                run.conversationContinuationApp = app
            }
        case .switchToApp: stepTargetApp = NSWorkspace.shared.frontmostApplication
        default: break
        }
        owLog("[Result] System command: \(status)")
        ran.append(step.command)
        statuses.append(status)
        if !step.command.endsSession || command == .disableWakeWord { replies.append(self.jarvisReply.system(command, status: status)) }
    }

    private func runSpotifyStep(
        _ run: FinishRun,
        _ step: MultiCommandSplitter.Step<VoiceCommand>,
        _ request: String,
        targetApp stepTargetApp: NSRunningApplication?,
        ran: inout [VoiceCommand],
        statuses: inout [String],
        replies: inout [String?]
    ) async {
        let resumes = SpotifyManager.resumesPausedMedia(afterCommand: request)
        let likedSongs = SpotifyManager.playsLikedSongs(afterCommand: request)
        let speaksResult = SpotifyManager.speaksResult(afterCommand: request)
        let speaksFailure = SpotifyManager.speaksFailure(afterCommand: request)
        let handled = await SpotifyManager.shared.handleCommand(text: request, targetApp: stepTargetApp)
        let message = SpotifyManager.shared.takeResultMessage(for: request)
        owLog("[Result] Spotify command \(handled ? "handled" : "not applied"): '\(request)'")
        if handled, !resumes { run.resumeMediaAfterCommand = false }
        if handled { ArticleReader.shared.forget() }
        if handled { ran.append(step.command) }
        statuses.append(handled ? "Spotify: \(step.text)" : L("Spotify komutu uygulanamadı", "Couldn't apply the Spotify command"))
        if handled {
            replies.append(speaksResult ? message.map { self.jarvisReply.spotifyResult($0) }
                : self.jarvisReply.spotify(handled: true, likedSongs: likedSongs))
        } else {
            replies.append(self.jarvisReply.failure(speaksFailure ? message ?? L("Spotify komutunu uygulayamadım", "I couldn't apply the Spotify command") : L("Spotify komutunu uygulayamadım", "I couldn't apply the Spotify command")))
        }
    }

    private func runNewAgentChatStep(
        _ run: FinishRun,
        _ step: MultiCommandSplitter.Step<VoiceCommand>,
        _ dictation: AgentDictation,
        isLast: Bool,
        ran: inout [VoiceCommand],
        statuses: inout [String],
        replies: inout [String?]
    ) async {
        // A scene's "Claude Code'da yeni session aç". An app still launching behind
        // can take the front while this one is activated; try again once it settled.
        let agent = dictation.target ?? .claudeCode
        var app: NSRunningApplication?
        for _ in 0..<3 where app == nil { app = await AgentAppActivator.activate(agent) }
        var opened = false
        if let app {
            opened = agent == .claudeCode ? await ClaudeSessionNavigator.openNewSession(app)
                : await CodexSessionNavigator.openNewThread(app, folder: nil)
        }
        if opened, let app, isLast { run.conversationContinuationApp = app }
        let status = opened ? L("\(agent.displayName)’da yeni sohbet hazır", "New chat ready in \(agent.displayName)")
            : L("\(agent.displayName)’da yeni sohbet açılamadı", "Couldn't open a new chat in \(agent.displayName)")
        owLog("[Result] Agent new session: \(status)")
        ran.append(step.command)
        statuses.append(status)
        replies.append(opened ? nil : self.jarvisReply.failure(status))
    }

    private func pressLastAgain(_ run: FinishRun, _ element: ScreenElement, stepStarted: TimeInterval) async {
        let session = run.session
        let text = run.text
        session.latency.finishDecision(route: "ekran eylemi, aynı düğme")
        owLog("[Route] screen action: '\(element.label)' again")
        self.lastTranscription = text
        let pressed = ScreenActions.perform(element)
        self.logScreenStep(session, pressed ? "aynı düğmeye basıldı" : "basılamadı", startedAt: stepStarted,
                           [("basma", CACurrentMediaTime() - stepStarted)])
        self.showFlowBarMessage(pressed ? "✓" : L("Basılamadı", "Couldn't press it"), durationMs: pressed ? 1500 : 3000)
        if pressed {
            self.noteScreenModeAction()
            run.commandFollowUp = .some(nil)
        } else {
            await self.speakReply(self.jarvisReply.failure(L("Basamadım", "I couldn't press it")))
        }
    }

    /// Fn dictation keeps typing such a sentence; only Jarvis was asked to press.
    private func notFound(_ run: FinishRun, saysClick: Bool, stepStarted: TimeInterval, stepParts: [(String, TimeInterval)]) async -> Bool {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        guard saysClick, session.isVoiceCommand else { return false }
        let name = ScreenActions.spokenName(trimmed)
        owLog("[Screen] Nothing on screen matches '\(name)'")
        session.latency.finishDecision(route: "ekran eylemi, bulunamadı")
        self.logScreenStep(session, "bulunamadı", startedAt: stepStarted, stepParts)
        self.lastTranscription = text
        if await rescue(run, failure: L("Ekranda “\(name)” bulamadım", "I couldn't find “\(name)” on screen")) { return true }
        self.showFlowBarMessage(L("Ekranda “\(name)” bulamadım", "I couldn't find “\(name)” on screen"), durationMs: 4000)
        if session.isVoiceCommand { await self.speakReply(self.jarvisReply.failure(L("Bulamadım", "I couldn't find it"))) }
        return true
    }

    /// Not in the accessibility tree (a canvas, a game, an Electron view): find the
    /// words on a screenshot and click them; an icon without words goes to a vision
    /// model. Only when pressing was asked for.
    private func pressByText(
        _ run: FinishRun,
        app: NSRunningApplication,
        saysClick: Bool,
        screenModeStep: Bool,
        stepStarted: TimeInterval,
        stepParts: [(String, TimeInterval)]
    ) async -> Bool {
        let session = run.session
        let text = run.text
        let trimmed = run.trimmed
        var stepParts = stepParts
        // "bu butonuna bas" names nothing: no screenshot can find it.
        guard session.isVoiceCommand, saysClick || screenModeStep,
              !ScreenActions.spokenName(trimmed).isEmpty else { return await notFound(run, saysClick: saysClick, stepStarted: stepStarted, stepParts: stepParts) }
        // OCR and the icon model look at the screen at the same time, not one after the
        // other; a named icon ("mikrofona bas") is no text, so there the icon's pick wins.
        let namesIcon = saysClick && IconClassifier.iconClass(for: trimmed) != nil
        var mark = CACurrentMediaTime()
        async let textFound = ScreenActions.findText(trimmed, in: app)
        async let iconFound = saysClick ? await ScreenActions.iconPick(trimmed, in: app) : nil
        var hit = await textFound
        let icon = await iconFound
        stepParts.append((saysClick ? "OCR + simge modeli (aynı anda)" : "ekran görüntüsü + OCR", CACurrentMediaTime() - mark))
        if let found = hit, ScreenActions.isRisky(found.label), !saysClick { hit = nil }
        if let icon, namesIcon || hit == nil,
           NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            session.latency.finishDecision(route: "ekran eylemi, simge modeli")
            owLog("[Route] screen action: icon '\(icon.label)' by the icon model")
            self.lastTranscription = text
            self.lastCommandUndo = []
            mark = CACurrentMediaTime()
            let pressed = ScreenActions.perform(icon)
            if pressed { self.screenModeLastPress = (icon, IconClassifier.iconClass(for: trimmed)) }
            stepParts.append(("basma", CACurrentMediaTime() - mark))
            self.logScreenStep(session, pressed ? "simge modeliyle basıldı" : "basılamadı", startedAt: stepStarted, stepParts)
            self.showFlowBarMessage(pressed ? "✓" : L("Basılamadı", "Couldn't press it"), durationMs: pressed ? 1500 : 3000)
            if pressed {
                self.noteScreenModeAction()
                run.commandFollowUp = .some(nil)
            } else {
                await self.speakReply(self.jarvisReply.failure(L("Basamadım", "I couldn't press it")))
            }
            return true
        }
        if hit == nil, saysClick {
            self.showFlowBarMessage(L("Ekrana bakıyorum…", "Looking at the screen…"), durationMs: 12000)
            mark = CACurrentMediaTime()
            let point = await ScreenActions.visionPick(trimmed, in: app)
            stepParts.append(("görüntü modeli", CACurrentMediaTime() - mark))
            if let point { hit = (ScreenActions.spokenName(trimmed), point) } else { self.dismissFlowBarMessage() }
        }
        guard let hit, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return await notFound(run, saysClick: saysClick, stepStarted: stepStarted, stepParts: stepParts)
        }
        session.latency.finishDecision(route: "ekran eylemi, ekran görüntüsünden")
        owLog("[Route] screen action: '\(hit.label)' on the screenshot at \(Int(hit.point.x)),\(Int(hit.point.y))")
        self.lastTranscription = text
        self.lastCommandUndo = []
        mark = CACurrentMediaTime()
        let pressed = ScreenActions.click(at: hit.point)
        stepParts.append(("tıklama", CACurrentMediaTime() - mark))
        if session.isVoiceCommand {
            self.logScreenStep(session, pressed ? "ekran görüntüsünden tıklandı" : "tıklanamadı", startedAt: stepStarted, stepParts)
        }
        self.showFlowBarMessage(pressed ? "“\(hit.label)” ✓" : L("Basılamadı", "Couldn't press it"), durationMs: pressed ? 1500 : 3000)
        if session.isVoiceCommand, pressed {
            self.noteScreenModeAction()
            run.commandFollowUp = .some(nil)
        } else if session.isVoiceCommand {
            await self.speakReply(self.jarvisReply.failure(L("Basamadım", "I couldn't press it")))
        }
        return true
    }

    /// The element the words name: by its label if that is clear, otherwise the language model's pick.
    private func pickElement(
        _ trimmed: String,
        elements: [ScreenElement],
        saysClick: Bool,
        stepParts: inout [(String, TimeInterval)]
    ) async -> (pick: Int?, byModel: Bool) {
        let labels = elements.map(\.label)
        var pick: Int?
        var byModel = false
        let exact = ScreenActions.exactMatches(trimmed, labels: labels)
        // Only when pressing was said: "bak" alone must not press "Back".
        let soundAlike = exact.isEmpty && saysClick ? ScreenActions.soundAlikeMatches(trimmed, labels: labels) : []
        if exact.count == 1 {
            pick = exact[0]
        } else if exact.count > 1, exact.filter({ elements[$0].inDialog }).count == 1 {
            pick = exact.first { elements[$0].inDialog }
        } else if soundAlike.count == 1 {
            pick = soundAlike[0]
            owLog("[Screen] '\(trimmed)' sounds like '\(labels[soundAlike[0]])'")
        } else if !(exact.isEmpty && saysClick && IconClassifier.iconClass(for: trimmed) != nil
                    && !labels.contains { ScreenActions.isGrounded(trimmed, label: $0) }),
                  !exact.isEmpty || saysClick || ScreenActions.mayBeAboutScreen(trimmed, labels: labels) {
            // A named icon no label speaks of skips the language model (0.5–2 s): the icon
            // model in `pressByText` knows icons better.
            self.showFlowBarMessage(L("Ekrana bakıyorum…", "Looking at the screen…"), durationMs: 8000)
            let mark = CACurrentMediaTime()
            pick = await ScreenActions.modelPick(trimmed, elements: Array(elements.prefix(150)))
            stepParts.append(("model seçimi", CACurrentMediaTime() - mark))
            byModel = true
            if let chosen = pick, exact.isEmpty, !soundAlike.contains(chosen),
               !ScreenActions.isGrounded(trimmed, label: labels[chosen]) {
                owLog("[Screen] Model's pick '\(labels[chosen])' has nothing to do with '\(trimmed)'; not pressed")
                pick = nil
            }
            if pick == nil { self.dismissFlowBarMessage() }
        }
        return (pick, byModel)
    }

    // For a Jarvis session that is not a command, keyboard focus is the primary signal:
    // editable means dictation (unless the model says a question is for Jarvis), known
    // non-editable means chat. The LLM is otherwise only a fallback when Accessibility
    // could not determine the focus. Fn dictation is always typed, except on the lock
    // screen: nothing is dictated there, so every trigger gets the Jarvis answer.
    /// A command no rule caught, maybe misheard: the model (the cloud when Jarvis's chat is on
    /// it) writes the command the user most likely meant, and it runs only if a rule then
    /// recognises that sentence. `anyShape`: the model judges it even when it doesn't end like
    /// a command (a short sentence said to Jarvis).
    @MainActor private func runRewrittenCommand(_ run: FinishRun, anyShape: Bool = false) async -> Bool {
        let session = run.session
        let trimmed = run.trimmed
        let cloud = ChatBackend.selected == .cloud ? FallbackChat.command("CommandRewriter") : nil
        guard cloud != nil || self.ollamaAvailable, anyShape || CommandRewriter.looksLikeCommand(trimmed),
              let rewritten = await CommandRewriter.rewrite(trimmed, model: self.ollamaModel,
                                                            cloud: cloud.map { ($0, $0.cloudModel) }) else { return false }
        var command = CommandRewriter.safeCommand(rewritten, context: commandContext(run))
        // Volume and "Tarkan çal" aren't in the rule table; the Spotify path reads them.
        if command == nil, await SpotifyManager.isSpotifyCommand(rewritten, ollamaAvailable: self.ollamaAvailable, commandMode: true) {
            command = .spotify(rewritten)
        }
        guard let command else {
            owLog("[Route] llm-rewrite '\(trimmed)' → '\(rewritten)' recognised by no rule")
            return false
        }
        session.latency.finishDecision(route: "LLM ile yeniden yorumlanan komut")
        owLog("[Route] llm-rewrite '\(trimmed)' → '\(rewritten)' → \(command)")
        await runCommands(run, [MultiCommandSplitter.Step(text: rewritten, command: command)], output: "yeniden yorumlanan komut")
        return true
    }

    @MainActor private func dictateOrChat(_ run: FinishRun) async {
        let session = run.session
        let trimmed = run.trimmed
        // After a command only a command is taken (see the follow-up check below).
        if session.takesOnlyCommands {
            // A misheard command right after a command ("ekran parlaklığını kız"): the model
            // may still read it as one. Never for words heard only over playback.
            if session.followsCommand, !session.wakeWordUnheard, !session.heardOnlyOverPlayback,
               await runRewrittenCommand(run) { return }
            owLog("[FollowUp] No command after the command; ignored: '\(trimmed)'")
            session.latency.finishDecision(route: "komut sonrası, komut değil")
            dismissFlowBarMessage()
            return
        }
        let front = session.targetApp?.bundleIdentifier
        if session.isVoiceCommand || RemoteControl.screenIsLocked {
            // The lock screen's password field has focus, but nobody dictates into it.
            let focusStatus = RemoteControl.screenIsLocked ? .notEditable : session.routingFocus
            let isQuestion = JarvisAddressee.looksLikeQuestion(trimmed)
            let needsScore = focusStatus == .unknown || (focusStatus == .editable && isQuestion)
            let score = needsScore && (self.ollamaAvailable || SetFitDecider.isActive)
                ? await JarvisAddressee.score(
                    text: trimmed,
                    frontApp: session.targetApp?.localizedName,
                    lastReply: JarvisChat.shared.recentReply,
                    model: self.ollamaModel)
                : nil
            let minScore = JarvisAddressee.minScore
            let route = JarvisAddressee.defaultRoute(
                focusStatus: focusStatus,
                score: score,
                minScore: minScore,
                isQuestion: isQuestion
            )
            owLog("[Addressee] focus \(focusStatus.rawValue), question \(isQuestion), score \(score.map(String.init) ?? "not-used") / threshold \(minScore) → \(route.rawValue) (front: \(front ?? "none"))")
            if route == .chat,
               JarvisAddressee.skipsChat(frontBundleID: front, misheardWordCount: self.misheardWords(in: trimmed).count,
                                         isQuestion: isQuestion) {
                owLog("[Addressee] Lock screen and the text has non-words; not answering: '\(trimmed)'")
                session.latency.finishDecision(route: "kilit ekranı, anlamsız metin")
                return
            }
            // Short sentences are always shown to the model: a misheard command may not look like one.
            if route == .chat, await runRewrittenCommand(run, anyShape: trimmed.split(separator: " ").count <= 10) { return }
            if route == .chat {
                session.latency.finishDecision(route: "Jarvis sohbet")
                await chat(run, trimmed, detail: "Jarvis sohbet")
                return
            }
        }
        await pasteAsDictation(run, trimmed, targetApp: session.targetApp, pasteContext: session.pasteContext, send: false)
    }
}
