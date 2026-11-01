import AppKit

/// A Claude Code permission question waiting for its spoken answer.
struct PendingClaudePermission {
    let id: UUID
    let request: ClaudePermission.Request
    /// Nil once answered or given up; the record stays until its recording ends, so a late
    /// "evet" is not taken for a new command.
    var continuation: CheckedContinuation<Data?, Never>?
}

extension AppState {
    func setupClaudePermissions() {
        claudePermissionServer.onRequest = { [weak self] body, id in await self?.askClaudePermission(body, id: id) }
        claudePermissionServer.onAbandoned = { [weak self] id in
            guard let self else { return }
            abandonedClaudePermissions.insert(id)
            resolveClaudePermission(nil, id: id, reason: "answered in Claude")
        }
        claudePermissionServer.start()
    }

    /// Says the question and waits for "evet" / "her zaman" / "hayır …" without the wake word.
    /// Nil (Claude's own prompt decides) when off, busy, unanswered or answered in Claude.
    func askClaudePermission(_ body: Data, id: UUID) async -> Data? {
        defer { abandonedClaudePermissions.remove(id) }
        guard claudeVoicePermissionsEnabled, let request = ClaudePermission.Request(json: body) else { return nil }
        owLog("[ClaudePermission] \(request.tool) asked in \(request.project ?? "?")")
        // A voice profile being recorded would take the answer's recording for its next sample.
        guard !targetSpeakerEnrollmentActive else {
            owLog("[ClaudePermission] Voice profile recording; left to Claude's prompt")
            return nil
        }
        // One question at a time, and not over a command in progress.
        let deadline = Date().addingTimeInterval(30)
        while claudePermissionAsking || recordingState == .recording || isTranscribing || jarvisActivity != .none {
            guard Date() < deadline, !abandonedClaudePermissions.contains(id) else {
                owLog("[ClaudePermission] Busy; left to Claude's prompt")
                return nil
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        guard !abandonedClaudePermissions.contains(id), !targetSpeakerEnrollmentActive,
              hotkey?.isIdle == true, microphoneGranted else { return nil }
        claudePermissionAsking = true
        defer { claudePermissionAsking = false }

        showFlowBarMessage(ClaudePermission.detail(for: request), durationMs: 15000)
        await speakReply(ClaudePermission.question(for: request))
        guard !abandonedClaudePermissions.contains(id), !targetSpeakerEnrollmentActive,
              recordingState != .recording, hotkey?.isIdle == true else { return nil }

        return await withCheckedContinuation { continuation in
            pendingClaudePermission = PendingClaudePermission(id: id, request: request, continuation: continuation)
            startVoiceSession(trigger: .confirmation)
            if hotkey?.isIdle == true {
                endClaudePermission(reason: "mic didn't open")
                return
            }
            // Safety net if the answer's recording never finishes.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, self.pendingClaudePermission?.id == id else { return }
                self.resolveClaudePermission(nil, id: id, reason: "timed out")
                if self.recordingState != .recording { self.pendingClaudePermission = nil }
            }
        }
    }

    /// Hands the hook its answer once; the pending record stays until its recording ends.
    func resolveClaudePermission(_ output: Data?, id: UUID, reason: String) {
        guard pendingClaudePermission?.id == id, let continuation = pendingClaudePermission?.continuation else { return }
        pendingClaudePermission?.continuation = nil
        if output == nil { owLog("[ClaudePermission] No decision (\(reason)); Claude's prompt decides") }
        continuation.resume(returning: output)
    }

    /// The answer's recording ended (or never started): an unanswered question is left to Claude.
    func endClaudePermission(reason: String) {
        guard let pending = pendingClaudePermission else { return }
        resolveClaudePermission(nil, id: pending.id, reason: reason)
        pendingClaudePermission = nil
    }

    /// The `.confirmation` recording after the question: its transcript is the answer.
    func answerClaudePermission(_ pending: PendingClaudePermission, with text: String) async {
        guard pending.continuation != nil else {
            owLog("[ClaudePermission] Answer came after Claude decided: '\(text)'")
            showFlowBarMessage(L("Claude'da zaten cevaplandı.", "Already answered in Claude."), durationMs: 2500)
            return
        }
        guard let answer = ClaudePermission.answer(text) else {
            owLog("[ClaudePermission] Unclear answer: '\(text)'")
            resolveClaudePermission(nil, id: pending.id, reason: "unclear answer")
            await speakReply(L("Anlamadım; karar Claude'un penceresinde.", "I didn't catch that; the decision is in Claude's window."))
            return
        }
        owLog("[ClaudePermission] Answer: \(answer)")
        resolveClaudePermission(ClaudePermission.hookOutput(answer, request: pending.request), id: pending.id, reason: "answered")
        let reply = ClaudePermission.reply(to: answer, request: pending.request)
        if !(await speakReply(reply)) { showFlowBarMessage(reply, durationMs: 2500) }
    }
}
