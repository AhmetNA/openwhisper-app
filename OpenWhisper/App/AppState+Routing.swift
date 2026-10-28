import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    /// An explicit recording must not look successful when recognition produced no usable text.
    /// Passive command follow-ups may legitimately contain only silence or playback.
    func reportUnrecognizedRecording(_ session: RecordingTranscriptionSession) async {
        session.latency.markOutput("konuşma anlaşılamadı; gönderilmedi")
        guard !session.isCancelled, !session.takesOnlyCommands else { return }
        let message = "Konuşmanı anlayamadım; metin çıkarılamadı. Mikrofonu kontrol edip tekrar dene."
        lastError = message
        showFlowBarMessage(message, durationMs: 8000)
        owLog("[Result] Recognition failed; user notified, nothing pasted or copied")
        if session.isVoiceCommand, recordingState != .recording {
            await speakReply(message)
        }
    }

    func finishTranscription(_ session: RecordingTranscriptionSession) async {
        guard !session.hasFinished else { return }
        session.hasFinished = true
        // Set when a command ran: listen a moment longer for a fix ("sonrakine geç"). Declared
        // first so it runs last, once the media and recording state below are settled.
        var commandFollowUp: CommandFollowUp.Domain?? = nil
        // An agent app or a new chat was opened: listen for commands or dictation there.
        var conversationContinuationApp: NSRunningApplication?
        // Opened already as Jarvis's reply started (`speakAfterCommand`).
        var followUpOpenedOverReply = false
        defer {
            if let app = conversationContinuationApp, !session.isCancelled,
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

        defer {
            // A re-asked confirmation (holdMediaForFollowUp) keeps its plan for the next answer.
            if session.trigger == .confirmation && !holdMediaForFollowUp {
                self.reminderManager?.cancelPendingDeletion()
                self.whatsAppSender.cancel()
            }
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
                owLog("[OpenWhisper] Audio too short (\(session.queuedSampleCount) samples < 0.4s)")
                return
            }

            // Mangled names ("Sputfayda" → "Spotify'da") fixed before routing, so a command is
            // still recognized; the list is the user's ses-benzerleri.txt.
            // Wake sessions now start at the wake itself, so the tail of "Jarvis" can be heard.
            let rawJoined = AudioSegmentation.joinTranscripts(session.segmentTexts)
            let joined = session.appliesSpeechChecks
                ? SpokenDoneEndpoint.removingSuffix(from: rawJoined) ?? rawJoined : rawJoined
            // A bare finish word closes the microphone without creating an empty request.
            if session.appliesSpeechChecks, joined.isEmpty,
               SpokenDoneEndpoint.removingSuffix(from: rawJoined) != nil { return }
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
            let (text, soundAlikes) = session.appliesSpeechChecks
                ? SoundAlikeCorrector.correct(spoken, entries: AppFocus.soundAlikeEntries(soundAlikeEntries, focus: focus),
                                              keeping: GlossaryStore.multiWordTerms())
                : (spoken, [])
            for (heard, written) in soundAlikes { owLog("[SoundAlike] \(heard) → \(written)") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("[BLANK"),
                  !trimmed.hasPrefix("(BLANK") else {
                owLog("[OpenWhisper] Empty/blank transcription, skipping")
                await reportUnrecognizedRecording(session)
                return
            }
            guard !session.appliesSpeechChecks || !AudioSegmentation.isRepetitionHallucination(trimmed) else {
                owLog("[OpenWhisper] Repeated-word hallucination, skipping: \(trimmed)")
                await reportUnrecognizedRecording(session)
                return
            }
            guard !session.appliesSpeechChecks
                    || !ForeignTranscriptGuard.isForeign(trimmed, misheardCount: misheardWords(in: trimmed).count) else {
                owLog("[OpenWhisper] Not Turkish or English, nothing pasted or run: \(trimmed)")
                if session.followsCommand {
                    dismissFlowBarMessage()
                } else {
                    // A voice session that asks "tekrar söyler misin?" must also listen for it.
                    let ask = "Anlaşılamadı, tekrar söyler misin?"
                    lastError = ask
                    session.latency.markOutput("konuşma anlaşılamadı; gönderilmedi")
                    if listenForReplyAnswer(ask, heard: false, after: session) {
                        holdMediaForReplyAnswer = true
                    } else {
                        showFlowBarMessage(ask, durationMs: 8000)
                    }
                }
                return
            }

            owLog("[OpenWhisper] Raw: \(text)")
            session.latency.beginDecision()
            correctionGeneration &+= 1
            let generation = correctionGeneration

            var agentDeliveryFailure: String?
            /// Jarvis opened the app or chat it sends to: the Flow bar keeps saying so.
            var jarvisChangedScreen = false

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
                    owLog("[Result] Screen locked; nothing pasted")
                    session.latency.finishDecision(route: "Mac kilitli")
                    await self.speakReply(self.jarvisReply.answer(RemoteControl.lockedAnswer))
                    return false
                }
                session.latency.finishDecision(route: send ? "agent yazma" : "dikte")
                let preprocessingStartedAt = session.latency.timestamp()
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
                let screenWatch = watchesScreen ? NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
                ) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    Task { @MainActor in
                        guard watchesScreen, let app, app.processIdentifier != targetApp?.processIdentifier,
                              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                        owLog("[Agent] Screen changed to \(app.localizedName ?? "?") before the send")
                        self?.showFlowBarMessage("Ekran değişti, mesaj gitmeyebilir", durationMs: 8000)
                    }
                } : nil
                defer {
                    watchesScreen = false
                    if let screenWatch { NSWorkspace.shared.notificationCenter.removeObserver(screenWatch) }
                }
                if watchesScreen, !jarvisChangedScreen {
                    self.showFlowBarMessage("Gönderiyorum, ekranı değiştirmeyin", durationMs: 8000)
                }

                // Return can only be pressed in the frontmost app. If the user moved to another
                // app (or full-screen Space) after "gönder", hop to the target, send there, and
                // go straight back to where they were.
                var hopFrom: NSRunningApplication?
                if self.autoPasteEnabled, send,
                   let target = targetApp, !target.isTerminated,
                   let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != target.processIdentifier {
                    owLog("[Result] Send target is in the background; switching to \(target.localizedName ?? "?") to send, then back to \(front.localizedName ?? "?")")
                    jarvisChangedScreen = true
                    self.showFlowBarMessage("Jarvis ekranı değiştirdi, bekleyin", durationMs: 8000)
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

                if self.autoPasteEnabled, RecordedConversation.requiresBinding(pasteContext.bundleIdentifier) {
                    if previousConversation != nil {
                        self.showFlowBarMessage("Jarvis sohbeti değiştirdi, bekleyin", durationMs: 8000)
                    }
                    guard let app = targetApp, let conversation = pasteContext.conversation,
                          await conversation.restore(in: app) else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(initialText, forType: .string)
                        let reason = pasteContext.conversation == nil
                            ? "Kayıt başında sohbet kimliği alınamadı"
                            : "Kaydın başladığı sohbete dönülemedi"
                        agentDeliveryFailure = reason
                        self.lastError = "\(reason). Metin panoya kopyalandı."
                        session.latency.markOutput(reason)
                        owLog("[Agent] Delivery blocked: \(reason)")
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
                    chatWatch = Task { @MainActor [weak self] in
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(250))
                            guard watchesScreen, !Task.isCancelled else { return }
                            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                                  let now = conversation.shownTitle(in: app), now != shown else { continue }
                            owLog("[Agent] Chat changed to \"\(now)\" before the send")
                            self?.showFlowBarMessage("Sohbet değişti, mesaj gitmeyebilir", durationMs: 8000)
                            return
                        }
                    }
                }
                defer { chatWatch?.cancel() }

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
                        Task { @MainActor in VoiceTrace.$current.withValue(traceID) {
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
                                            // From here Jarvis itself may hop to the target and back.
                                            watchesScreen = false
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
                                                if let traceID {
                                                    VoiceEventLog.shared.append(traceID, "[Result] Replaced pasted text with cleanup: '\(trimmedCleaned)'")
                                                }
                                            }
                                        }
                                    }
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
                } else {
                    self.textInjector?.copyToClipboard(initialText)
                    owLog("[Result] Auto-paste off, copied to clipboard: '\(initialText)'")
                    session.latency.markOutput("panoya kopyalandı")
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
                        owLog("[Result] Timer: \(status)")
                        ran.append(step.command)
                        statuses.append(status)
                        replies.append(self.jarvisReply.timer(timerCommand, status: status))
                    case .system(let command):
                        if step.command.endsSession && command != .disableWakeWord {
                            // Say everything before the Mac stops listening.
                            if session.isVoiceCommand {
                                await self.speakReply(self.jarvisReply.combined(replies + ["Görüşürüz."]))
                            }
                            replies = []
                        }
                        // The local model takes several seconds on a long page.
                        if command == .browser(.summarize) { self.showFlowBarMessage("Sayfa özetleniyor…", durationMs: 30000) }
                        var youTubeStatus: String?
                        if case .video = command, SystemCommandParser.mentionsYouTube(step.text) {
                            youTubeStatus = await BrowserController.prepareYouTubeVideo()
                        }
                        var status: String
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
                            commandFollowUp = nil
                            conversationContinuationApp = nil
                        }
                        if command == .developerMode {
                            // ChatGPT, still launching behind Claude, can take the front while
                            // Claude is being activated; try again once its launch has settled.
                            var claude: NSRunningApplication?
                            for _ in 0..<3 where claude == nil {
                                claude = await AgentAppActivator.activate(.claudeCode)
                            }
                            if let app = claude,
                               await ClaudeSessionNavigator.openNewSession(app) {
                                conversationContinuationApp = app
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
                        case .switchToAgent(let agent):
                            stepTargetApp = NSWorkspace.shared.frontmostApplication
                            // Opening an agent invites a message, not just a short command fix.
                            // Continue only after a successful final step into the expected app.
                            if session.isVoiceCommand, steps.last?.command == step.command,
                               status == "\(agent.displayName) önde",
                               let app = stepTargetApp,
                               agent.bundleIdentifiers.contains(app.bundleIdentifier ?? "") {
                                conversationContinuationApp = app
                            }
                        case .switchToApp: stepTargetApp = NSWorkspace.shared.frontmostApplication
                        default: break
                        }
                        owLog("[Result] System command: \(status)")
                        ran.append(step.command)
                        statuses.append(status)
                        if !step.command.endsSession || command == .disableWakeWord { replies.append(self.jarvisReply.system(command, status: status)) }
                    case .spotify(let request):
                        let resumes = SpotifyManager.resumesPausedMedia(afterCommand: request)
                        let likedSongs = SpotifyManager.playsLikedSongs(afterCommand: request)
                        let speaksResult = SpotifyManager.speaksResult(afterCommand: request)
                        let speaksFailure = SpotifyManager.speaksFailure(afterCommand: request)
                        let handled = await SpotifyManager.shared.handleCommand(text: request, targetApp: stepTargetApp)
                        let message = SpotifyManager.shared.takeResultMessage(for: request)
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
                // The Mac stops listening after sleep / lock; developer mode is a whole setup.
                if conversationContinuationApp == nil, !ran.isEmpty, !ran.contains(where: { $0.endsSession || $0 == .system(.developerMode) }) {
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
                let answer = await self.chatReply(to: chatText, recalled: recalled)
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
                    owLog("[Result] WhatsApp draft read back, awaiting confirmation")
                    let heard = await self.speakReply(prompt)
                    askFollowUp(prompt, heard: heard)
                case .done(let status):
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
                        self?.pendingScreenPress = nil
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

            /// "Kaydet", "izin ver", "sağ üstteki çarpıya bas": something in the front window,
            /// named as the user would to a friend. Not in a text field, unless clicking is said
            /// outright (there "tamam" is dictation), and never from a mic left open after a
            /// command or over playing media, where a TV's "tamam" must not press anything.
            @MainActor func screenAction() async -> Bool {
                guard session.acceptsCommands, !session.takesOnlyCommands, !session.heardOnlyOverPlayback,
                      !RemoteControl.screenIsLocked, let app = session.targetApp, !app.isTerminated,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return false }
                // Fn types unless the focus is known not to be a text field (Electron composers
                // report it unknown); a Jarvis session only stays out of a known text field.
                let outsideTextField = session.isVoiceCommand ? session.routingFocus != .editable : session.routingFocus == .notEditable
                if !outsideTextField, !ScreenActions.saysClick(trimmed) { return false }
                guard ScreenActions.worthLooking(trimmed) else { return false }
                // "… tuşuna bas" asked for a press: if nothing fits, say so instead of chatting.
                let saysClick = ScreenActions.saysClick(trimmed)
                // Fn dictation keeps typing such a sentence; only Jarvis was asked to press.
                @MainActor func notFound() async -> Bool {
                    guard saysClick, session.isVoiceCommand else { return false }
                    let name = ScreenActions.spokenName(trimmed)
                    owLog("[Screen] Nothing on screen matches '\(name)'")
                    session.latency.finishDecision(route: "ekran eylemi, bulunamadı")
                    self.lastTranscription = text
                    self.showFlowBarMessage("Ekranda “\(name)” bulamadım", durationMs: 4000)
                    if session.isVoiceCommand { await self.speakReply(self.jarvisReply.failure("Bulamadım")) }
                    return true
                }
                let elements = ScreenActions.elements(of: app)
                guard !elements.isEmpty else { return await notFound() }
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
                } else if !exact.isEmpty || saysClick || ScreenActions.mayBeAboutScreen(trimmed, labels: labels) {
                    self.showFlowBarMessage("Ekrana bakıyorum…", durationMs: 8000)
                    pick = await ScreenActions.modelPick(trimmed, elements: elements)
                    byModel = true
                    if let chosen = pick, exact.isEmpty, !soundAlike.contains(chosen),
                       !ScreenActions.isGrounded(trimmed, label: labels[chosen]) {
                        owLog("[Screen] Model's pick '\(labels[chosen])' has nothing to do with '\(trimmed)'; not pressed")
                        pick = nil
                    }
                    if pick == nil { self.dismissFlowBarMessage() }
                }
                guard let pick else { return await notFound() }
                let target = elements[pick]
                session.latency.finishDecision(route: "ekran eylemi")
                owLog("[Route] screen action: \(target.kind) '\(target.label)' (\(target.region))\(byModel ? " by the model" : "")")
                self.lastTranscription = text
                self.lastCommandUndo = []
                if ScreenActions.isRisky(target.label) {
                    self.pendingScreenPress = (target, app, Date().addingTimeInterval(30))
                    let prompt = "“\(target.label)” \(target.kindDative) basayım mı?"
                    let heard = await self.speakReply(prompt)
                    askFollowUp(prompt, heard: heard)
                    return true
                }
                let pressed = ScreenActions.perform(target)
                self.showFlowBarMessage(pressed ? "“\(target.label)” ✓" : "Basılamadı", durationMs: pressed ? 1500 : 3000)
                if session.isVoiceCommand {
                    await self.speakReply(pressed ? self.jarvisReply.ack() : self.jarvisReply.failure("Basamadım"))
                }
                return true
            }

            // For a Jarvis session that is not a command, keyboard focus is the primary signal:
            // editable means dictation (unless the model says a question is for Jarvis), known
            // non-editable means chat. The LLM is otherwise only a fallback when Accessibility
            // could not determine the focus. Fn dictation is always typed.
            @MainActor func dictateOrChat() async {
                // After a command only a command is taken (see the follow-up check below).
                if session.takesOnlyCommands {
                    owLog("[FollowUp] No command after the command; ignored: '\(trimmed)'")
                    session.latency.finishDecision(route: "komut sonrası, komut değil")
                    dismissFlowBarMessage()
                    return
                }
                let front = session.targetApp?.bundleIdentifier
                if session.isVoiceCommand {
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
                       JarvisAddressee.skipsChat(frontBundleID: front, misheardWordCount: self.misheardWords(in: trimmed).count) {
                        owLog("[Addressee] Lock screen and the text has non-words; not answering: '\(trimmed)'")
                        session.latency.finishDecision(route: "kilit ekranı, anlamsız metin")
                        return
                    }
                    // Sounds like a command no rule caught: let the model rephrase it, and run
                    // it only if a rule then recognises the rephrased sentence.
                    if route == .chat, self.ollamaAvailable, CommandRewriter.looksLikeCommand(trimmed),
                       let rewritten = await CommandRewriter.rewrite(trimmed, model: self.ollamaModel) {
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

            // The rules decide where the transcript goes (`VoiceRouter`, in their order); this
            // runs the decision.
            if let pending = self.pendingScreenPress, pending.expiresAt <= Date() { self.pendingScreenPress = nil }
            var facts = VoiceRouter.Facts(
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
                commandContext: commandContext)
            // The mic opened after a Claude / Codex recap: all of it is the message for that
            // chat, unless the user called it off ("boş ver", "vazgeç").
            if session.sendsToRecappedSession != nil, ClaudeSessionRecap.isCancel(trimmed) {
                session.latency.finishDecision(route: "Claude mesajı iptal")
                owLog("[Agent] Recap message called off: '\(trimmed)'")
                await say("Tamam, göndermedim.", durationMs: 3000)
                return
            }
            if session.acceptsCommands, session.sendsToRecappedSession == nil,
               !facts.pendingDeletion, !facts.pendingWhatsAppSend, !RemoteControl.screenIsLocked,
               let reply = await CloudSessionNavigation.handle(trimmed, front: session.targetApp) {
                session.latency.finishDecision(route: "bulut sohbet geçişi")
                self.lastTranscription = text
                if reply == CloudSessionNavigation.newChatOpened || reply == CloudSessionNavigation.switchedChat, session.isVoiceCommand {
                    conversationContinuationApp = NSWorkspace.shared.frontmostApplication
                }
                await say(reply, durationMs: 5000)
                return
            }
            var route = session.sendsToRecappedSession.map {
                .agent(AgentDictation(target: $0, body: trimmed, send: true, session: .last))
            } ?? VoiceRouter.route(text, facts: facts)

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

            if case .screenPressConfirmation = route {
                if let pending = self.pendingScreenPress, let approved = ScreenActions.confirmation(trimmed) {
                    self.pendingScreenPress = nil
                    session.latency.finishDecision(route: "ekran onayı")
                    owLog("[Route] screen press confirmation: \(approved)")
                    self.lastTranscription = text
                    guard approved else {
                        await say("Tamam, basmadım.", durationMs: 2500)
                        return
                    }
                    guard pending.expiresAt > Date(),
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pending.app.processIdentifier else {
                        await say("Ekran değişti, basmadım.", durationMs: 3000)
                        return
                    }
                    let pressed = ScreenActions.perform(pending.target)
                    self.showFlowBarMessage(pressed ? "“\(pending.target.label)” ✓" : "Basılamadı", durationMs: 1500)
                    if !pressed { await self.speakReply(self.jarvisReply.failure("Basamadım")) }
                    return
                }
                self.pendingScreenPress = nil
                facts.pendingScreenPress = false
                route = VoiceRouter.route(text, facts: facts)
            }

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
                    owLog("[FollowUp] No command after the command; ignored: '\(trimmed)'")
                    session.latency.finishDecision(route: "komut sonrası, komut değil")
                    dismissFlowBarMessage()
                    return
                }
            }

            // Locked: nothing can be typed into an app or done on screen. Say so instead of
            // failing silently (or typing into the lock screen); the rest runs as usual.
            if RemoteControl.needsUnlockedScreen(route), RemoteControl.screenIsLocked {
                session.latency.finishDecision(route: "Mac kilitli")
                owLog("[Route] Screen locked; not running: '\(trimmed)'")
                self.lastTranscription = text
                await say(self.jarvisReply.answer(RemoteControl.lockedAnswer), durationMs: 5000)
                return
            }

            switch route {
            case .agentWithoutForeground:
                let status = "Önde bir uygulama bulamadım; mesaj gönderilmedi."
                owLog("[Agent] Send skipped: no foreground application")
                self.showFlowBarMessage(status, durationMs: 4500)
                await self.speakReply(status)

            case .agent(let agent):
                owLog("[Route] agent (\(agent.target?.displayName ?? "frontmost app"), send: \(agent.send), session: \(agent.session.rawValue))")
                // "Claude Code'da yeni session aç" / "Bitirme projesine geç" alone just open it.
                guard !agent.body.isEmpty || agent.session == .new || agent.project != nil else {
                    owLog("[Agent] Nothing to write after the command words, skipping")
                    return
                }
                @MainActor func fail(_ status: String, spoken: String) async {
                    if !agent.body.isEmpty { self.textInjector?.copyToClipboard(agent.body) }
                    self.showFlowBarMessage(agent.body.isEmpty ? status : "\(status), panoya kopyalandı", durationMs: 4500)
                    if session.isVoiceCommand { await self.speakReply(self.jarvisReply.failure(spoken)) }
                }
                @MainActor func jarvisChangesScreen() {
                    guard agent.send, !agent.body.isEmpty else { return }
                    jarvisChangedScreen = true
                    self.showFlowBarMessage("Jarvis ekranı değiştirdi, bekleyin", durationMs: 8000)
                }
                if let project = agent.project {
                    jarvisChangesScreen()
                    switch await AgentProjectNavigator.open(project, target: agent.target ?? .claudeCode,
                                                            assumed: agent.targetAssumed, newSession: agent.session == .new) {
                    case .failed(let status, let spoken):
                        await fail(status, spoken: spoken)
                    case .opened(let app, let projectAgent, let found, let isNew):
                        guard !agent.body.isEmpty else {
                            if session.isVoiceCommand { conversationContinuationApp = app }
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
                    case .last where agent.target != .claudeCode:
                        let thread = CodexSessionNavigator.lastThread!
                        switched = await CodexSessionNavigator.openThread(app, id: thread.id, title: thread.title)
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
                        if agent.session == .new, session.isVoiceCommand { conversationContinuationApp = app }
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
                } else if agent.send, let app = targetApp,
                          app.bundleIdentifier.map(AgentApp.codex.bundleIdentifiers.contains) ?? false {
                    CodexSessionNavigator.rememberThread(shownIn: app)
                }
                if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: agent.send)) }

            case .dictationEdit(let edit):
                session.latency.finishDecision(route: "dikte düzeltme")
                owLog("[Route] dictation edit (\(edit))")
                let result = await runDictationEdit(edit, targetApp: session.targetApp)
                owLog("[Result] Dictation edit: \(result.status)")
                self.showFlowBarMessage(result.status, durationMs: result.done ? 1000 : 3000)
                if session.isVoiceCommand, !result.done { await self.speakReply(result.status) }

            case .typed(let typed):
                owLog("[Route] explicit dictation override: '\(typed)'")
                await pasteAsDictation(typed, targetApp: session.targetApp, pasteContext: session.pasteContext, send: false)
                if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: false)) }

            case .chat(let chatText):
                session.latency.finishDecision(route: "Jarvis sohbet")
                owLog("[Route] explicit Jarvis chat: '\(chatText)'")
                await chat(chatText, detail: "Jarvis sohbet")

            // "Günaydın", "Selam Jarvis", "Nasılsın?": answered at once by the clock, no LLM.
            case .greeting(let greeting):
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
                        + " " + summary.morningLine(now: now)
                    owLog("[Briefing] Morning: \(summary.headline)")
                }
                await say(reply, durationMs: 6000)

            // "Ne dedin?" repeats the last reply; "Ne yapabilirsin?" lists what Jarvis does.
            case .meta(let meta):
                session.latency.finishDecision(route: "Jarvis hakkında")
                owLog("[Route] meta (\(meta))")
                let heard = self.lastTranscription
                let reply: String
                switch meta {
                case .repeatLast: reply = self.lastSpokenReply ?? "Henüz bir şey söylemedim."
                case .help: reply = JarvisReply.helpText
                case .whatCanISay:
                    reply = JarvisReply.whatCanISay(frontBundleID: session.targetApp?.bundleIdentifier,
                                                    inTextField: session.routingFocus == .editable)
                case .whatDidYouHear:
                    // Not a transcript of its own: asked twice, it still reads the request before.
                    reply = heard.isEmpty ? "Henüz bir şey duymadım." : "“\(heard)” diye duydum."
                    await say(reply, durationMs: 8000)
                    return
                case .undoLastCommand:
                    self.lastTranscription = text
                    let undo = self.lastCommandUndo
                    guard !undo.isEmpty else {
                        await say("Geri alabileceğim bir komut yok.", durationMs: 3000)
                        return
                    }
                    owLog("[Route] undo last command: \(undo)")
                    await runCommands(undo.map { MultiCommandSplitter.Step(text: trimmed, command: $0) }, output: "komut geri alma")
                    return
                }
                self.lastTranscription = text
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

            // "Claude'da son session'ı özetle" / "Codex'te son sohbeti özetle": two sentences on
            // screen and aloud, then the mic stays open and whatever the user says goes there.
            case .agentSessionRecap(let agent):
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
                    await say("\(agent.locative) cevabı gelmiş bir sohbet bulamadım.", durationMs: 4000)
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
                    await say("\(recapped.title) oturumunda özetlenecek bir şey bulamadım.", durationMs: 4000)
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
                    holdMediaForReplyAnswer = true
                }

            // "Biten sohbete geç", "yanıtı gelene geç": opens the chat whose answer came in last;
            // the mic then stays open there, so the next words are written without "Hey Jarvis".
            case .finishedAgentChat(let target):
                session.latency.finishDecision(route: "biten sohbete geçiş")
                self.lastTranscription = text
                guard !RemoteControl.screenIsLocked else {
                    await say("Mac kilitli; bunu kilidi açınca yapabilirim.", durationMs: 4000)
                    return
                }
                let agents: [AgentApp] = target.map { [$0 == .claudeCode ? .claudeCode : .codex] } ?? [.claudeCode, .codex]
                let current = session.targetApp.flatMap { RecordedConversation.capture(app: $0) }?.sessionID
                let chats = await Task.detached { agents.flatMap(AgentFinishedChat.load) }.value
                guard let chat = AgentFinishedChat.newest(chats, excluding: current) else {
                    owLog("[Agent] Finished chat: none in \(agents.map(\.displayName))")
                    await say("Cevabı gelmiş başka bir sohbet bulamadım.", durationMs: 4000)
                    return
                }
                owLog("[Route] finished chat → \(chat.agent.displayName) \"\(chat.title)\" (finished \(chat.finishedAt))")
                guard let app = await AgentAppActivator.activate(chat.agent) else {
                    await say(self.jarvisReply.failure("\(chat.agent.displayName) açılamadı"), durationMs: 4000)
                    return
                }
                let navigated = chat.agent == .claudeCode
                    ? await ClaudeSessionNavigator.openSession(app, id: chat.id, title: chat.title)
                    : await CodexSessionNavigator.openThread(app, id: chat.id, title: chat.title)
                // A changed title is not proof: the open mic must never write into another chat.
                guard navigated, RecordedConversation.capture(app: app)?.sessionID == chat.id else {
                    owLog("[Agent] Finished chat: could not verify \"\(chat.title)\" opened")
                    await say("Sohbetin açıldığını doğrulayamadım.", durationMs: 4000)
                    return
                }
                if session.isVoiceCommand { conversationContinuationApp = app }
                await say(self.jarvisReply.finishedChat(chat.title), durationMs: 4000)

            case .deletionConfirmation, .whatsAppConfirmation, .screenPressConfirmation:
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
                    // After Spotify: "Tarkan çal" must not pick a row that says Tarkan.
                    if await screenAction() { return }
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
        }
    }
}
