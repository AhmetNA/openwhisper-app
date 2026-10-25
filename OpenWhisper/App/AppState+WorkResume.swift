import AppKit

extension AppState {
    /// Navigation only. "Continue" never sends a fabricated instruction to an agent.
    func resumeGreetingWork(_ action: WorkResume.Action, context: WorkResume.Context,
                            after session: RecordingTranscriptionSession) async {
        func say(_ text: String) async {
            showFlowBarMessage(text, durationMs: 10000)
            await speakReply(text)
        }
        guard !session.isCancelled, !Task.isCancelled, nextTranscriptionID == session.id,
              recordingState != .recording else { return }
        switch action {
        case .cancel:
            recentWorkContext = nil
            await say("Tamam, bırakalım.")
        case .repeatSummary:
            await say(context.summary)
            _ = listenAfterGreeting(after: session)
        case .resume:
            guard !RemoteControl.screenIsLocked else {
                await say("Kaldığımız işe dönmek için önce Mac'in kilidini açmalısın.")
                return
            }
            guard let agent = context.work?.agent else {
                await say("Dönebileceğim bir çalışma oturumu bulamadım. Hangi projeye dönmek istediğini söyleyebilirsin.")
                _ = listenAfterGreeting(after: session)
                return
            }
            let candidates = await Task.detached(priority: .utility) { CloudSessionNavigation.load(agent) }.value
            guard !session.isCancelled, !Task.isCancelled, nextTranscriptionID == session.id,
                  recordingState != .recording, !RemoteControl.screenIsLocked else { return }
            guard let destination = WorkResume.destination(context, candidates: candidates) else {
                recentWorkContext = nil
                await say("Özetlediğim sohbet artık erişilebilir değil. Yeniden nerede kaldığımızı sorabilirsin.")
                return
            }
            guard let app = await AgentAppActivator.activate(agent) else {
                await say("Çalıştığımız uygulamayı açamadım.")
                return
            }
            guard !session.isCancelled, !Task.isCancelled, nextTranscriptionID == session.id,
                  recordingState != .recording, !RemoteControl.screenIsLocked else { return }
            let opened = agent == .claudeCode
                ? await ClaudeSessionNavigator.openSession(app, id: destination.id, title: destination.title)
                : await CodexSessionNavigator.openThread(app, id: destination.id, title: destination.title)
            guard !session.isCancelled, !Task.isCancelled, nextTranscriptionID == session.id,
                  recordingState != .recording, !RemoteControl.screenIsLocked else { return }
            guard opened, RecordedConversation.capture(app: app)?.sessionID == destination.id else {
                await say("Özetlediğim sohbetin açıldığını doğrulayamadım.")
                return
            }
            owLog("[WorkResume] Returned to the recapped \(agent.rawValue) session")
            await say("Kaldığımız sohbeti açtım, seni dinliyorum.")
            _ = listenAfterGreeting(after: session)
        }
    }
}
