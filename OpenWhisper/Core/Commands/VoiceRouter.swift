import Foundation

/// Where a transcript goes, decided by the rules alone. `AppState.finishTranscription` runs
/// the decision; `RouteCorpusTests` checks it against real transcripts, so both read the
/// same order. Models (Ollama, SetFit) and keyboard focus scoring only come in at the last
/// step, `.spotifyOrConversation`, which the app settles itself.
///
/// The order is the meaning: the first rule that claims the text wins. Add a new route as
/// a case here, at the place it should take precedence, not as a branch in `AppState`.
@MainActor
enum VoiceRouter {
    /// What the rules need to know about the session and the app.
    struct Facts {
        /// A Jarvis session (wake word, Jarvis key, follow-up), not dictation keys.
        var isVoiceCommand: Bool
        /// Jarvis sessions and the dictation keys run commands; other triggers only type.
        var acceptsCommands: Bool
        /// Keyboard focus when recording began (a voice test may simulate it).
        var focus: TextFocusStatus
        /// The app that was frontmost when recording began.
        var hasTargetApp: Bool
        var targetBundleID: String?
        /// A reminder deletion waits for "evet" / "hayır".
        var pendingDeletion = false
        /// A WhatsApp message waits for "evet" / "hayır" (`WhatsAppSender`).
        var pendingWhatsAppSend = false
        /// Test mode reads TODO items aloud; "geçti" / "kaldı" / "atla" answer it.
        var voiceTestActive = false
        /// The words came from audio the profile rejected while the Mac played a song or video
        /// (`RecordingTranscriptionSession.heardOnlyOverPlayback`): the user's command can sit
        /// between the video's sentences ("… Videonun durdur. Çok yavaş …"), so any one may be it.
        var commandAmongPlayback = false
        /// Built only when a command rule is reached: it lists the installed apps.
        var commandContext: @MainActor () -> CommandRegistry.Context = { CommandRegistry.Context() }
    }

    enum Route {
        /// "… gönder" in a Jarvis session with no app in front: nothing to send to.
        case agentWithoutForeground
        /// "Claude Code'a yaz …", or "… gönder" into the frontmost agent app.
        case agent(AgentDictation)
        /// "Claude'da son session'ı özetle": two spoken sentences, then the next words go there.
        case claudeSessionRecap
        /// "Buraya yaz …", "… bunu yaz": always typed, even if the words are a command.
        case typed(String)
        /// "Jarvis, …" said while a text field has focus.
        case chat(String)
        case greeting(JarvisReply.Greeting)
        case meta(JarvisReply.Meta)
        case memory(UserMemoryCommand)
        /// "Test modunu başlat", then "geçti" / "kaldı …" / "atla" / "tekrar oku" / "bitir".
        case voiceTest(VoiceTestCommand)
        /// "Dün ne konuşmuştuk?": answered from that day's journal lines.
        case pastConversation(TimeQuery)
        /// The answer to a pending reminder deletion. The app may find it is not one (a new
        /// delete command, an expired plan): it then routes again without `pendingDeletion`.
        case deletionConfirmation
        /// "Dilayım'a yaz: akşam geliyorum": read back, sent only after a yes.
        case whatsAppSend(WhatsAppOutgoing)
        /// The answer to a pending WhatsApp message; like `deletionConfirmation`, the app
        /// routes again without `pendingWhatsAppSend` when it is no answer.
        case whatsAppConfirmation
        /// Several commands at once: "sesi kıs ve Bluetooth'u kapat".
        case commands([MultiCommandSplitter.Step<VoiceCommand>])
        case command(VoiceCommand)
        case reminderDeletion(ReminderManager.DeletionRequest)
        case reminder
        /// No rule claimed it: Spotify (with the models' help) for the text or its first
        /// sentence, else dictation or chat by keyboard focus.
        case spotifyOrConversation(firstSentence: String?)
    }

