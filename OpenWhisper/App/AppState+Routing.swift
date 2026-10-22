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
        // Opened already as Jarvis's reply started (`speakAfterCommand`).
        var followUpOpenedOverReply = false
        defer {
            if let commandFollowUp, !followUpOpenedOverReply { listenAfterCommand(domain: commandFollowUp, after: session) }
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
            let joined = AudioSegmentation.joinTranscripts(session.segmentTexts)
            // A follow-up opened over Jarvis's reply heard the reply first.
            let spoken = session.trigger == .wakeWord ? WakeWordVerifier.strippingLeadingWakeWord(joined)
                : session.precedingReply != nil ? CommandFollowUp.removingEcho(of: session.precedingReply, from: joined)
                : joined
            if spoken != joined { owLog("[WakeWord] Removed the wake word from the transcript start: \(joined)") }
            let (text, soundAlikes) = session.appliesSpeechChecks
                ? SoundAlikeCorrector.correct(spoken, entries: SoundAlikeCorrector.loadEntries())
                : (spoken, [])
            for (heard, written) in soundAlikes { owLog("[SoundAlike] \(heard) → \(written)") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("[BLANK"),
                  !trimmed.hasPrefix("(BLANK") else {
                owLog("[OpenWhisper] Empty/blank transcription, skipping")
                return
            }
            guard !session.appliesSpeechChecks || !AudioSegmentation.isRepetitionHallucination(trimmed) else {
                owLog("[OpenWhisper] Repeated-word hallucination, skipping: \(trimmed)")
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

                // Return can only be pressed in the frontmost app. If the user moved to another
                // app (or full-screen Space) after "gönder", hop to the target, send there, and
                // go straight back to where they were.
                var hopFrom: NSRunningApplication?
                if self.autoPasteEnabled, send,
                   let target = targetApp, !target.isTerminated,
                   let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != target.processIdentifier {
                    owLog("[Result] Send target is in the background; switching to \(target.localizedName ?? "?") to send, then back to \(front.localizedName ?? "?")")
                    if await AgentAppActivator.bringToFront(target) {
                        hopFrom = front
                    }
                }
                let returnToApp = hopFrom
                @MainActor func goBack() {
                    guard let app = returnToApp else { return }
                    Task { @MainActor in _ = await AgentAppActivator.bringToFront(app) }
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
                        Task { @MainActor in VoiceTrace.$current.withValue(traceID) {
                            guard let self else { return }
                            session.latency.record(.paste, since: pasteStartedAt, detail: "\(outcome)")
                            session.latency.markOutput("\(outcome)")
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
                                        if let pid = pasteContext.targetPID, let injector = self.textInjector as? TextInjector {
                                            sent = await injector.pressReturnBringingToFront(pid: pid)
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
                                        let cleaned = await self.llmCleanup?.cleanup(text: initialText, misheard: misheard) ?? initialText
                                        session.latency.record(.cleanup, since: cleanupStartedAt)
                                        let formatted = await self.formatTurkishDictation(cleaned)
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
                    installedApps: SystemController.installedApps(), shortcuts: SystemController.shortcutNames)
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
                        if step.command.endsSession {
                            // Say everything before the Mac stops listening.
                            if session.isVoiceCommand {
                                await self.speakReply(self.jarvisReply.combined(replies + ["Görüşürüz."]))
                            }
                            replies = []
                        }
                        // The local model takes several seconds on a long page.
                        if command == .browser(.summarize) { self.showFlowBarMessage("Sayfa özetleniyor…", durationMs: 30000) }
                        let status = await SystemController.perform(command)
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
                        owLog("[Result] System command: \(status)")
                        ran.append(step.command)
                        statuses.append(status)
                        if !step.command.endsSession { replies.append(self.jarvisReply.system(command, status: status)) }
                    case .spotify(let request):
                        let resumes = SpotifyManager.resumesPausedMedia(afterCommand: request)
                        let likedSongs = SpotifyManager.playsLikedSongs(afterCommand: request)
                        let handled = await SpotifyManager.shared.handleCommand(text: request, targetApp: stepTargetApp)
                        owLog("[Result] Spotify command \(handled ? "handled" : "not applied"): '\(request)'")
                        if handled, !resumes { resumeMediaAfterCommand = false }
                        if handled { ran.append(step.command) }
                        statuses.append(handled ? "Spotify: \(step.text)" : "Spotify komutu uygulanamadı")
                        replies.append(handled ? self.jarvisReply.spotify(handled: true, likedSongs: likedSongs) : self.jarvisReply.failure("Spotify komutunu uygulayamadım"))
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

            /// Keeps the paused media paused while a follow-up question waits for its answer,
            /// with a safety net if the answer's recording never starts.
            @MainActor func askFollowUp(_ prompt: String, heard: Bool) {
                // Typed: the answer is typed too; closing the panel unanswered drops the plan,
                // as a silent confirmation window does.
                if session.trigger == .typed {
                    self.openTypedRequestPanel(prompt: prompt) { [weak self] in
                        self?.reminderManager?.cancelPendingDeletion()
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

            // For a Jarvis session that is not a command, keyboard focus is the primary signal:
            // editable means dictation, known non-editable means chat. The LLM is only a fallback
            // when Accessibility could not determine the focus. Fn dictation is always typed.
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
                    let focusStatus = session.routingFocus
                    let needsScore = focusStatus == .unknown
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
                        minScore: minScore
                    )
                    owLog("[Addressee] focus \(focusStatus.rawValue), score \(score.map(String.init) ?? "not-used") / threshold \(minScore) → \(route.rawValue) (front: \(front ?? "none"))")
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
            var facts = VoiceRouter.Facts(
                isVoiceCommand: session.isVoiceCommand,
                acceptsCommands: session.acceptsCommands,
                focus: session.routingFocus,
                hasTargetApp: session.targetApp != nil,
                targetBundleID: session.targetApp?.bundleIdentifier,
                pendingDeletion: self.reminderManager?.hasPendingDeletion ?? false,
                voiceTestActive: self.voiceTest.isActive,
                commandAmongPlayback: session.heardOnlyOverPlayback,
                commandContext: commandContext)
            var route = VoiceRouter.route(text, facts: facts)

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

            // The mic stayed open after a command: only a command is taken from it, never
            // dictation or chat (a TV, the song's lyrics, someone else in the room). A bare
            // "sonrakine geç" is about what the command just did.
            if session.takesOnlyCommands {
                var isCommand: Bool {
                    switch route { case .command, .commands: true; default: false }
                }
                if !isCommand, let domain = session.commandFollowUpDomain,
                   let fix = CommandFollowUp.resolve(trimmed, after: domain) {
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

            switch route {
            case .agentWithoutForeground:
                let status = "Önde bir uygulama bulamadım; mesaj gönderilmedi."
                owLog("[Agent] Send skipped: no foreground application")
                self.showFlowBarMessage(status, durationMs: 4500)
                await self.speakReply(status)

            case .agent(let agent):
                owLog("[Route] agent (\(agent.target?.displayName ?? "frontmost app"), send: \(agent.send), session: \(agent.session.rawValue))")
                // "Claude Code'da yeni session aç" alone just opens the session.
                guard !agent.body.isEmpty || agent.session == .new else {
                    owLog("[Agent] Nothing to write after the command words, skipping")
                    return
                }
                @MainActor func fail(_ status: String, spoken: String) async {
                    if !agent.body.isEmpty { self.textInjector?.copyToClipboard(agent.body) }
                    self.showFlowBarMessage(agent.body.isEmpty ? status : "\(status), panoya kopyalandı", durationMs: 4500)
                    if session.isVoiceCommand { await self.speakReply(self.jarvisReply.failure(spoken)) }
                }
                if agent.session != .current, agent.target != .claudeCode {
                    await fail("Session seçimi yalnızca Claude Code'da var", spoken: "session seçimini yalnızca Claude Code'da yapabiliyorum")
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
                        switched = await ClaudeSessionNavigator.openNewSession(app)
                    case .last:
                        guard let name = ClaudeSessionNavigator.lastSessionTitle else {
                            await fail("Son session'ı bilmiyorum", spoken: "son session'ı bilmiyorum")
                            return
                        }
                        switched = await ClaudeSessionNavigator.selectSession(app, titled: name)
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
                        if session.isVoiceCommand { await self.speakReply(self.jarvisReply.newAgentSession()) }
                        return
                    }
                }
                let delivered = await pasteAsDictation(agent.body, targetApp: targetApp, pasteContext: pasteContext, send: agent.send)
                guard delivered else {
                    owLog("[Agent] Not delivered to \(targetApp?.localizedName ?? "?"); not reporting success")
                    await fail(agent.send ? "Mesaj gönderilemedi" : "Mesaj yazılamadı",
                               spoken: agent.send ? "mesajı gönderemedim" : "mesajı yazamadım")
                    return
                }
                if agent.send, let app = targetApp,
                   app.bundleIdentifier.map(AgentApp.claudeCode.bundleIdentifiers.contains) ?? false {
                    ClaudeSessionNavigator.rememberSession(app, wasNew: agent.session == .new)
                }
                if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: agent.send)) }

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

            case .deletionConfirmation:
                // Answered above; a non-answer was routed again without it.
                break

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
                let misheard = self.cleanupAvailable ? self.misheardWords(in: commandText) : []
                let actionStartedAt = session.latency.timestamp()
                let handled = await SpotifyManager.shared.handleCommand(
                    text: commandText, targetApp: session.targetApp, recordUndo: !misheard.isEmpty
                )
                session.latency.record(.action, since: actionStartedAt, detail: "Spotify")
                if handled { session.latency.markOutput("Spotify komutu tamamlandı") }
                owLog("[Result] Spotify command \(handled ? "handled" : "not applied")")
                guard handled else {
                    owLog("[OpenWhisper] Spotify command not applied, falling back to dictation")
                    await dictateOrChat()
                    return
                }
                resumeMediaAfterCommand = resumesMedia
                commandFollowUp = .some(.music)
                self.lastTranscription = text
                // Never "şarkı çalınıyor": only a short ack, spoken before the music resumes.
                if session.isVoiceCommand {
                    await speakAfterCommand(self.jarvisReply.spotify(handled: true, likedSongs: likedSongs))
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
