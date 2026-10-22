import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    func setupTimers() {
        let timers = TimerManager.shared
        timers.onFire = { [weak self] timer in
            // Music pauses under the chimes, as it does for a voice command.
            self?.recordingMedia.begin()
            Task { @MainActor in await self?.announceTimer(timer) }
        }
        timers.onRingingEnded = { [weak self] in
            // A recording in progress (the stop/snooze answer) resumes it when it ends.
            guard let self, self.recordingState != .recording else { return }
            self.recordingMedia.end(resuming: true)
        }
        timers.onReminderDue = { [weak self] reminder in
            Task { @MainActor in
                guard let self else { return }
                self.showFlowBarMessage("Hatırlatma: \(reminder.task)", durationMs: 8000)
                await self.speakReply(self.jarvisReply.reminderDue(reminder.task))
            }
        }
    }

    func setupWhatsAppAnnouncements() {
        whatsAppWatcher.onAnnounce = { [weak self] announcement in
            Task { @MainActor in await self?.announceWhatsApp(announcement) }
        }
        if whatsAppAnnouncementsEnabled { whatsAppWatcher.start() }
    }

    /// "Dilayım'dan mesaj var, okuyayım mı?", then a short window for "evet" / "hayır"
    /// (`WhatsAppSender.handleConfirmation`). Not while WhatsApp is in front (the user sees
    /// it) or the screen is locked; after a command in progress has finished.
    func announceWhatsApp(_ announcement: WhatsAppWatcher.Announcement) async {
        guard whatsAppAnnouncementsEnabled, voiceRepliesEnabled else { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == WhatsAppSender.bundleIdentifier {
            owLog("[WhatsApp] announcement skipped: WhatsApp is in front")
            return
        }
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true {
            owLog("[WhatsApp] announcement skipped: screen locked")
            return
        }
        let deadline = Date().addingTimeInterval(30)
        while recordingState == .recording || isTranscribing || jarvisActivity != .none, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard recordingState != .recording, !whatsAppSender.hasPending, !(reminderManager?.hasPendingDeletion ?? false) else {
            owLog("[WhatsApp] announcement skipped: Jarvis is busy")
            return
        }
        showFlowBarMessage(announcement.text, durationMs: 8000)
        whatsAppSender.offerRead(announcement.chatIDs)
        guard await speakReply(announcement.text), hotkey?.isIdle == true, microphoneGranted else {
            whatsAppSender.cancel()
            return
        }
        owLog("[WhatsApp] Listening for the answer to the announcement")
        startVoiceSession(trigger: .confirmation)
    }

    /// The first chimes are already playing: say what it was for, then listen briefly for
    /// "tamam" / "5 dakika ertele" without the wake word. The chimes keep coming back until
    /// someone stops them.
    func announceTimer(_ timer: TimerManager.JarvisTimer) async {
        let message = jarvisReply.timerFired(label: timer.label, seconds: timer.seconds)
        showFlowBarMessage(message, durationMs: 8000)
        // It may go off while the user is giving another command: say it once that is done,
        // instead of skipping the announcement (and the stop/snooze listening) entirely.
        let deadline = Date().addingTimeInterval(30)
        while recordingState == .recording || isTranscribing || jarvisActivity != .none, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard TimerManager.shared.ringing?.id == timer.id else { return }
        await speakReply(message)
        guard TimerManager.shared.ringing?.id == timer.id, recordingState != .recording,
              hotkey?.isIdle == true, microphoneGranted else { return }
        owLog("[Timer] Listening for stop / snooze")
        startVoiceSession(trigger: .followUp)
    }

    /// Speaks Jarvis's reply and waits for it, so music paused for the command resumes only
    /// after he is done. Silent when the setting is off or a new recording already started.
    /// `onStart` runs as the voice starts playing (a command opens its follow-up window there).
    @discardableResult
    func speakReply(_ reply: String?, onStart: () -> Void = {}) async -> Bool {
        guard let reply, voiceRepliesEnabled, recordingState != .recording else { return false }
        owLog("[Voice] Reply: '\(reply)'")
        lastSpokenReply = reply
        let heard = await JarvisVoice.shared.speak(reply) { [weak self] in
            self?.jarvisActivity = .speaking
            onStart()
        }
        jarvisActivity = .none
        return heard
    }

    /// A "Jarvis" session that is no command and not meant for Claude Code / Codex: the user is
    /// talking to Jarvis, so the chat model (cloud or local) answers out loud. The voice starts on the first
    /// sentence while the rest is still being written. Without a voice the answer is shown.
    /// Returns the answer (nil when a new recording cut it off) and whether it was heard.
    @discardableResult
    /// `recalled` is set for "geçen hafta ne demiştim?"; such a question is not journaled itself.
    func chatReply(to text: String, recalled: [String] = []) async -> (text: String?, heard: Bool) {
        guard ollamaAvailable || JarvisChat.cloudReady else {
            owLog("[Chat] Neither Ollama nor the cloud model available")
            showFlowBarMessage("Ollama kapalı ve bulut modeli ayarlı değil, sohbet edemiyorum")
            await speakReply(jarvisReply.failure("yerel model şu an kapalı"))
            return (nil, false)
        }
        jarvisActivity = .thinking
        defer { jarvisActivity = .none }
        let context = await JarvisContext.gather()
        owLog("[Chat] Context: \(context.promptLines.joined(separator: " | "))")
        let sentences = JarvisChat.shared.reply(
            to: text, model: ollamaModel, language: JarvisVoice.shared.replyLanguage, context: context.promptLines,
            userFacts: UserMemory.shared.promptLines, recalled: recalled
        )
        var heard = false
        if voiceRepliesEnabled, recordingState != .recording {
            heard = await JarvisVoice.shared.speak(sentences: sentences) { [weak self] in self?.jarvisActivity = .speaking }
        } else {
            for await _ in sentences {}
        }
        guard recordingState != .recording else { return (nil, heard) }
        let answer = JarvisChat.shared.lastReply
        if let answer, !answer.isEmpty {
            lastSpokenReply = answer
            if recalled.isEmpty { JarvisJournal.shared.append(user: text, reply: answer) }
        }
        if !heard, let answer, !answer.isEmpty {
            showFlowBarMessage(answer, durationMs: min(max(answer.count * 60, 3000), 10000))
        }
        return (answer, heard)
    }

    /// Jarvis's answer asked something back ("anlayamadım, biraz daha açık söyler misin?"):
    /// open the mic without the wake word. Silence for `replyFollowUpWindow` closes it; speech
    /// keeps it open like a "Hey Jarvis" session. Returns true when the window opened, so the
    /// caller keeps paused media paused for the answer.
    func listenForReplyAnswer(_ reply: String?, heard: Bool, after session: RecordingTranscriptionSession) -> Bool {
        // A typed request is answered by typing: the panel opens again with the question.
        if session.trigger == .typed {
            if !session.isCancelled, let reply, JarvisChat.awaitsAnswer(reply) { openTypedRequestPanel(prompt: reply) }
            return false
        }
        guard session.isVoiceCommand, !session.isCancelled, let reply, JarvisChat.awaitsAnswer(reply),
              recordingState != .recording, hotkey?.isIdle == true else { return false }
        let chain = session.trigger == .followUp ? replyFollowUpChain + 1 : 1
        guard chain <= Self.maxReplyFollowUps else {
            owLog("[FollowUp] \(Self.maxReplyFollowUps) follow-ups in a row; not listening again")
            return false
        }
        replyFollowUpChain = chain
        // The user who just spoke is answering; carry the session's voice check over.
        pendingWakeSpeakerVerified = session.wakeSpeakerVerified
        Task { @MainActor [weak self] in
            // Safety net if the follow-up recording never starts.
            try? await Task.sleep(for: .seconds(20))
            guard let self, self.recordingState != .recording else { return }
            self.recordingMedia.end(resuming: true)
        }
        if !heard { showFlowBarMessage(reply, durationMs: 6000) }
        owLog("[FollowUp] Reply asks back (\(chain)/\(Self.maxReplyFollowUps)); opening the mic")
        pendingCommandFollowUp = nil
        commandFollowUpOverReply = false
        startVoiceSession(trigger: .followUp)
        return true
    }

    /// A command just ran: listen `commandFollowUpWindow` more without the wake word, so the
    /// user can fix it ("müzik başlat" → "sonrakine geç"). Only a command is taken from that
    /// recording; `domain` tells a bare "sonrakine geç" what to skip. Media is left playing:
    /// the user is judging what the command started.
    /// `overReply`: Jarvis's reply is starting now; the window opens with it and runs until 2 s
    /// after it (`commandFollowUpReplyEnded`). Returns true when the mic opened.
    @discardableResult
    func listenAfterCommand(domain: CommandFollowUp.Domain?, after session: RecordingTranscriptionSession,
                            overReply: Bool = false) -> Bool {
        guard session.isVoiceCommand, session.trigger != .typed, !session.isCancelled, recordingState != .recording,
              hotkey?.isIdle == true, microphoneGranted else { return false }
        // Opening the buds' mic puts them in call mode, which would break the reply playing in
        // them: there the window opens after the reply (the caller's fallback).
        if overReply, Self.inputIsBluetooth(uid: resolvedInputDeviceUID(for: .followUp)) {
            owLog("[FollowUp] Bluetooth input; opening the mic after the reply instead")
            return false
        }
        let chain = session.followsCommand ? commandFollowUpChain + 1 : 1
        guard chain <= Self.maxCommandFollowUps else {
            owLog("[FollowUp] \(Self.maxCommandFollowUps) command follow-ups in a row; not listening again")
            return false
        }
        commandFollowUpChain = chain
        // The user who just gave the command is the one fixing it.
        pendingWakeSpeakerVerified = session.wakeSpeakerVerified
        pendingCommandFollowUp = .some(domain)
        commandFollowUpOverReply = overReply
        owLog("[FollowUp] Command done (\(domain?.rawValue ?? "no domain"), \(chain)/\(Self.maxCommandFollowUps)); opening the mic\(overReply ? " as the reply starts" : "")")
        // The recording starts a moment later (`startRecording` consumes both flags).
        startVoiceSession(trigger: .followUp)
        return hotkey?.isIdle == false
    }
}
