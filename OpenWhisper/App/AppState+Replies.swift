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
    @discardableResult
    func speakReply(_ reply: String?) async -> Bool {
        guard let reply, voiceRepliesEnabled, recordingState != .recording else { return false }
        owLog("[Voice] Reply: '\(reply)'")
        lastSpokenReply = reply
        let heard = await JarvisVoice.shared.speak(reply) { [weak self] in self?.jarvisActivity = .speaking }
        jarvisActivity = .none
        return heard
    }

    /// A "Jarvis" session that is no command and not meant for Claude Code / Codex: the user is
    /// talking to Jarvis, so the local LLM answers out loud. The voice starts on the first
    /// sentence while the rest is still being written. Without a voice the answer is shown.
    /// Returns the answer (nil when a new recording cut it off) and whether it was heard.
    @discardableResult
    /// `recalled` is set for "geçen hafta ne demiştim?"; such a question is not journaled itself.
    func chatReply(to text: String, recalled: [String] = []) async -> (text: String?, heard: Bool) {
        guard ollamaAvailable else {
            owLog("[Chat] Ollama not available")
            showFlowBarMessage("Ollama kapalı, sohbet edemiyorum")
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
        startVoiceSession(trigger: .followUp)
        return true
    }
}
