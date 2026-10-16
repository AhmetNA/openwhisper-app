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
            if session.isVoiceCommand && recordingState != .recording && !holdMediaForFollowUp && !holdMediaForReplyAnswer {
                recordingMedia.end(resuming: resumeMediaAfterCommand)
            }
        }
        let recordingID = await recordingHistoryStore.activeRecordingID(sessionID: session.id)
        do {
            savedRecordings = try await recordingHistoryStore.finish(
                sessionID: session.id,
                keep: !session.isCancelled && !session.historySaveFailed && session.queuedSampleCount >= 6_400,
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
            if !session.hadFailClosedPassthrough &&
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

                if !rawCandidateText.isEmpty, !TargetSpeakerOutputGate.retainsRejectedCandidate(
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
                        targetApp: session.targetApp
                    )
                    textInjector?.copyToClipboard(rawCandidateText)
                    showTargetSpeakerAppendOffer(message: "")
                    owLog("[OpenWhisper] Near-threshold candidate retained for 'Bu benim sesimdi' confirmation without showing error warning")
                } else {
                    dismissFlowBarMessage()
                }
                return
            }
            guard session.queuedSampleCount >= 6400 else {
                owLog("[OpenWhisper] Audio too short (\(session.queuedSampleCount) samples < 0.4s)")
                return
            }

            // Mangled names ("Sputfayda" → "Spotify'da") fixed before routing, so a command is
            // still recognized; the list is the user's ses-benzerleri.txt.
            // Wake sessions now start at the wake itself, so the tail of "Jarvis" can be heard.
            let joined = AudioSegmentation.joinTranscripts(session.segmentTexts)
            let spoken = session.trigger == .wakeWord ? WakeWordVerifier.strippingLeadingWakeWord(joined) : joined
            if spoken != joined { owLog("[WakeWord] Removed the wake word from the transcript start: \(joined)") }
            let (text, soundAlikes) = SoundAlikeCorrector.correct(spoken, entries: SoundAlikeCorrector.loadEntries())
            for (heard, written) in soundAlikes { owLog("[SoundAlike] \(heard) → \(written)") }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("[BLANK"),
                  !trimmed.hasPrefix("(BLANK") else {
                owLog("[OpenWhisper] Empty/blank transcription, skipping")
                return
            }
            guard !AudioSegmentation.isRepetitionHallucination(trimmed) else {
                owLog("[OpenWhisper] Repeated-word hallucination, skipping: \(trimmed)")
                return
            }
            guard !ForeignTranscriptGuard.isForeign(trimmed, misheardCount: misheardWords(in: trimmed).count) else {
                owLog("[OpenWhisper] Not Turkish or English, nothing pasted or run: \(trimmed)")
                showFlowBarMessage("Anlaşılamadı, tekrar söyler misin?")
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
                                self.lastInjectedIsCleaned = false
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
                                        let trimmedCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

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

            // A named target wins; otherwise a Jarvis send goes to the app that was frontmost
            // when recording began. TextInjector still verifies that the destination is safe.
            // "Claude Code'a geç ve şunu yolla …" is the same as naming the app in the command.
            if let agent = AgentCommandParser.parseAfterSwitch(trimmed) ?? AgentCommandParser.parse(trimmed) {
                if session.isVoiceCommand, agent.send, agent.target == nil, session.targetApp == nil {
                    let status = "Önde bir uygulama bulamadım; mesaj gönderilmedi."
                    owLog("[Agent] Send skipped: no foreground application")
                    self.showFlowBarMessage(status, durationMs: 4500)
                    await self.speakReply(status)
                    return
                }
                let routeToAgent = agent.target != nil || (
                    agent.send && session.targetApp != nil && (
                        session.isVoiceCommand || (
                            session.pasteContext.focusStatus == .editable
                                && AgentApp.sendCapableBundleIdentifiers.contains(session.targetApp?.bundleIdentifier ?? "")
                        )
                    )
                )
                if routeToAgent {
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
                    return
                }
            }

            // An explicit "buraya yaz …" or trailing "… bunu yaz" always means the captured
            // text field, even when the words themselves resemble a Jarvis command. A trailing
            // "gönder" outside agent apps is typed without Return, so Slack / Mail are never sent.
            if session.acceptsCommands {
                let typed = JarvisAddressee.leadingTypeCommand(trimmed)
                    ?? JarvisAddressee.trailingTypeCommand(trimmed)
                    ?? AgentCommandParser.parse(trimmed).flatMap { $0.send && !$0.body.isEmpty ? $0.body : nil }
                if let typed {
                    owLog("[Route] explicit dictation override: '\(typed)'")
                    await pasteAsDictation(typed, targetApp: session.targetApp, pasteContext: session.pasteContext, send: false)
                    if session.isVoiceCommand { await self.speakReply(self.jarvisReply.agent(sent: false)) }
                    return
                }
            }

            // An editable field normally routes to dictation. This explicit phrase lets the
            // user talk to Jarvis without first clicking away from the field.
            if session.isVoiceCommand,
               let chatText = JarvisAddressee.explicitChatCommand(trimmed) {
                session.latency.finishDecision(route: "Jarvis sohbet")
                owLog("[Route] explicit Jarvis chat: '\(chatText)'")
                self.lastTranscription = text
                let actionStartedAt = session.latency.timestamp()
                let answer = await self.chatReply(to: chatText)
                session.latency.record(.action, since: actionStartedAt, detail: "Jarvis sohbet")
                session.latency.markOutput("Jarvis cevabı")
                if self.listenForReplyAnswer(answer.text, heard: answer.heard, after: session) {
                    holdMediaForReplyAnswer = true
                }
                return
            }

            // "Günaydın", "Selam Jarvis", "Nasılsın?": answered at once by the clock, no LLM.
            // In a text field it stays dictation ("Selam nasılsın?" typed into WhatsApp).
            if session.isVoiceCommand,
               (VoiceTestInjector.shared.simulatedFocus ?? session.pasteContext.focusStatus) != .editable,
               let greeting = JarvisReply.greeting(in: trimmed) {
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
                if !(await self.speakReply(reply)) { self.showFlowBarMessage(reply, durationMs: 6000) }
                return
            }

            // "Ne dedin?" repeats the last reply; "Ne yapabilirsin?" lists what Jarvis does.
            if session.isVoiceCommand, let meta = JarvisReply.meta(in: trimmed) {
                session.latency.finishDecision(route: "Jarvis hakkında")
                owLog("[Route] meta (\(meta))")
                self.lastTranscription = text
                let reply: String
                switch meta {
                case .repeatLast: reply = self.lastSpokenReply ?? "Henüz bir şey söylemedim."
                case .help: reply = JarvisReply.helpText
                }
                if !(await self.speakReply(reply)) { self.showFlowBarMessage(reply, durationMs: 8000) }
                return
            }

            // "Bunu hatırla: …", "benim adım …", "hakkımda ne biliyorsun?", "… unut".
            if session.isVoiceCommand, let memoryCommand = UserMemoryCommand.parse(trimmed) {
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
                if !(await self.speakReply(reply)) { self.showFlowBarMessage(reply, durationMs: 5000) }
                return
            }

            // A destructive reminder action is always two-step. While a deletion confirmation
            // is pending, only an explicit approval can execute the already-resolved plan; any
            // other ordinary voice response discards it without touching reminders.
            if session.isVoiceCommand,
               let confirmation = await self.reminderManager?.handleDeletionConfirmation(
                   trimmed, alternatives: session.heardVariants
               ) {
                session.latency.finishDecision(route: "hatırlatıcı silme onayı")
                owLog("[Route] reminder deletion confirmation")
                owLog("[Result] Reminder deletion confirmation: \(String(describing: confirmation))")
                self.lastTranscription = text
                let reply = self.jarvisReply.reminderDeletion(confirmation)
                let heard = await self.speakReply(reply)
                if confirmation == .confirmationUnclear {
                    holdMediaForFollowUp = true
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(20))
                        guard let self, self.recordingState != .recording else { return }
                        self.recordingMedia.end(resuming: true)
                    }
                    if !heard { self.showFlowBarMessage(reply, durationMs: 6000) }
                    self.startVoiceSession(trigger: .confirmation)
                }
                return
            }

            // Several commands at once: "sesi kıs ve Bluetooth'u kapat", "Wi-Fi'yi aç, sonra
            // 10 dakikalık alarm kur". Only when every part is a command on its own; otherwise
            // the transcript goes on to the single-command routes below.
            let timers = TimerManager.shared
            if session.acceptsCommands,
               let steps = MultiCommandStep.plan(
                   trimmed, ringing: timers.ringing != nil, active: !timers.timers.isEmpty,
                   installedApps: SystemController.installedApps(), shortcuts: SystemController.shortcutNames
               ) {
                session.latency.finishDecision(route: "çoklu komut")
                owLog("[Route] multi-command (\(steps.count)): \(steps.map { "'\($0.text)' → \($0.command)" }.joined(separator: ", "))")
                self.lastTranscription = text
                let actionStartedAt = session.latency.timestamp()
                var statuses: [String] = []
                var replies: [String?] = []
                // After "Safari'ye geç", later steps belong to the app switched to: Spotify gives
                // focus back to this app if a cold launch stole it.
                var stepTargetApp = session.targetApp
                for step in steps {
                    switch step.command {
                    case .timer(let timerCommand):
                        let status: String
                        if case .alarm(let date, let label) = timerCommand, ClockAlarm.canSet(date),
                           await ClockAlarm.set(date, label: label) {
                            status = "Saat uygulamasına alarm kurdum: \(TimerManager.clock(date, sayDay: true))"
                        } else {
                            status = timers.perform(timerCommand)
                        }
                        owLog("[Result] Timer: \(status)")
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
                        if command == .browser(.summarize) { self.showFlowBarMessage("Sayfa özetleniyor…", durationMs: 30000) }
                        let status = await SystemController.perform(command)
                        if case .video(let action) = command, action.changesPlayback,
                           !VideoController.failures.contains(status) { resumeMediaAfterCommand = false }
                        switch command {
                        case .switchToApp, .switchToAgent: stepTargetApp = NSWorkspace.shared.frontmostApplication
                        default: break
                        }
                        owLog("[Result] System command: \(status)")
                        statuses.append(status)
                        if !step.command.endsSession { replies.append(self.jarvisReply.system(command, status: status)) }
                    case .spotify(let request):
                        let resumes = SpotifyManager.resumesPausedMedia(afterCommand: request)
                        let handled = await SpotifyManager.shared.handleCommand(text: request, targetApp: stepTargetApp)
                        owLog("[Result] Spotify command \(handled ? "handled" : "not applied"): '\(request)'")
                        if handled, !resumes { resumeMediaAfterCommand = false }
                        statuses.append(handled ? "Spotify: \(step.text)" : "Spotify komutu uygulanamadı")
                        replies.append(handled ? self.jarvisReply.spotify(handled: true) : self.jarvisReply.failure("Spotify komutunu uygulayamadım"))
                    }
                }
                session.latency.record(.action, since: actionStartedAt, detail: "çoklu komut")
                session.latency.markOutput("çoklu komut tamamlandı")
                let summary = statuses.joined(separator: " · ")
                self.showFlowBarMessage(summary, durationMs: summary.count > 40 ? 6000 : 3500)
                if session.isVoiceCommand { await self.speakReply(self.jarvisReply.combined(replies)) }
                return
            }

            // "20 dakikalık alarm kur", "10 dakika sonra beni uyar", "saat 7'de beni uyandır",
            // "zamanlayıcı ne kadar kaldı"; while one rings, "tamam" / "5 dakika ertele".
            if session.acceptsCommands,
               let timerCommand = TimerCommandParser.parse(trimmed, ringing: timers.ringing != nil, active: !timers.timers.isEmpty) {
                session.latency.finishDecision(route: "zamanlayıcı")
                owLog("[Route] timer (\(timerCommand))")
                self.lastTranscription = text
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
                session.latency.markOutput("zamanlayıcı")
                self.showFlowBarMessage(status, durationMs: 3500)
                if session.isVoiceCommand { await self.speakReply(self.jarvisReply.timer(timerCommand, status: status)) }
                return
            }

            // "Bluetooth'u kapat", "Wi-Fi'yi aç", "kulaklığın bağlantısını kes": in a Jarvis
            // session and with the dictation keys (`acceptsCommands`); "… bunu yaz" above types
            // them instead. A Jarvis session can run on after the command ("Şarkıyı durdur. Neden. Var öyle…"
            // when the user turns to someone else): if the whole transcript is no command, the
            // first sentence alone may be.
            let firstSentence = session.isVoiceCommand ? Self.leadingSentence(of: trimmed) : nil
            func parseSystem(_ candidate: String) -> SystemCommand? {
                SystemCommandParser.parse(
                    candidate,
                    installedApps: SystemController.installedApps(),
                    shortcuts: candidate.range(of: SystemCommandParser.shortcutMention, options: [.regularExpression, .caseInsensitive]) != nil
                        ? SystemController.shortcutNames() : []
                )
            }
            // Developer mode opens apps and starts music: only when it is the whole transcript.
            if session.acceptsCommands,
               let command = parseSystem(trimmed)
                ?? firstSentence.flatMap(parseSystem).flatMap({ $0 == .developerMode ? nil : $0 }) {
                session.latency.finishDecision(route: "sistem komutu")
                owLog("[Route] system (\(command))")
                // Going to sleep or locking: say it before the Mac stops listening.
                let speaksFirst = ([.sleep, .displaySleep, .lockScreen] as [SystemCommand]).contains(command)
                if speaksFirst && session.isVoiceCommand { await self.speakReply("Görüşürüz.") }
                // The local model takes several seconds on a long page.
                if command == .browser(.summarize) { self.showFlowBarMessage("Sayfa özetleniyor…", durationMs: 30000) }
                let actionStartedAt = session.latency.timestamp()
                let status = await SystemController.perform(command)
                // Liked Songs now play; don't resume what the session paused over them.
                if command == .developerMode { resumeMediaAfterCommand = false }
                // "Videoyu durdur / devam ettir" decided the state; a seek or speed change
                // lets the video the recording paused continue, and so does a failed command.
                if case .video(let action) = command, action.changesPlayback,
                   !VideoController.failures.contains(status) { resumeMediaAfterCommand = false }
                session.latency.record(.action, since: actionStartedAt, detail: "sistem komutu")
                session.latency.markOutput("sistem komutu tamamlandı")
                owLog("[Result] System command: \(status)")
                self.lastTranscription = text
                self.showFlowBarMessage(status, durationMs: status.count > 40 ? 6000 : 2500)
                if !speaksFirst && session.isVoiceCommand { await self.speakReply(self.jarvisReply.system(command, status: status)) }
                return
            }

            // For a Jarvis session that is not a command, keyboard focus is the primary signal:
            // editable means dictation, known non-editable means chat. The LLM is only a fallback
            // when Accessibility could not determine the focus. Fn dictation is always typed.
            @MainActor func dictateOrChat() async {
                let front = session.targetApp?.bundleIdentifier
                if session.isVoiceCommand {
                    let focusStatus = VoiceTestInjector.shared.simulatedFocus ?? session.pasteContext.focusStatus
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
                        if let command = CommandRewriter.safeSystemCommand(rewritten, installedApps: SystemController.installedApps()) {
                            session.latency.finishDecision(route: "LLM ile yeniden yorumlanan komut")
                            owLog("[Route] llm-rewrite '\(trimmed)' → '\(rewritten)' → system (\(command))")
                            self.lastTranscription = text
                            let status = await SystemController.perform(command)
                            if case .video(let action) = command, action.changesPlayback,
                               !VideoController.failures.contains(status) { resumeMediaAfterCommand = false }
                            owLog("[Result] System command: \(status)")
                            self.showFlowBarMessage(status, durationMs: status.count > 40 ? 6000 : 2500)
                            await self.speakReply(self.jarvisReply.system(command, status: status))
                            return
                        }
                        if SpotifyManager.explicitIntent(in: rewritten) != nil {
                            session.latency.finishDecision(route: "LLM ile yeniden yorumlanan komut")
                            owLog("[Route] llm-rewrite '\(trimmed)' → '\(rewritten)' → spotify")
                            self.lastTranscription = text
                            let handled = await SpotifyManager.shared.handleCommand(text: rewritten, targetApp: session.targetApp)
                            owLog("[Result] Spotify command \(handled ? "handled" : "not applied"): '\(rewritten)'")
                            if handled, !SpotifyManager.resumesPausedMedia(afterCommand: rewritten) { resumeMediaAfterCommand = false }
                            await self.speakReply(handled ? self.jarvisReply.spotify(handled: true) : self.jarvisReply.failure("Spotify komutunu uygulayamadım"))
                            return
                        }
                        owLog("[Route] llm-rewrite '\(trimmed)' → '\(rewritten)' recognised by no rule; chatting")
                    }
                    if route == .chat {
                        session.latency.finishDecision(route: "Jarvis sohbet")
                        self.lastTranscription = text
                        let actionStartedAt = session.latency.timestamp()
                        let answer = await self.chatReply(to: trimmed)
                        session.latency.record(.action, since: actionStartedAt, detail: "Jarvis sohbet")
                        session.latency.markOutput("Jarvis cevabı")
                        if self.listenForReplyAnswer(answer.text, heard: answer.heard, after: session) {
                            holdMediaForReplyAnswer = true
                        }
                        return
                    }
                }
                await pasteAsDictation(trimmed, targetApp: session.targetApp, pasteContext: session.pasteContext, send: false)
            }

            let reminderDeletion = session.acceptsCommands
                ? ReminderManager.deletionRequest(trimmed)
                : nil
            let isReminderCommand = reminderDeletion == nil && ReminderManager.isReminder(text)
            var commandText = text
            var isSpotifyCommand = await SpotifyManager.isSpotifyCommand(
                text, ollamaAvailable: self.ollamaAvailable, commandMode: session.acceptsCommands
            )
            if !isSpotifyCommand, !isReminderCommand, let firstSentence,
               await SpotifyManager.isSpotifyCommand(firstSentence, ollamaAvailable: self.ollamaAvailable, commandMode: true) {
                owLog("[Route] first sentence is the command: '\(firstSentence)'")
                commandText = firstSentence
                isSpotifyCommand = true
            }
            owLog("[Route] \(reminderDeletion != nil ? "reminder deletion" : isReminderCommand ? "reminder" : isSpotifyCommand ? "spotify" : "dictation")")
            if let reminderDeletion {
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
                if case .confirmationRequired = result {
                    holdMediaForFollowUp = true
                    Task { @MainActor [weak self] in
                        // Safety net if the confirmation recording never starts.
                        try? await Task.sleep(for: .seconds(20))
                        guard let self, self.recordingState != .recording else { return }
                        self.recordingMedia.end(resuming: true)
                    }
                    if !promptWasHeard {
                        // The voice failed; show the question so the listening window isn't a mystery.
                        owLog("[Reminders] Confirmation prompt not heard; showing it on screen")
                        self.showFlowBarMessage(prompt, durationMs: 6000)
                    }
                    self.startVoiceSession(trigger: .confirmation)
                }
            } else if isReminderCommand {
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
            } else if isSpotifyCommand {
                session.latency.finishDecision(route: "Spotify")
                owLog("[OpenWhisper] Spotify command detected: \(commandText)")
                let resumesMedia = SpotifyManager.resumesPausedMedia(afterCommand: commandText)
                let misheard = self.cleanupAvailable ? self.misheardWords(in: commandText) : []
                let actionStartedAt = session.latency.timestamp()
                let handled = await SpotifyManager.shared.handleCommand(
                    text: commandText, targetApp: session.targetApp, recordUndo: !misheard.isEmpty
                )
                session.latency.record(.action, since: actionStartedAt, detail: "Spotify")
                if handled { session.latency.markOutput("Spotify komutu tamamlandı") }
                owLog("[Result] Spotify command \(handled ? "handled" : "not applied")")
                if handled {
                    resumeMediaAfterCommand = resumesMedia
                    self.lastTranscription = text
                    // Never "şarkı çalınıyor": only a short ack, spoken before the music resumes.
                    if session.isVoiceCommand {
                        await self.speakReply(self.jarvisReply.spotify(handled: true))
                    }
                    if !misheard.isEmpty {
                        owLog("[Misheard] Not Turkish or English: \(misheard.map(\.text)); checking the command again")
                        Task { @MainActor [weak self] in
                            await self?.rerunCorrectedCommand(
                                commandText, misheard: misheard, generation: generation, session: session
                            )
                        }
                    }
                } else {
                    owLog("[OpenWhisper] Spotify command not applied, falling back to dictation")
                    await dictateOrChat()
                }
            } else {
                await dictateOrChat()
            }
        }
    }

    /// The first sentence when the transcript has more than one, for a command followed by
    /// talk that wasn't meant for Jarvis.
    nonisolated static func leadingSentence(of text: String) -> String? {
        guard let end = text.firstIndex(where: { ".!?".contains($0) }) else { return nil }
        let first = text[...end].trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = text[text.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty || first.split(separator: " ").count < 2 ? nil : first
    }
}
