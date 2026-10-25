import AppKit

extension AppState {
    /// Each recap owns its microphone window; its endpoint must never stop a newer
    /// recording. Spoken input uses the existing command/echo checks; sending requires an explicit send verb.
    func readAgentSessions(_ text: String, selection: UnreadSessionRecap.Selection, after source: RecordingTranscriptionSession) async {
        guard let target = UnreadSessionRecap.target(text, frontBundleID: source.targetApp?.bundleIdentifier) else {
            await speakReply("ChatGPT'deki mi, Claude Code'daki mi cevapları açayım?")
            return
        }
        var items: [UnreadSessionRecap.Item]
        let unreadOnly = selection == .unread
        let currentID = selection == .current ? source.pasteContext.conversation?.sessionID : nil
        do { items = try await Task.detached { try UnreadSessionRecap.load(target, unreadOnly: unreadOnly, sessionID: currentID) }.value }
        catch {
            let message = "\(target.locative) yerel oturum kayıtlarını okuyamadım."
            showFlowBarMessage(message); await speakReply(message); return
        }
        guard !source.isCancelled, !Task.isCancelled else { return }
        switch selection {
        case .unread: break
        case .latest: items = Array(items.prefix(1))
        case .current:
            guard let conversation = source.pasteContext.conversation,
                  conversation.agent.bundleIdentifiers == target.bundleIdentifiers else {
                await speakReply("Açık sohbetin kimliğini doğrulayamadım; son oturumu oku diyebilirsin.")
                return
            }
            items = items.filter { $0.id == conversation.sessionID }
        }
        guard !items.isEmpty else {
            let message = unreadOnly ? "\(target.locative) okunmamış tamamlanmış yanıt yok."
                : "\(target.locative) bu seçim için tamamlanmış bir yanıt bulamadım."
            showFlowBarMessage(message); await speakReply(message); return
        }
        for item in items {
            guard !source.isCancelled, !Task.isCancelled, !RemoteControl.screenIsLocked,
                  recordingState != .recording else { return }
            let readAloud = text.lowercased(with: Locale(identifier: "tr_TR")).range(of: #"\boku(?:r|yabilir|sana)?\b"#, options: .regularExpression) != nil
            let prepared = readAloud && selection != .unread
                ? JarvisChat.speakable(item.exchange.answer)
                : await UnreadSessionRecap.summary(item.exchange, model: ollamaModel, ollamaAvailable: ollamaAvailable)
            guard let summary = prepared, !summary.isEmpty else {
                let message = "Kısa özeti hazırlayamadım; sohbeti okunmamış bıraktım."
                showFlowBarMessage(message); await speakReply(message); return
            }
            // The user may have read or continued this chat while the model summarized it.
            guard let fresh = try? await Task.detached(operation: { try UnreadSessionRecap.load(target, unreadOnly: unreadOnly, sessionID: currentID) }).value,
                  fresh.contains(where: { $0.id == item.id && $0.exchange == item.exchange }) else { continue }
            guard !source.isCancelled, !Task.isCancelled, !RemoteControl.screenIsLocked,
                  recordingState != .recording,
                  let app = await AgentAppActivator.activate(target) else { return }
            let opened = target == .claudeCode
                ? await ClaudeSessionNavigator.openSession(app, id: item.id, title: item.title)
                : await CodexSessionNavigator.openThread(app, id: item.id, title: item.title)
            guard opened, RecordedConversation.capture(app: app)?.sessionID == item.id else {
                let message = "Sohbetin açıldığını doğrulayamadım."
                showFlowBarMessage(message); await speakReply(message); return
            }
            showFlowBarMessage(summary, durationMs: 15000)
            var requestedMic = false
            let previousRecordingID = nextTranscriptionID
            await speakReply(summary)
            if source.isVoiceCommand, source.trigger != .typed, !source.isCancelled,
               recordingState != .recording, hotkey?.isIdle == true,
               microphoneGranted, modelLoaded {
                pendingWakeSpeakerVerified = source.wakeSpeakerVerified
                pendingClaudeMessage = nil
                pendingUnreadRecap = true
                pendingUnreadRecapSessionID = item.id
                pendingCommandFollowUp = .some(nil)
                commandFollowUpOverReply = false
                startVoiceSession(trigger: .followUp)
                requestedMic = hotkey?.isIdle == false
            }
            guard requestedMic else { continue }
            // startRecording is dispatched on the main queue; let that dispatch settle once.
            await Task.yield()
            guard let microphone = activeTranscriptionSession, microphone.id > previousRecordingID,
                  microphone.isUnreadRecapWindow, microphone.unreadRecapSessionID == item.id else {
                pendingUnreadRecap = false
                pendingUnreadRecapSessionID = nil
                pendingCommandFollowUp = nil
                commandFollowUpOverReply = false
                return
            }
            // TTS is finished: two seconds to start, then ordinary silence ends the response.
            var heardSpeech = false
            while activeTranscriptionSession === microphone, recordingState == .recording {
                heardSpeech = heardSpeech || voiceEndpointDetector?.speechDetected == true
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch {
                    if activeTranscriptionSession === microphone {
                        hotkey?.externalCancelHandsFree()
                        stopRecording()
                    }
                    return
                }
            }
            // The recorded command runs after its parent recap returns. Never navigate away
            // while the user is speaking or a different recording has taken over.
            if heardSpeech || activeTranscriptionSession != nil || !microphone.segmentTexts.isEmpty { return }

        }
    }
}
