import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    func finishTranscription(_ session: RecordingTranscriptionSession) async {
        guard !session.hasFinished else { return }
        session.hasFinished = true
        // Set when a command ran: listen a moment longer for a fix ("sonrakine geç"). Declared
        // first so it runs last, once the media and recording state below are settled.
        var commandFollowUp: CommandFollowUp.Domain?? = nil
        // A new, empty Claude Code / Codex chat was opened: keep listening for its first message.
        var developerSessionApp: NSRunningApplication?
        // Opened already as Jarvis's reply started (`speakAfterCommand`).
        var followUpOpenedOverReply = false
        defer {
            if let app = developerSessionApp, !session.isCancelled,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
               recordingState != .recording, hotkey?.isIdle == true, microphoneGranted {
                pendingCommandFollowUp = nil
                pendingClaudeMessage = nil
                pendingWakeSpeakerVerified = session.wakeSpeakerVerified
                startVoiceSession(trigger: .jarvisKey)
            } else if let commandFollowUp, !followUpOpenedOverReply {
                listenAfterCommand(domain: commandFollowUp, after: session)
            }
        }
        // Media paused when a voice session started plays again only after its command
        // (or dictation) is done, on every exit path below. A recording started meanwhile
        // owns the pause now and releases it when it stops.
        var resumeMediaAfterCommand = true
        // A follow-up question (deletion confirmation) keeps the music paused through the
        // answer; that session's own finish resumes it.
        var holdMediaForFollowUp = false
        // Same for a chat answer that asks something back (see `listenForReplyAnswer`).
        var holdMediaForReplyAnswer = false
        defer {
            // The follow-up opened over the reply leaves media alone; this session still owns it.
            let recordingIsOwnFollowUp = followUpOpenedOverReply && activeTranscriptionSession?.followsCommand == true
            if session.isVoiceCommand && (recordingState != .recording || recordingIsOwnFollowUp)
                && !holdMediaForFollowUp && !holdMediaForReplyAnswer {
                recordingMedia.end(resuming: resumeMediaAfterCommand)
            }
        }
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
            lastError = "Ses geçmişi tamamlanamadı: \(error.localizedDescription)"
            owLog("[RecordingHistory] Finish failed: \(error)")
        }
        // Only kept recordings get a trace: it lives and is pruned next to their audio.
        let traceID = recordingID.flatMap { id in savedRecordings.contains { $0.id == id } ? id : nil }
        SpeechDiagnostics.event("session.recording", ["recordingID": recordingID?.uuidString ?? "none",
            "traceKept": String(traceID != nil), "speech": session.diagnosticID])
        if let traceID {
            VoiceEventLog.shared.begin(traceID, header: [
                "Recording \(traceID.uuidString)",
                "Speech diagnostic ID: \(session.diagnosticID)",
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

        defer {
            // A re-asked confirmation (holdMediaForFollowUp) keeps its plan for the next answer.
            if session.trigger == .confirmation && !holdMediaForFollowUp {
                self.reminderManager?.cancelPendingDeletion()
                self.whatsAppSender.cancel()
            }
            // Break the session ↔ worker reference cycle once the worker has drained the
            // session's stream and the final output step is complete.
            session.task = nil
            pendingTranscriptionCount = max(0, pendingTranscriptionCount - 1)
            if transcriptionQueueTailID == session.id {
                transcriptionQueueTail = nil
                transcriptionQueueTailID = nil
            }
            if recordingState != .recording {
                recordingState = pendingTranscriptionCount > 0 ? .transcribing : .idle
            }
        }

        await SpeechDiagnostics.$session.withValue(session.diagnosticID) {
        await SpeechDiagnostics.$outcome.withValue(session.diagnosticOutcome) {
        await VoiceTrace.$current.withValue(traceID) {
            defer {
                var summary = session.diagnosticOutcome.summary
                summary["cancelled"] = String(session.isCancelled)
                summary["acceptedTexts"] = String(session.segmentTexts.count)
                summary["batches"] = String(session.nextSegmentNumber)
                summary["scope"] = "routing_finished; later async events retain this speech ID"
                SpeechDiagnostics.event("session.summary", summary)
            }
            defer {
                let outcome = session.diagnosticOutcome.summary
                session.latency.finishIfNeeded(outcome["assessment"] == "no_action_result_reported"
                    ? "işlem yapılmadı: \(outcome["reasons"] ?? "neden kaydedilmedi")"
                    : "yönlendirme bitti; sonuçlar session.summary kaydında")
            }
            guard !session.isCancelled else {
                SpeechDiagnostics.event("output.skipped", ["reason": "session_cancelled"])
                return
            }
            // The weak-wake check may fail after a batch was already transcribed: the video called.
            if session.segmentTexts.isEmpty, !session.playbackCommandTexts.isEmpty, !session.hadFailClosedPassthrough,
               !session.wakeUnconfirmed {
                session.segmentTexts = session.playbackCommandTexts
                session.heardOnlyOverPlayback = true
                owLog("[OpenWhisper] No batch matched your voice over the media; taking a command only")
            }
            if !session.hadFailClosedPassthrough && !session.heardOnlyOverPlayback &&
                (session.hadSingleSpeakerUncertain ||
                 (session.hadDiarizationAttempt && session.segmentTexts.isEmpty) ||
                 TargetSpeakerOutputGate.shouldSkipPostProcessing(
                     featureEnabled: session.targetSpeakerEnabled,
                     acceptedSampleCount: session.acceptedTargetSpeechSamples
                 )) {
                SpeechDiagnostics.event("output.skipped", ["reason": "speaker_gate_rejected",
                    "acceptedSamples": String(session.acceptedTargetSpeechSamples),
                    "uncertain": String(session.hadSingleSpeakerUncertain),
                    "diarizationFailed": String(session.hadDiarizationFailure),
                    "followUp": String(session.followsCommand)])
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
                        mic: session.targetSpeakerMic,
                        session: session
                    )
                    SpeechDiagnostics.event("action.result", ["result": textInjector == nil ? "clipboard_unavailable" : "candidate_copied_for_confirmation"])
                    textInjector?.copyToClipboard(rawCandidateText)
                    showTargetSpeakerAppendOffer(message: "")
                    owLog("[OpenWhisper] Near-threshold candidate retained for 'Bu benim sesimdi' confirmation without showing error warning")
                } else if session.hadDiarizationFailure && !session.followsCommand {
                    let status = "Sesini doğrulayamadım; mesaj gönderilmedi. Fn tuşuyla tekrar deneyebilirsin."
                    lastError = status
                    session.latency.markOutput("konuşmacı doğrulanamadı; gönderilmedi")
                    owLog("[TargetSpeaker] No output after diarization failure; notifying the user")
                    showFlowBarMessage(status, durationMs: 6000)
                    if session.isVoiceCommand { await speakReply(status) }
                } else {
                    dismissFlowBarMessage()
                }
                return
            }
            guard !session.appliesSpeechChecks || session.queuedSampleCount >= 6400 else {
                SpeechDiagnostics.event("output.skipped", ["reason": "[OpenWhisper] Audio too short (\(session.queuedSampleCount) samples < 0.4s)"])
                owLog("[OpenWhisper] Audio too short (\(session.queuedSampleCount) samples < 0.4s)")
                return
            }

            // Mangled names ("Sputfayda" → "Spotify'da") fixed before routing, so a command is
            // still recognized; the list is the user's ses-benzerleri.txt.
            // Wake sessions now start at the wake itself, so the tail of "Jarvis" can be heard.
            let joined = AudioSegmentation.joinTranscripts(session.segmentTexts)
            SpeechDiagnostics.text("transcript.joined", joined)
            // A follow-up opened over Jarvis's reply heard the reply first, and may itself
            // start with "Hey Jarvis," (voice test 2026-10-22).
            let spoken = session.trigger == .wakeWord ? WakeWordVerifier.strippingLeadingWakeWord(joined)
                : session.followsCommand || session.isConversationFollowUp
                    ? WakeWordVerifier.strippingLeadingWakeWord(CommandFollowUp.removingEcho(of: session.precedingReply, from: joined))
                : joined
            SpeechDiagnostics.text("transcript.afterWakeEcho", spoken, previous: joined)
            if spoken != joined { owLog("[WakeWord] Removed the wake word from the transcript start: \(joined)") }
            // The app in front comes first: its ses-benzerleri.txt section ("cloud" → Claude in
            // Claude), its name in app matching and in the cleanup model's terms.
            let soundAlikeEntries = SoundAlikeCorrector.loadEntries()
            let focus = AppFocus(app: session.targetApp, entries: soundAlikeEntries)
            let (text, soundAlikes) = session.appliesSpeechChecks
                ? SoundAlikeCorrector.correct(spoken, entries: AppFocus.soundAlikeEntries(soundAlikeEntries, focus: focus),
                                              keeping: GlossaryStore.multiWordTerms())
                : (spoken, [])
            for (heard, written) in soundAlikes { owLog("[SoundAlike] \(heard) → \(written)") }
            SpeechDiagnostics.text("transcript.afterSoundAlikes", text, previous: spoken)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("[BLANK"),
                  !trimmed.hasPrefix("(BLANK") else {
                SpeechDiagnostics.event("output.skipped", ["reason": "[OpenWhisper] Empty/blank transcription, skipping"])
                owLog("[OpenWhisper] Empty/blank transcription, skipping")
                return
            }
            guard !session.appliesSpeechChecks || !AudioSegmentation.isRepetitionHallucination(trimmed) else {
                SpeechDiagnostics.event("output.skipped", ["reason": "[OpenWhisper] Repeated-word hallucination, skipping: \(trimmed)"])
                owLog("[OpenWhisper] Repeated-word hallucination, skipping: \(trimmed)")
                return
            }
            guard !session.appliesSpeechChecks
                    || !ForeignTranscriptGuard.isForeign(trimmed, misheardCount: misheardWords(in: trimmed).count) else {
                SpeechDiagnostics.event("output.skipped", ["reason": "[OpenWhisper] Not Turkish or English, nothing pasted or run: \(trimmed)"])
                owLog("[OpenWhisper] Not Turkish or English, nothing pasted or run: \(trimmed)")
                if session.followsCommand {
                    dismissFlowBarMessage()
                } else {
                    // A voice session that asks "tekrar söyler misin?" must also listen for it.
                    let ask = "Anlaşılamadı, tekrar söyler misin?"
                    if listenForReplyAnswer(ask, heard: false, after: session) {
                        holdMediaForReplyAnswer = true
                    } else {
                        showFlowBarMessage(ask)
                    }
                }
                return
            }

            owLog("[OpenWhisper] Raw: \(text)")
            session.latency.beginDecision()
            correctionGeneration &+= 1
            let generation = correctionGeneration

            var agentDeliveryFailure: String?

            /// Pastes `rawText` (after learned/phonetic corrections) into `targetApp`. With
            /// `send`, presses Return once the paste landed, for coding agents: the text is
            /// then gone from the field, so the swap, snapshot and LLM cleanup steps are skipped.
            @MainActor
            /// True once the text is in the target, and, with `send`, Return went to it.
            @discardableResult
            func pasteAsDictation(
                _ rawText: String,
                targetApp: NSRunningApplication?,
                pasteContext: PasteContext,
                send: Bool
            ) async -> Bool {
                var pasteContext = pasteContext
                agentDeliveryFailure = nil
                // Never type into the lock screen.
                guard !RemoteControl.screenIsLocked else {
                    SpeechDiagnostics.event("action.result", ["result": "[Result] Screen locked; nothing pasted"])
                    owLog("[Result] Screen locked; nothing pasted")
                    session.latency.finishDecision(route: "Mac kilitli")
                    await self.speakReply(self.jarvisReply.answer(RemoteControl.lockedAnswer))
                    return false
                }
                session.latency.finishDecision(route: send ? "agent yazma" : "dikte")
                let preprocessingStartedAt = session.latency.timestamp()
                var initialText = rawText

                SpeechDiagnostics.text("dictation.input", rawText)
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

                SpeechDiagnostics.text("dictation.afterLearnedCorrections", initialText, previous: rawText)
                let (phoneticCorrected, phoneticApplied) = PhoneticGlossaryCorrector.correct(initialText)
                SpeechDiagnostics.text("dictation.afterPhoneticGlossary", phoneticCorrected, previous: initialText)
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

                initialText = await self.formatTurkishDictation(initialText)
                initialText = TranscriptSanitizer.removeForbiddenArtifacts(from: initialText)
                session.latency.record(.preprocessing, since: preprocessingStartedAt)
                guard !initialText.isEmpty else {
                    SpeechDiagnostics.event("output.skipped", ["reason": "[OpenWhisper] Forbidden-only transcript blocked before output"])
                    owLog("[OpenWhisper] Forbidden-only transcript blocked before output")
                    return false
                }
                self.lastTranscription = initialText
                let misheard = self.misheardWords(in: initialText)
                if !misheard.isEmpty {
                    owLog("[Misheard] Not Turkish or English: \(misheard.map(\.text))")
                }

                // Return can only be pressed in the frontmost app. If the user moved to another
                // app (or full-screen Space) after "gönder", hop to the target, send there, and
                // go straight back to where they were.
                var hopFrom: NSRunningApplication?
                if self.autoPasteEnabled, send,
                   let target = targetApp, !target.isTerminated,
                   let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != target.processIdentifier {
                    SpeechDiagnostics.event("action.result", ["result": "[Result] Send target is in the background; switching to \(target.localizedName ?? "?") to send, then back to \(front.localizedName ?? "?")"])
                    owLog("[Result] Send target is in the background; switching to \(target.localizedName ?? "?") to send, then back to \(front.localizedName ?? "?")")
                    if await AgentAppActivator.bringToFront(target) {
                        hopFrom = front
                    }
                }
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

                // Confirmation must use the cursor captured before speech, never a field
                // that appeared when the user clicked the confirmation chip.
                if session.speakerConfirmedByUser, pasteContext.focusStatus != .editable {
                    if let injector = self.textInjector { injector.copyToClipboard(initialText) }
                    else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(initialText, forType: .string)
                    }
                    self.showFlowBarMessage("Panoya kopyalandı — kayıt başında imleç yoktu", durationMs: 4500)
                    SpeechDiagnostics.event("action.result", ["result": "confirmed_dictation_copied_no_original_cursor"])
                    session.latency.markOutput("panoya kopyalandı")
                    goBack()
                    return false
                }

                if self.autoPasteEnabled, RecordedConversation.requiresBinding(pasteContext.bundleIdentifier) {
                    guard let app = targetApp, let conversation = pasteContext.conversation,
                          await conversation.restore(in: app) else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(initialText, forType: .string)
                        let reason = pasteContext.conversation == nil
                            ? "Kayıt başında sohbet kimliği alınamadı"
                            : "Kaydın başladığı sohbete dönülemedi"
                        agentDeliveryFailure = reason
                        self.lastError = "\(reason). Metin panoya kopyalandı."
                        self.showFlowBarMessage("\(reason). Panoya kopyalandı.", durationMs: 4500)
                        session.latency.markOutput(reason)
                        SpeechDiagnostics.event("output.skipped", ["reason": "[Agent] Delivery blocked: \(reason)"])
                        owLog("[Agent] Delivery blocked: \(reason)")
                        goBack()
                        return false
                    }
                    // The old composer may have been destroyed while another chat was open.
                    pasteContext = PasteContext.capture(targetApp: app)
                    pasteContext.conversation = conversation
                }

                if self.autoPasteEnabled {
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
                        Task { @MainActor in SpeechDiagnostics.withTrace(session.diagnosticID, recording: traceID, outcome: session.diagnosticOutcome) {
                            guard let self else { return }
                            session.latency.record(.paste, since: pasteStartedAt, detail: "\(outcome)")
                            session.latency.markOutput("\(outcome)")
                            SpeechDiagnostics.text("delivery.pasteText", initialText)
                            SpeechDiagnostics.event("delivery.result", ["outcome": String(describing: outcome), "target": targetApp?.bundleIdentifier ?? "unknown"])
                            SpeechDiagnostics.event("action.result", ["result": "[Result] Paste into \(targetApp?.bundleIdentifier ?? "unknown"): \(outcome) — '\(initialText)'"])
                            owLog("[Result] Paste into \(targetApp?.bundleIdentifier ?? "unknown"): \(outcome) — '\(initialText)'")
                            switch outcome {
                            case .pastedVerified where send, .pastedUnverified where send:
                                self.swapPair = nil
                                self.swapPasteContext = nil
                                self.hotkey?.setSwapAvailable(false)
                                // Electron composers and CLI bracketed paste need a moment to
                                // take the paste before Return, or only part of it is sent.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
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
                                            sent = await injector.pressReturnBringingToFront(pid: pid, context: pasteContext)
                                        }
                                        // A posted Return proves nothing if Claude was not ready:
                                        // a sent message leaves the composer.
                                        if sent, let app = targetApp, !app.isTerminated,
                                           app.bundleIdentifier.map(AgentApp.claudeCode.bundleIdentifiers.contains) ?? false,
                                           NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                                           await ClaudeSessionNavigator.composerStillHolds(app, text: initialText) {
                                            SpeechDiagnostics.event("action.result", ["result": "[Result] Return pressed but the text is still in Claude's composer"])
                                            owLog("[Result] Return pressed but the text is still in Claude's composer")
                                            sent = false
                                        }
                                        SpeechDiagnostics.event("action.result", ["result": "[Result] Agent message \(sent ? "sent" : "pasted, Return skipped")"])
                                        owLog("[Result] Agent message \(sent ? "sent" : "pasted, Return skipped")")
                                        if let traceID {
                                            VoiceEventLog.shared.append(traceID, "[Result] Agent message \(sent ? "sent" : "pasted, Return skipped")")
                                        }
                                        self.showFlowBarMessage(sent ? "gönderildi" : "yazıldı, gönderilmedi", durationMs: 1200)
                                        finish(sent)
                                        // Wait a beat so the app takes the Return before losing focus.
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { goBack() }
                                    }
                                }
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
                                    Task { @MainActor [weak self] in
                                        guard let self else { return }
                                        let cleanupStartedAt = session.latency.timestamp()
                                        let cleaned = await self.llmCleanup?.cleanup(text: initialText, misheard: misheard, focus: focus) ?? initialText
                                        session.latency.record(.cleanup, since: cleanupStartedAt)
                                        let formatted = await self.formatTurkishDictation(cleaned)
                                        SpeechDiagnostics.text("cleanup.modelOutput", cleaned, previous: initialText)
                                        SpeechDiagnostics.text("cleanup.formatted", formatted, previous: cleaned)
                                        let trimmedCleaned = formatted.trimmingCharacters(in: .whitespacesAndNewlines)

                                        guard !trimmedCleaned.isEmpty, trimmedCleaned != initialText else { return }
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
                                                SpeechDiagnostics.withTrace(session.diagnosticID, recording: traceID, outcome: session.diagnosticOutcome) {
                                                    SpeechDiagnostics.text("delivery.cleanupReplacement", trimmedCleaned, previous: initialText)
                                                }
                                                owLog("[OpenWhisper] Async LLM replacement finished.")
                                                if let traceID {
                                                    VoiceEventLog.shared.append(traceID, "[Result] Replaced pasted text with cleanup: '\(trimmedCleaned)'")
                                                }
                                            }
                                        }
                                    }
                                }
                            case .clipboardOnly(let reason):
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
                        if !finished {
                            SpeechDiagnostics.event("output.skipped", ["reason": "paste_callback_timeout"])
                            owLog("[Result] Paste result never came back; reporting not delivered")
                        }
                        finish(false)
                    }
                    }
                } else {
                    guard let textInjector = self.textInjector else {
                        SpeechDiagnostics.event("output.skipped", ["reason": "text_injector_unavailable"])
                        return false
                    }
                    textInjector.copyToClipboard(initialText)
                    SpeechDiagnostics.event("action.result", ["result": "[Result] Auto-paste off, copied to clipboard: '\(initialText)'"])
                    owLog("[Result] Auto-paste off, copied to clipboard: '\(initialText)'")
                    session.latency.markOutput("panoya kopyalandı")
                    if session.speakerConfirmedByUser {
                        self.showFlowBarMessage("Panoya kopyalandı", durationMs: 4500)
                    }
                    return false
                }
            }

            // What the rules need for the command routes. Built only when one is reached:
            // it lists the installed apps.
            let timers = TimerManager.shared
            @MainActor func commandContext() -> CommandRegistry.Context {
                CommandRegistry.Context(
                    ringing: timers.ringing != nil, timerActive: !timers.timers.isEmpty,
                    installedApps: focus.map { $0.frontFirst(SystemController.installedApps()) } ?? SystemController.installedApps(),
                    shortcuts: SystemController.shortcutNames)
            }

            /// Runs the steps in order and answers once for all of them.
            @MainActor func runCommands(_ steps: [MultiCommandSplitter.Step<VoiceCommand>], output: String) async {
                self.lastTranscription = text
                let actionStartedAt = session.latency.timestamp()
                var statuses: [String] = []
                var replies: [String?] = []
                // After "Safari'ye geç", later steps belong to the app switched to: Spotify gives
                // focus back to this app if a cold launch stole it.
                var stepTargetApp = session.targetApp
                var ran: [VoiceCommand] = []
                for step in steps {
                    guard !session.isCancelled, !Task.isCancelled,
                          !CloudReasoning.enabled || self.nextTranscriptionID == session.id else { return }
                    SpeechDiagnostics.event("action.begin", ["command": String(describing: step.command)])
                    switch step.command {
                    case .timer(let timerCommand):
                        let status: String
                        // A wall-clock alarm goes to the Clock app, which rings it even without Jarvis;
                        // Jarvis keeps it only when that can't be done (no shortcut, more than a day away).
                        if case .alarm(let date, let label) = timerCommand, ClockAlarm.canSet(date),
                           await ClockAlarm.set(date, label: label) {
                            status = "Saat uygulamasına alarm kurdum: \(TimerManager.clock(date, sayDay: true))"
                        } else {
                            status = timers.perform(timerCommand)
                        }
                        SpeechDiagnostics.event("action.result", ["result": "[Result] Timer: \(status)"])
                        owLog("[Result] Timer: \(status)")
                        ran.append(step.command)
                        statuses.append(status)
                        replies.append(self.jarvisReply.timer(timerCommand, status: status))
                    case .system(let command):
                        if step.command.endsSession {
                            // Say everything before the Mac stops listening.
                            if session.isVoiceCommand {
                                await self.speakReply(self.jarvisReply.combined(replies + ["Görüşürüz."]))
                            }
                            replies = []
                        }
                        // The local model takes several seconds on a long page.
                        if command == .browser(.summarize) { self.showFlowBarMessage("Sayfa özetleniyor…", durationMs: 30000) }
                        var status = await SystemController.perform(command)
                        if command == .developerMode {
                            if let app = await AgentAppActivator.activate(.claudeCode),
                               await ClaudeSessionNavigator.openNewSession(app) {
                                developerSessionApp = app
                                status += " · Claude Code’da yeni sohbet hazır"
                            } else {
                                status += " · Claude Code’da yeni sohbet açılamadı"
                            }
                        }
                        // Liked Songs now play; don't resume what the session paused over them.
                        if command == .developerMode { resumeMediaAfterCommand = false }
                        // "Videoyu durdur / devam ettir" decided the state; a seek or speed change
                        // lets the video the recording paused continue, and so does a failed command.
                        if case .video(let action) = command, action.changesPlayback,
                           !VideoController.failures.contains(status) { resumeMediaAfterCommand = false }
                        switch command {
                        case .switchToApp, .switchToAgent: stepTargetApp = NSWorkspace.shared.frontmostApplication
                        default: break
                        }
                        SpeechDiagnostics.event("action.result", ["result": "[Result] System command: \(status)"])
                        owLog("[Result] System command: \(status)")
                        ran.append(step.command)
                        statuses.append(status)
                        if !step.command.endsSession { replies.append(self.jarvisReply.system(command, status: status)) }
                    case .spotify(let request):
                        let resumes = SpotifyManager.resumesPausedMedia(afterCommand: request)
                        let likedSongs = SpotifyManager.playsLikedSongs(afterCommand: request)
                        let speaksResult = SpotifyManager.speaksResult(afterCommand: request)
                        let speaksFailure = SpotifyManager.speaksFailure(afterCommand: request)
                        let handled = await SpotifyManager.shared.handleCommand(text: request, targetApp: stepTargetApp)
                        let message = SpotifyManager.shared.takeResultMessage(for: request)
                        SpeechDiagnostics.event("action.result", ["result": "[Result] Spotify command \(handled ? "handled" : "not applied"): '\(request)'"])
                        owLog("[Result] Spotify command \(handled ? "handled" : "not applied"): '\(request)'")
                        if handled, !resumes { resumeMediaAfterCommand = false }
                        if handled { ran.append(step.command) }
                        statuses.append(handled ? "Spotify: \(step.text)" : "Spotify komutu uygulanamadı")
                        if handled {
                            replies.append(speaksResult ? message.map { self.jarvisReply.spotifyResult($0) }
                                : self.jarvisReply.spotify(handled: true, likedSongs: likedSongs))
                        } else {
                            replies.append(self.jarvisReply.failure(speaksFailure ? message ?? "Spotify komutunu uygulayamadım" : "Spotify komutunu uygulayamadım"))
                        }
                    case .agent:
                        // Never a step: `CommandRegistry` keeps agent dictation on its own route.
                        owLog("[Route] agent dictation reached the command runner; skipped")
                    }
                }
                session.latency.record(.action, since: actionStartedAt, detail: output)
                session.latency.markOutput("\(output) tamamlandı")
                let summary = statuses.joined(separator: " · ")
                // A lone Mac action is a short confirmation; a timer or a list stays a bit longer.
                let lone: Bool
                if steps.count == 1, case .system = steps[0].command { lone = true } else { lone = false }
                if !summary.isEmpty {
                    self.showFlowBarMessage(summary, durationMs: summary.count > 40 ? 6000 : lone ? 2500 : 3500)
                }
                // The Mac stops listening after sleep / lock; developer mode is a whole setup.
                if !ran.isEmpty, !ran.contains(where: { $0.endsSession || $0 == .system(.developerMode) }) {
                    commandFollowUp = .some(ran.reversed().lazy.compactMap(CommandFollowUp.domain(of:)).first)
                }
                if session.isVoiceCommand { await speakAfterCommand(self.jarvisReply.combined(replies)) }
            }

            /// Says a command's reply; the follow-up window (`commandFollowUp`) opens as the
            /// voice starts and lasts until 2 s after it. Without a voice the defer opens it.
            @MainActor func speakAfterCommand(_ reply: String?) async {
                await self.speakReply(reply) {
                    guard let commandFollowUp, !followUpOpenedOverReply else { return }
                    followUpOpenedOverReply = self.listenAfterCommand(domain: commandFollowUp, after: session, overReply: true)
                }
                if followUpOpenedOverReply { self.commandFollowUpReplyEnded() }
            }

            /// Answers with the chat model and, when the answer asks something back, listens.
            @MainActor func chat(_ chatText: String, recalled: [String] = [], detail: String) async {
                self.lastTranscription = text
                let actionStartedAt = session.latency.timestamp()
                let answer = await self.chatReply(to: chatText, recalled: recalled,
                    continuingReply: session.isConversationFollowUp && session.addresseeClarification == nil
                        ? session.precedingReply : nil)
                self.pendingYouTubeRequest.remember(user: chatText, reply: answer.text ?? "")
                session.latency.record(.action, since: actionStartedAt, detail: detail)
                session.latency.markOutput("Jarvis cevabı")
                if self.listenForReplyAnswer(answer.text, heard: answer.heard, after: session) {
                    holdMediaForReplyAnswer = true
                }
            }

            /// Speaks `reply`, or shows it when the voice can't be heard.
            @MainActor func say(_ reply: String, durationMs: Int) async {
                if !(await self.speakReply(reply)) { self.showFlowBarMessage(reply, durationMs: durationMs) }
            }

            /// Says a WhatsApp status; a read-back draft then listens for "evet" / "hayır".
            @MainActor func sayWhatsApp(_ prepared: WhatsAppSender.Prepared) async {
                switch prepared {
                case .confirm(let prompt):
                    SpeechDiagnostics.event("action.result", ["result": "[Result] WhatsApp draft read back, awaiting confirmation"])
                    owLog("[Result] WhatsApp draft read back, awaiting confirmation")
                    let heard = await self.speakReply(prompt)
                    askFollowUp(prompt, heard: heard)
                case .done(let status):
                    SpeechDiagnostics.event("action.result", ["result": "[Result] WhatsApp: \(status)"])
                    owLog("[Result] WhatsApp: \(status)")
                    await say(status, durationMs: 5000)
                }
            }

            /// Keeps the paused media paused while a follow-up question waits for its answer,
            /// with a safety net if the answer's recording never starts.
            @MainActor func askFollowUp(_ prompt: String, heard: Bool) {
                // Typed: the answer is typed too; closing the panel unanswered drops the plan,
                // as a silent confirmation window does.
                if session.trigger == .typed {
                    self.openTypedRequestPanel(prompt: prompt) { [weak self] in
                        self?.reminderManager?.cancelPendingDeletion()
                        self?.whatsAppSender.cancel()
                    }
                    return
                }
                holdMediaForFollowUp = true
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

            let applicationCommands = JarvisAddressee.usesApplicationCommands(
                acceptsCommands: session.acceptsCommands, focus: session.routingFocus,
                bundleID: session.targetApp?.bundleIdentifier)

            // For a Jarvis session that is not a command, keyboard focus is the primary signal:
            // editable means dictation (unless the model says a question is for Jarvis), known
            // non-editable means chat. The LLM is otherwise only a fallback when Accessibility
            // could not determine the focus. Dictation keys also take commands outside text fields.
            @MainActor func dictateOrChat() async {
                // One shared encoder supplies all heads. Only a short, explicit, unambiguous
                // prediction may become a command; target and action guards remain rule-owned.
                if session.isVoiceCommand || session.takesOnlyCommands || applicationCommands,
                   trimmed.count <= 200, CommandRewriter.looksLikeCommand(trimmed),
                   !SharedCommandResolver.isNarrationOrNegation(trimmed.lowercased(with: Locale(identifier: "tr_TR"))) {
                    let bundle = session.targetApp?.bundleIdentifier?.lowercased() ?? ""
                    let appCategory = AgentApp.isAgentFront(bundle) ? "agent"
                        : ["whatsapp", "mail", "messages", "slack", "telegram"].contains(where: bundle.contains) ? "messaging"
                        : ["safari", "chrome", "firefox", "brave", "edge"].contains(where: bundle.contains) ? "browser"
                        : bundle.isEmpty ? "unknown" : "other"
                    let focus = session.routingFocus == .editable ? "editable"
                        : session.routingFocus == .notEditable ? "not_editable" : "unknown"
                    let last = session.commandFollowUpDomain == .music ? "music"
                        : session.commandFollowUpDomain == .video ? "video"
                        : session.commandFollowUpDomain == .youtubeList ? "youtube_list" : "none"
                    let modelContext = ["mode": session.isVoiceCommand ? "voice" : "keys", "focus": focus,
                        "app": appCategory, "pending": "none", "last": last]
                    if let decisions = await SetFitDecider.decideAll(text: trimmed, context: modelContext),
                       let command = SharedCommandResolver.resolve(trimmed, decisions: decisions,
                           context: commandContext(), frontBundleID: session.targetApp?.bundleIdentifier) {
                        session.latency.finishDecision(route: "ortak karar modeli")
                        owLog("[Route] shared-model '\(trimmed)' → \(command)")
                        await runCommands([MultiCommandSplitter.Step(text: trimmed, command: command)], output: "komut")
                        return
                    }
                }
                // Resolve misheard installed-app requests even when a text field has focus
                // or this is the command-only follow-up. Fn dictation never reaches the model.
                if (session.isVoiceCommand || session.takesOnlyCommands || applicationCommands), self.ollamaAvailable,
                   let command = await CommandRewriter.appCommand(
                       trimmed, installedApps: commandContext().installedApps, model: self.ollamaModel) {
                    session.latency.finishDecision(route: "LLM uygulama komutu")
                    owLog("[Route] llm-app '\(trimmed)' → \(command)")
                    await runCommands([MultiCommandSplitter.Step(text: trimmed, command: .system(command))],
                                      output: "uygulama komutu")
                    return
                }
                if session.takesOnlyCommands, applicationCommands, self.ollamaAvailable,
                   CommandRewriter.looksLikeCommand(trimmed),
                   let rewritten = await CommandRewriter.rewrite(trimmed, model: self.ollamaModel,
                       frontApp: applicationCommands ? session.targetApp?.localizedName : nil),
                   let command = CommandRewriter.safeCommand(rewritten, context: commandContext()) {
                    session.latency.finishDecision(route: "komut sonrası yeniden yorumlama")
                    await runCommands([MultiCommandSplitter.Step(text: rewritten, command: command)],
                                      output: "yeniden yorumlanan komut")
                    return
                }
                // After a command only a command is taken (see the follow-up check below).
                if session.takesOnlyCommands {
                    SpeechDiagnostics.event("output.skipped", ["reason": "[FollowUp] No command after the command; ignored: '\(trimmed)'"])
                    owLog("[FollowUp] No command after the command; ignored: '\(trimmed)'")
                    session.latency.finishDecision(route: "komut sonrası, komut değil")
                    dismissFlowBarMessage()
                    return
                }
                if session.isConversationFollowUp, JarvisAddressee.clarificationChoice(trimmed) == .cancel {
                    session.latency.finishDecision(route: "sohbet devamı iptal")
                    await say("Tamam.", durationMs: 1500)
                    return
                }
                if session.speakerConfirmedByUser, !session.isConversationFollowUp {
                    await pasteAsDictation(trimmed, targetApp: session.targetApp,
                                           pasteContext: session.pasteContext, send: false)
                    return
                }
                let front = session.targetApp?.bundleIdentifier
                if session.isVoiceCommand || applicationCommands {
                    // The lock screen's password field has focus, but nobody dictates into it.
                    let focusStatus = RemoteControl.screenIsLocked ? .notEditable : session.routingFocus
                    let isQuestion = JarvisAddressee.looksLikeQuestion(trimmed)
                    let needsScore = !session.isConversationFollowUp && (focusStatus == .unknown || (focusStatus == .editable && (session.isVoiceCommand || isQuestion)))
                    let score = needsScore && (self.ollamaAvailable || SetFitDecider.isActive)
                        ? await JarvisAddressee.score(
                            text: trimmed,
                            frontApp: session.targetApp?.localizedName,
                            lastReply: JarvisChat.shared.recentReply,
                            model: self.ollamaModel)
                        : nil
                    let minScore = JarvisAddressee.minScore
                    let route = session.isVoiceCommand
                        ? JarvisAddressee.voiceRoute(focusStatus: focusStatus, score: score, minScore: minScore,
                                                     continuingConversation: session.isConversationFollowUp)
                        : JarvisAddressee.defaultRoute(focusStatus: focusStatus, score: score,
                                                      minScore: minScore, isQuestion: isQuestion)
                    if route == .clarify {
                        session.latency.finishDecision(route: "muhatap açıklaması bekleniyor")
                        let prompt = "Bana mı söyledin, yazmamı mı istedin?"
                        let heard = await self.speakReply(prompt)
                        guard !session.isCancelled, self.nextTranscriptionID == session.id,
                              !Task.isCancelled else { return }
                        self.showFlowBarMessage(prompt, durationMs: 6000)
                        self.pendingAddresseeClarification = .init(text: trimmed,
                            targetApp: session.targetApp, pasteContext: session.pasteContext)
                        if self.listenForReplyAnswer(prompt, heard: heard, after: session) {
                            holdMediaForReplyAnswer = true
                        } else {
                            self.pendingAddresseeClarification = nil
                        }
                        return
                    }
                    owLog("[Addressee] focus \(focusStatus.rawValue), question \(isQuestion), score \(score.map(String.init) ?? "not-used") / threshold \(minScore) → \(route.rawValue) (front: \(front ?? "none"))")
                    if route == .chat,
                       JarvisAddressee.skipsChat(frontBundleID: front, misheardWordCount: self.misheardWords(in: trimmed).count) {
                        SpeechDiagnostics.event("output.skipped", ["reason": "[Addressee] Lock screen and the text has non-words; not answering: '\(trimmed)'"])
                        owLog("[Addressee] Lock screen and the text has non-words; not answering: '\(trimmed)'")
                        session.latency.finishDecision(route: "kilit ekranı, anlamsız metin")
                        return
                    }
                    // Sounds like a command no rule caught: let the model rephrase it, and run
                    // it only if a rule then recognises the rephrased sentence.
                    if route == .chat, self.ollamaAvailable, CommandRewriter.looksLikeCommand(trimmed),
                       let rewritten = await CommandRewriter.rewrite(trimmed, model: self.ollamaModel,
                       frontApp: applicationCommands ? session.targetApp?.localizedName : nil) {
                        if let command = CommandRewriter.safeCommand(rewritten, context: commandContext()) {
                            session.latency.finishDecision(route: "LLM ile yeniden yorumlanan komut")
                            owLog("[Route] llm-rewrite '\(trimmed)' → '\(rewritten)' → \(command)")
                            await runCommands([MultiCommandSplitter.Step(text: rewritten, command: command)], output: "yeniden yorumlanan komut")
                            return
                        }
                        owLog("[Route] llm-rewrite '\(trimmed)' → '\(rewritten)' recognised by no rule; chatting")
                    }
                    if route == .chat {
                        session.latency.finishDecision(route: "Jarvis sohbet")
                        await chat(trimmed, detail: "Jarvis sohbet")
                        return
                    }
                }
                await pasteAsDictation(trimmed, targetApp: session.targetApp, pasteContext: session.pasteContext, send: false)
            }

            if let request = session.addresseeClarification, request.isFresh(),
               ["evet", "tamam"].contains(trimmed.lowercased(with: Locale(identifier: "tr_TR"))
                    .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))) {
                let prompt = "Sana söyledim veya bunu yaz diyebilirsin."
                let heard = await self.speakReply(prompt)
                guard !session.isCancelled, self.nextTranscriptionID == session.id, !Task.isCancelled else { return }
                self.pendingAddresseeClarification = request
                if self.listenForReplyAnswer(prompt, heard: heard, after: session) {
                    holdMediaForReplyAnswer = true
                } else {
                    self.pendingAddresseeClarification = nil
                }
                return
            }

            if let request = session.addresseeClarification, request.isFresh(),
               let choice = JarvisAddressee.clarificationChoice(trimmed) {
                session.latency.finishDecision(route: "muhatap açıklaması")
                switch choice {
                case .chat:
                    await chat(request.text, detail: "açıklanan Jarvis sohbeti")
                case .type:
                    await pasteAsDictation(request.text, targetApp: request.targetApp,
                                           pasteContext: request.pasteContext, send: false)
                case .cancel:
                    await say("Tamam, iptal ettim.", durationMs: 2000)
                }
                return
            }

            // The rules decide where the transcript goes (`VoiceRouter`, in their order); this
            // runs the decision.
            var facts = VoiceRouter.Facts(
                isVoiceCommand: session.isVoiceCommand || session.speakerConfirmedByUser,
                acceptsCommands: session.acceptsCommands,
                focus: session.routingFocus,
                hasTargetApp: session.targetApp != nil,
                targetBundleID: session.targetApp?.bundleIdentifier,
                greetingAfterWake: session.recoversWakeGreeting,
                hasWorkRecap: !session.takesOnlyCommands && session.greetingWorkContext?.isFresh() == true,
                pendingDeletion: self.reminderManager?.hasPendingDeletion ?? false,
                pendingWhatsAppSend: self.whatsAppSender.hasPending,
                voiceTestActive: self.voiceTest.isActive,
                commandAmongPlayback: session.heardOnlyOverPlayback,
                commandContext: commandContext)
            if session.isVoiceCommand {
                let confirmed = self.pendingYouTubeRequest.take(for: trimmed)
                if let confirmed, !facts.pendingDeletion, !facts.pendingWhatsAppSend,
                   !session.sendsToRecappedClaudeSession {
                    session.latency.finishDecision(route: "YouTube isteği onaylandı")
                    await runCommands([MultiCommandSplitter.Step(text: trimmed, command: .system(.browser(confirmed)))], output: "YouTube")
                    return
                }
            }
            // The mic opened after a Claude session recap: all of it is the message for that
            // session, unless the user called it off ("boş ver", "vazgeç").
            if session.sendsToRecappedClaudeSession, ClaudeSessionRecap.isCancel(trimmed) {
                session.latency.finishDecision(route: "Claude mesajı iptal")
                owLog("[Agent] Claude recap message called off: '\(trimmed)'")
                await say("Tamam, göndermedim.", durationMs: 3000)
                return
            }
            var route = session.sendsToRecappedClaudeSession
                ? .agent(AgentDictation(target: .claudeCode, body: trimmed, send: true, session: .last))
                : VoiceRouter.route(text, facts: facts)
            let isWorkContinuation: Bool
            if case .workResume = route { isWorkContinuation = true } else { isWorkContinuation = false }
            if !CloudReasoning.enabled, session.acceptsCommands, !session.sendsToRecappedClaudeSession,
               !facts.pendingDeletion, !facts.pendingWhatsAppSend, !RemoteControl.screenIsLocked,
               let selection = UnreadSessionRecap.selection(trimmed) {
                session.latency.finishDecision(route: "okunmamış sohbet özeti")
                self.lastTranscription = text
                await self.readAgentSessions(trimmed, selection: selection, after: session)
                return
            }
            if !CloudReasoning.enabled, session.acceptsCommands, !session.sendsToRecappedClaudeSession, !isWorkContinuation,
               !facts.pendingDeletion, !facts.pendingWhatsAppSend, !RemoteControl.screenIsLocked,
               let reply = await CloudSessionNavigation.handle(trimmed, front: session.targetApp) {
                session.latency.finishDecision(route: "bulut sohbet geçişi")
                self.lastTranscription = text
                if reply == CloudSessionNavigation.newChatOpened, session.isVoiceCommand {
                    developerSessionApp = NSWorkspace.shared.frontmostApplication
                }
                await say(reply, durationMs: 5000)
                return
            }
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
                    SpeechDiagnostics.event("action.result", ["result": "[Result] Reminder deletion confirmation: \(String(describing: confirmation))"])
                    owLog("[Result] Reminder deletion confirmation: \(String(describing: confirmation))")
                    self.lastTranscription = text
                    let reply = self.jarvisReply.reminderDeletion(confirmation)
                    let heard = await self.speakReply(reply)
                    if confirmation == .confirmationUnclear { askFollowUp(reply, heard: heard) }
                    return
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
                    await sayWhatsApp(answer)
                    return
                }
                facts.pendingWhatsAppSend = false
                route = VoiceRouter.route(text, facts: facts)
            }

            var cloudRoutes: [CloudDecisionPlanner.Resolved]?
            if CloudReasoning.enabled, session.acceptsCommands, !session.sendsToRecappedClaudeSession,
               !facts.pendingDeletion, !facts.pendingWhatsAppSend, !facts.commandAmongPlayback {
                let pendingCloud = self.pendingCloudClarification
                self.pendingCloudClarification = nil
                let continuesCloud = session.isConversationFollowUp && pendingCloud.map { Date().timeIntervalSince($0.createdAt) < 20 } == true
                let context = CloudDecisionPlanner.Context(
                    requestID: String(describing: session.id), transcript: trimmed,
                    trigger: session.trigger.rawValue,
                    app: session.targetApp?.localizedName ?? "unknown",
                    bundleID: session.targetApp?.bundleIdentifier ?? "unknown",
                    focus: session.routingFocus.rawValue,
                    caret: session.pasteContext.selectedRangeAtCapture?.location,
                    selectionLength: session.pasteContext.selectedRangeAtCapture?.length,
                    conversationFollowUp: session.isConversationFollowUp,
                    commandsOnly: session.takesOnlyCommands,
                    lastCommand: session.commandFollowUpDomain?.rawValue ?? "none",
                    lastReply: String((session.precedingReply ?? JarvisChat.shared.recentReply ?? "").suffix(600)),
                    hasWorkRecap: facts.hasWorkRecap, installedApps: commandContext().installedApps,
                    localTime: ISO8601DateFormatter().string(from: Date()),
                    previousRequest: continuesCloud ? pendingCloud?.request : nil,
                    clarificationQuestion: continuesCloud ? pendingCloud?.question : nil)
                do {
                    let decision = try await CloudDecisionPlanner.plan(context, facts: facts, client: self.cloudPlanningClient)
                    guard !session.isCancelled, !Task.isCancelled, self.nextTranscriptionID == session.id,
                          self.recordingState != .recording else { return }
                    switch decision {
                    case .routes(let planned):
                        cloudRoutes = planned
                        route = planned[0].route
                        SpeechDiagnostics.event("cloud.plan", ["version": "1", "steps": String(planned.count)])
                    case .clarify(let question):
                        self.pendingCloudClarification = .init(request: continuesCloud ? pendingCloud!.request : trimmed,
                            question: question, createdAt: Date())
                        session.latency.finishDecision(route: "bulut açıklama istiyor")
                        let heard = await self.speakReply(question)
                        self.showFlowBarMessage(question, durationMs: 8000)
                        if self.listenForReplyAnswer(question, heard: heard, after: session) { holdMediaForReplyAnswer = true }
                        return
                    case .cancel:
                        session.latency.finishDecision(route: "bulut iptal")
                        return
                    }
                } catch {
                    guard !session.isCancelled, !Task.isCancelled, self.nextTranscriptionID == session.id else { return }
                    session.latency.finishDecision(route: "bulut planı uygulanmadı")
                    SpeechDiagnostics.event("cloud.plan.rejected", ["reason": String(describing: error)])
                    await say("İsteği güvenle planlayamadım; işlem yapmadım. Tekrar söyler misin?", durationMs: 6000)
                    return
                }
            }

            // Resolve screen-relative requests only in foreground YouTube, preserving explicit commands.
            if cloudRoutes == nil {
            switch route {
            case .spotifyOrConversation, .command(.spotify):
                if (facts.isVoiceCommand || session.takesOnlyCommands || applicationCommands),
                   session.targetApp?.bundleIdentifier == BrowserController.bundleID,
                   let command = await YouTubeVoice.contextual(trimmed) { route = .command(command) }
            default: break
            }

            }

            // The mic stayed open after a command: only a command is taken from it, never
            // dictation or chat (a TV, the song's lyrics, someone else in the room). A bare
            // "sonrakine geç" is about what the command just did.
            if session.takesOnlyCommands {
                var isCommand: Bool {
                    switch route { case .command, .commands: true; default: false }
                }
                if cloudRoutes == nil, !isCommand, let domain = session.commandFollowUpDomain,
                   let fix = CommandFollowUp.resolve(trimmed, after: domain) {
                    owLog("[FollowUp] '\(trimmed)' after a \(domain.rawValue) command → \(fix)")
                    route = .command(fix)
                }
                switch route {
                // Spotify asks the models ("biraz rock bir şey aç"); its dictation and chat
                // fallback is dropped in `dictateOrChat`.
                case .command, .commands, .meta, .voiceTest, .spotifyOrConversation: break
                case .agent(let request) where UnreadSessionRecap.allowsReplySend(
                    request, isRecap: session.isUnreadRecapWindow && !session.heardOnlyOverPlayback,
                    expectedID: session.unreadRecapSessionID,
                    capturedID: session.pasteContext.conversation?.sessionID,
                    capturedAgent: session.pasteContext.conversation?.agent):
                    owLog("[FollowUp] Explicit send to the recapped conversation")
                case .agent(let request) where session.isUnreadRecapWindow && request.send:
                    session.latency.finishDecision(route: "özet sonrası gönderim hedefi doğrulanamadı")
                    await say("Özetlediğim sohbeti doğrulayamadım; mesajı göndermedim.", durationMs: 5000)
                    return
                default:
                    SpeechDiagnostics.event("output.skipped", ["reason": "[FollowUp] No command after the command; ignored: '\(trimmed)'"])
                    owLog("[FollowUp] No command after the command; ignored: '\(trimmed)'")
                    session.latency.finishDecision(route: "komut sonrası, komut değil")
                    dismissFlowBarMessage()
                    return
                }
            }

            for planned in cloudRoutes ?? [.init(source: trimmed, route: route)] {
            guard !session.isCancelled, !Task.isCancelled,
                  cloudRoutes == nil || self.nextTranscriptionID == session.id else { return }
            let route = planned.route
            let text = planned.source
            let trimmed = planned.source.trimmingCharacters(in: .whitespacesAndNewlines)
            SpeechDiagnostics.event("route.selected", ["route": String(describing: route),
                "voice": String(facts.isVoiceCommand), "focus": String(describing: facts.focus),
                "commandsOnly": String(session.takesOnlyCommands)])
            // Locked: nothing can be typed into an app or done on screen. Say so instead of
            // failing silently (or typing into the lock screen); the rest runs as usual.
            if RemoteControl.needsUnlockedScreen(route), RemoteControl.screenIsLocked {
                session.latency.finishDecision(route: "Mac kilitli")
                SpeechDiagnostics.event("output.skipped", ["reason": "[Route] Screen locked; not running: '\(trimmed)'"])
                owLog("[Route] Screen locked; not running: '\(trimmed)'")
                self.lastTranscription = text
                await say(self.jarvisReply.answer(RemoteControl.lockedAnswer), durationMs: 5000)
                return
            }

            switch route {
            case .unreadSessionRecap(let request, let selection):
                session.latency.finishDecision(route: "bulut sohbet özeti")
                await self.readAgentSessions(request, selection: selection, after: session)
                return

            case .sessionNavigation(let request):
                session.latency.finishDecision(route: "bulut sohbet geçişi")
                let reply = await CloudSessionNavigation.handle(request, front: session.targetApp)
                guard !session.isCancelled, !Task.isCancelled, self.nextTranscriptionID == session.id else { return }
                await say(reply ?? "İstenen sohbeti açamadım.", durationMs: 6000)
                if reply == CloudSessionNavigation.newChatOpened, session.isVoiceCommand {
                    developerSessionApp = NSWorkspace.shared.frontmostApplication
                }

            case .sendExistingMessage:
                let sent = TextInjector().sendExistingMessage(context: session.pasteContext)
                let status = sent ? "Gönderme komutu uygulandı" : "Mesaj alanına odaklanıp tekrar gönder diyebilirsin"
                self.showFlowBarMessage(status, durationMs: 3500)
                if !sent { await self.speakReply(status) }

            case .agentWithoutForeground:
                let status = "Önde bir uygulama bulamadım; mesaj gönderilmedi."
                SpeechDiagnostics.event("output.skipped", ["reason": "[Agent] Send skipped: no foreground application"])
                owLog("[Agent] Send skipped: no foreground application")
                self.showFlowBarMessage(status, durationMs: 4500)
                await self.speakReply(status)

            case .agent(let agent):
                owLog("[Route] agent (\(agent.target?.displayName ?? "frontmost app"), send: \(agent.send), session: \(agent.session.rawValue))")
                // "Claude Code'da yeni session aç" / "Bitirme projesine geç" alone just open it.
                guard !agent.body.isEmpty || agent.session == .new || agent.project != nil else {
                    SpeechDiagnostics.event("output.skipped", ["reason": "[Agent] Nothing to write after the command words, skipping"])
                    owLog("[Agent] Nothing to write after the command words, skipping")
                    return
                }
                @MainActor func fail(_ status: String, spoken: String) async {
                    if !agent.body.isEmpty { self.textInjector?.copyToClipboard(agent.body) }
                    self.showFlowBarMessage(agent.body.isEmpty ? status : "\(status), panoya kopyalandı", durationMs: 4500)
                    if session.isVoiceCommand { await self.speakReply(self.jarvisReply.failure(spoken)) }
                }
                if let project = agent.project {
                    switch await AgentProjectNavigator.open(project, target: agent.target ?? .claudeCode,
                                                            assumed: agent.targetAssumed, newSession: agent.session == .new) {
                    case .failed(let status, let spoken):
                        await fail(status, spoken: spoken)
                    case .opened(let app, let projectAgent, let found, let isNew):
                        guard !agent.body.isEmpty else {
                            if isNew, session.isVoiceCommand { developerSessionApp = app }
                            if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agentProject(found.name, isNew: isNew)) }
                            return
                        }
                        let delivered = await pasteAsDictation(agent.body, targetApp: app, pasteContext: PasteContext.capture(targetApp: app), send: agent.send)
                        guard delivered else {
                            owLog("[Agent] Not delivered to \(found.name) in \(projectAgent.displayName); not reporting success")
                            await fail(agent.send ? "Mesaj gönderilemedi" : "Mesaj yazılamadı",
                                       spoken: agent.send ? "mesajı gönderemedim" : "mesajı yazamadım")
                            return
                        }
                        if agent.send, projectAgent == .claudeCode { ClaudeSessionNavigator.rememberSession(app, wasNew: isNew) }
                        if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: agent.send)) }
                    }
                    return
                }
                if agent.session == .last, agent.target != .claudeCode {
                    await fail("Son session yalnızca Claude Code'da var", spoken: "son session'ı yalnızca Claude Code'da bulabiliyorum")
                    return
                }
                var targetApp = session.targetApp
                var pasteContext = session.pasteContext
                if let target = agent.target,
                   !(targetApp?.bundleIdentifier.map(target.bundleIdentifiers.contains) ?? false)
                    || agent.session != .current {
                    guard let app = await AgentAppActivator.activate(target) else {
                        await fail("\(target.displayName) açılamadı", spoken: "\(target.displayName) açılamadı")
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
                    case .last:
                        guard let name = ClaudeSessionNavigator.lastSessionTitle else {
                            await fail("Son session'ı bilmiyorum", spoken: "son session'ı bilmiyorum")
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
                        let what = agent.session == .new ? "Yeni session açılamadı" : "Son session bulunamadı"
                        await fail(what, spoken: what.lowercased(with: Locale(identifier: "tr_TR")))
                        return
                    }
                    pasteContext = PasteContext.capture(targetApp: app)
                    if agent.body.isEmpty {
                        if agent.session == .new, session.isVoiceCommand { developerSessionApp = app }
                        if session.isVoiceCommand { await self.speakReply(self.jarvisReply.newAgentSession()) }
                        return
                    }
                }
                let delivered = await pasteAsDictation(agent.body, targetApp: targetApp, pasteContext: pasteContext, send: agent.send)
                guard delivered else {
                    owLog("[Agent] Not delivered to \(targetApp?.localizedName ?? "?"); not reporting success")
                    await fail(agentDeliveryFailure ?? (agent.send ? "Mesaj gönderilemedi" : "Mesaj yazılamadı"),
                               spoken: agentDeliveryFailure ?? (agent.send ? "mesajı gönderemedim" : "mesajı yazamadım"))
                    return
                }
                if agent.send, let app = targetApp,
                   app.bundleIdentifier.map(AgentApp.claudeCode.bundleIdentifiers.contains) ?? false {
                    ClaudeSessionNavigator.rememberSession(app, wasNew: agent.session == .new)
                }
                if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: agent.send)) }

            case .typed(let typed):
                owLog("[Route] explicit dictation override: '\(typed)'")
                let delivered = await pasteAsDictation(typed, targetApp: session.targetApp, pasteContext: session.pasteContext, send: false)
                if delivered, session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: false)) }

            case .chat(let chatText):
                session.latency.finishDecision(route: "Jarvis sohbet")
                owLog("[Route] explicit Jarvis chat: '\(chatText)'")
                await chat(chatText, detail: "Jarvis sohbet")

            case .workResume(let action):
                session.latency.finishDecision(route: "son çalışmaya dönüş")
                guard let context = session.greetingWorkContext, context.isFresh() else { return }
                await self.resumeGreetingWork(action, context: context, after: session)
                holdMediaForReplyAnswer = self.hotkey?.isIdle == false

            // Acknowledge immediately, then recap the last known work and listen again.
            case .greeting(let greeting):
                session.latency.finishDecision(route: "selamlama")
                owLog("[Route] greeting (\(greeting))")
                self.lastTranscription = text
                self.recentWorkContext = nil
                if greeting == .goodNight {
                    await say(self.jarvisReply.greet(greeting, hour: Calendar.current.component(.hour, from: Date())), durationMs: 4000)
                } else {
                    await say(greeting == .howAreYou ? "İyiyim, buradayım." : self.jarvisReply.greet(greeting, hour: Calendar.current.component(.hour, from: Date())), durationMs: 3000)
                    guard !session.isCancelled, !Task.isCancelled, self.nextTranscriptionID == session.id,
                          self.recordingState != .recording else { return }
                    let work = await Task.detached(priority: .utility) { GreetingBriefing.latestWork() }.value
                    let reply = await GreetingBriefing.summary(work, model: self.ollamaModel, ollamaAvailable: self.ollamaAvailable)
                    guard !session.isCancelled, !Task.isCancelled, self.nextTranscriptionID == session.id,
                          self.recordingState != .recording else { return }
                    self.recentWorkContext = WorkResume.Context(work: work, summary: reply, createdAt: Date())
                    await say(reply, durationMs: 10000)
                    holdMediaForReplyAnswer = self.listenAfterGreeting(after: session)
                }

            // "Ne dedin?" repeats the last reply; "Ne yapabilirsin?" lists what Jarvis does.
            case .meta(let meta):
                session.latency.finishDecision(route: "Jarvis hakkında")
                owLog("[Route] meta (\(meta))")
                self.lastTranscription = text
                let reply: String
                switch meta {
                case .repeatLast: reply = self.lastSpokenReply ?? "Henüz bir şey söylemedim."
                case .help: reply = JarvisReply.helpText
                }
                await say(reply, durationMs: 8000)

            // "Bunu hatırla: …", "benim adım …", "hakkımda ne biliyorsun?", "… unut".
            case .memory(let memoryCommand):
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
                await say(reply, durationMs: 5000)

            // Test mode: the next untested TODO.md item is read aloud; the answer is written back.
            case .voiceTest(let command):
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
                await say(reply, durationMs: 8000)

            // "Geçen hafta ne demiştim?", "dün ne konuşmuştuk?": only now is the journal read,
            // and only that time's lines go to the model.
            case .pastConversation(let query):
                session.latency.finishDecision(route: "geçmiş sohbet")
                self.lastTranscription = text
                let recalled = JarvisJournal.shared.recall(query, facts: UserMemory.shared.facts)
                owLog("[Route] memory-time (\(query.label), \(recalled.count) line(s))")
                guard !recalled.isEmpty else {
                    await say(self.jarvisReply.nothingRecalled(query.label), durationMs: 5000)
                    return
                }
                await chat(trimmed, recalled: recalled, detail: "geçmiş sohbet")

            // "Claude'da son session'ı özetle": two sentences on screen and aloud, then the mic
            // stays open and whatever the user says goes to that session.
            case .claudeSessionRecap:
                session.latency.finishDecision(route: "Claude oturum özeti")
                self.lastTranscription = text
                guard let recapped = ClaudeSessionRecap.latestSession() else {
                    owLog("[Agent] Claude recap: no session found")
                    await say("Claude'da bir oturum bulamadım.", durationMs: 4000)
                    return
                }
                owLog("[Route] Claude recap of \"\(recapped.title)\" (stored recap: \(recapped.storedRecap != nil))")
                self.jarvisActivity = .thinking
                let summary = await ClaudeSessionRecap.summary(of: recapped, ollamaModel: self.ollamaModel,
                                                               ollamaAvailable: self.ollamaAvailable)
                self.jarvisActivity = .none
                guard let summary else {
                    await say("\(recapped.title) oturumunda özetlenecek bir şey bulamadım.", durationMs: 4000)
                    return
                }
                ClaudeSessionNavigator.rememberSession(id: recapped.id, title: recapped.title)
                self.showFlowBarMessage(summary, durationMs: Self.flowBarDuration(ofRecap: summary))
                await self.speakReply(summary)
                if self.listenForClaudeMessage(summary, after: session) { holdMediaForReplyAnswer = true }

            case .deletionConfirmation, .whatsAppConfirmation:
                // Answered above; a non-answer was routed again without it.
                break

            case .whatsAppSend(let outgoing):
                owLog("[Route] WhatsApp send (\(outgoing.body.isEmpty ? "open chat" : "\(outgoing.body.count) chars"))")
                session.latency.finishDecision(route: "WhatsApp mesajı")
                self.lastTranscription = text
                await sayWhatsApp(await self.whatsAppSender.prepare(outgoing))

            // "sesi kıs ve Bluetooth'u kapat", "Wi-Fi'yi aç, sonra 10 dakikalık alarm kur".
            case .commands(let steps):
                session.latency.finishDecision(route: "çoklu komut")
                owLog("[Route] multi-command (\(steps.count)): \(steps.map { "'\($0.text)' → \($0.command)" }.joined(separator: ", "))")
                await runCommands(steps, output: "çoklu komut")

            // "20 dakikalık alarm kur", "Bluetooth'u kapat", "videoyu durdur", "YouTube'da lofi
            // ara", "yarın 3'te toplantı ekle".
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
                await runCommands([MultiCommandSplitter.Step(text: trimmed, command: command)], output: output)

            case .reminderDeletion(let reminderDeletion):
                owLog("[Route] reminder deletion")
                session.latency.finishDecision(route: "hatırlatıcı silme")
                owLog("[OpenWhisper] Reminder deletion detected: \(text)")
                self.lastTranscription = text
                let actionStartedAt = session.latency.timestamp()
                let result = await self.reminderManager?.beginDeletion(reminderDeletion) ?? .failed
                session.latency.record(.action, since: actionStartedAt, detail: "hatırlatıcı silme")
                session.latency.markOutput("hatırlatıcı silme sonucu")
                SpeechDiagnostics.event("action.result", ["result": "[Result] Reminder deletion request: \(String(describing: result))"])
                owLog("[Result] Reminder deletion request: \(String(describing: result))")
                let prompt = self.jarvisReply.reminderDeletion(result)
                let promptWasHeard = await self.speakReply(prompt)
                if case .confirmationRequired = result { askFollowUp(prompt, heard: promptWasHeard) }

            case .reminder:
                owLog("[Route] reminder")
                session.latency.finishDecision(route: "hatırlatıcı")
                owLog("[OpenWhisper] Reminder detected: \(text)")
                self.lastTranscription = text
                // The deterministic parser handles most phrasings; Ollama is only its fallback.
                let actionStartedAt = session.latency.timestamp()
                let reminder = await self.reminderManager?.handleReminder(text: text)
                session.latency.record(.action, since: actionStartedAt, detail: "hatırlatıcı")
                session.latency.markOutput(reminder != nil ? "hatırlatıcı kuruldu" : "hatırlatıcı kurulamadı")
                SpeechDiagnostics.event("action.result", ["result": "[Result] Reminder \(reminder != nil ? "scheduled" : "not scheduled")"])
                owLog("[Result] Reminder \(reminder != nil ? "scheduled" : "not scheduled")")
                if reminder == nil, !self.ollamaAvailable {
                    owLog("[OpenWhisper] Reminder not understood and Ollama is not available")
                }
                if session.isVoiceCommand {
                    await self.speakReply(self.jarvisReply.reminder(at: reminder.map { TimerManager.clock($0.fireDate, sayDay: true) }))
                }

            case .spotifyOrConversation(let firstSentence):
                // "Yarına takvim etkinliği ekle saat 13'e": SetFit decides, no rule.
                if session.acceptsCommands, let request = await self.calendarEventRequest(text) {
                    switch request {
                    case .event(let event):
                        owLog("[Route] calendar (SetFit)")
                        session.latency.finishDecision(route: "takvim")
                        await runCommands([MultiCommandSplitter.Step(text: trimmed, command: .system(.calendarEvent(event)))],
                                          output: "takvim")
                    case .needsDate:
                        owLog("[Route] calendar (SetFit) without a day or time")
                        session.latency.finishDecision(route: "takvim, tarih yok")
                        await say("Ne zaman ekleyeyim? Günüyle birlikte tekrar söyler misin?", durationMs: 6000)
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
                    await dictateOrChat()
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
                let handled = await SpotifyManager.shared.handleCommand(
                    text: commandText, targetApp: session.targetApp, recordUndo: !misheard.isEmpty
                )
                session.latency.record(.action, since: actionStartedAt, detail: "Spotify")
                let resultMessage = SpotifyManager.shared.takeResultMessage(for: commandText)
                if handled { session.latency.markOutput("Spotify komutu tamamlandı") }
                SpeechDiagnostics.event("action.result", ["result": "[Result] Spotify command \(handled ? "handled" : "not applied")"])
                owLog("[Result] Spotify command \(handled ? "handled" : "not applied")")
                guard handled else {
                    // Clearly a command, so typing it out would only hide that nothing plays.
                    if speaksFailure {
                        owLog("[OpenWhisper] Spotify command failed: \(resultMessage ?? "?")")
                        if session.isVoiceCommand {
                            await speakAfterCommand(self.jarvisReply.failure(resultMessage ?? "Spotify komutunu uygulayamadım"))
                        }
                        return
                    }
                    owLog("[OpenWhisper] Spotify command not applied, falling back to dictation")
                    await dictateOrChat()
                    return
                }
                resumeMediaAfterCommand = resumesMedia
                commandFollowUp = .some(.music)
                self.lastTranscription = text
                // Never "şarkı çalınıyor": only a short ack, spoken before the music resumes.
                // Questions ("sıradaki şarkı ne") and timers get their answer instead.
                if session.isVoiceCommand {
                    let answer = speaksResult ? resultMessage.map { self.jarvisReply.spotifyResult($0) } : nil
                    await speakAfterCommand(answer ?? self.jarvisReply.spotify(handled: true, likedSongs: likedSongs))
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
            } // cloud plan steps
        }
        }
        }
    }
}