    static func route(_ text: String, facts: Facts) -> Route {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = facts.isVoiceCommand

        // A named target wins; otherwise a Jarvis send goes to the app that was frontmost
        // when recording began. TextInjector still verifies that the destination is safe.
        // "Claude Code'a geç ve şunu yolla …" is the same as naming the app in the command.
        if case .agent(let agent)? = CommandRegistry.match(trimmed, in: [.agent], context: CommandRegistry.Context()) {
            if voice, agent.send, agent.target == nil, !facts.hasTargetApp {
                return .agentWithoutForeground
            }
            let toAgent = agent.target != nil || (
                agent.send && facts.hasTargetApp && (
                    voice || (
                        facts.focus == .editable
                            && AgentApp.sendCapableBundleIdentifiers.contains(facts.targetBundleID ?? "")
                    )
                )
            )
            if toAgent { return .agent(agent) }
        }

        // "Dilayım'a yaz: …", "Ali'ye mesaj at …": before the typed rule, which would read a
        // trailing "… mesaj yaz" as dictation. Nothing is sent before a spoken yes.
        if facts.acceptsCommands, let outgoing = WhatsAppSendParser.parse(trimmed) {
            return .whatsAppSend(outgoing)
        }

        // An explicit "buraya yaz …" or trailing "… bunu yaz" always means the captured
        // text field, even when the words themselves resemble a Jarvis command. A trailing
        // "gönder" outside agent apps is typed without Return, so Slack / Mail are never sent.
        if facts.acceptsCommands,
           let typed = JarvisAddressee.leadingTypeCommand(trimmed)
            ?? JarvisAddressee.trailingTypeCommand(trimmed)
            ?? AgentCommandParser.parse(trimmed).flatMap({ $0.send && !$0.body.isEmpty ? $0.body : nil }) {
            return .typed(typed)
        }

        if voice {
            // First: "evet" / "tamam" would otherwise read as a greeting or a meta answer.
            if facts.pendingWhatsAppSend { return .whatsAppConfirmation }
            if AgentCommandParser.isSessionSummaryRequest(trimmed) { return .claudeSessionRecap }
            // An editable field normally routes to dictation. This explicit phrase lets the
            // user talk to Jarvis without first clicking away from the field.
            if let chatText = JarvisAddressee.explicitChatCommand(trimmed) { return .chat(chatText) }
            // In a text field a greeting stays dictation ("Selam nasılsın?" typed into WhatsApp).
            if facts.focus != .editable, let greeting = JarvisReply.greeting(in: trimmed) { return .greeting(greeting) }
            if let test = VoiceTestCommand.parse(trimmed, active: facts.voiceTestActive) { return .voiceTest(test) }
            if let meta = JarvisReply.meta(in: trimmed) { return .meta(meta) }
            if let memory = UserMemoryCommand.parse(trimmed) { return .memory(memory) }
            if let query = TimeQuery.parse(trimmed) { return .pastConversation(query) }
            // A destructive reminder action is always two-step: while a confirmation is
            // pending, the answer goes to it before any command rule.
            if facts.pendingDeletion { return .deletionConfirmation }
        }

        let firstSentence = voice ? leadingSentence(of: trimmed) : nil
        if facts.acceptsCommands {
            let context = facts.commandContext()
            // Only when every part is a command on its own; otherwise the transcript goes on
            // to the single command below.
            if let steps = CommandRegistry.plan(trimmed, context: context) { return .commands(steps) }
            // A Jarvis session can run on after the command ("Şarkıyı durdur. Neden. Var
            // öyle…" when the user turns to someone else): if the whole transcript is no
            // command, the first sentence alone may be. Developer mode opens apps and starts
            // music: only when it is the whole transcript.
            if let command = CommandRegistry.match(trimmed, in: CommandRegistry.commandDomains, context: context)
                ?? firstSentence.flatMap({ CommandRegistry.match($0, in: CommandRegistry.systemDomains, context: context) })
                    .flatMap({ $0 == .system(.developerMode) ? nil : $0 }) {
                return .command(command)
            }
            if facts.commandAmongPlayback,
               let command = sentences(of: trimmed).lazy
                .compactMap({ CommandRegistry.match($0, in: CommandRegistry.systemDomains, context: context) })
                .first(where: { $0 != .system(.developerMode) }) {
                return .command(command)
            }
            if let deletion = ReminderManager.deletionRequest(trimmed) { return .reminderDeletion(deletion) }
        }
        if ReminderManager.isReminder(text) { return .reminder }
        return .spotifyOrConversation(firstSentence: firstSentence)
    }

    /// The first sentence when the transcript has more than one, for a command followed by
    /// talk that wasn't meant for Jarvis.
    /// Every sentence of the transcript, in order.
    nonisolated static func sentences(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: true) { ".!?".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func leadingSentence(of text: String) -> String? {
        guard let end = text.firstIndex(where: { ".!?".contains($0) }) else { return nil }
        let first = text[...end].trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = text[text.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty || first.split(separator: " ").count < 2 ? nil : first
    }
}
