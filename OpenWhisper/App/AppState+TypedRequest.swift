import AppKit

extension AppState {
    /// Typed request shortcut (⌃M by default): opens the panel, or closes it when open.
    func toggleTypedRequestPanel() {
        if typedRequestPanel?.isShown == true {
            typedRequestPanel?.hide()
        } else {
            openTypedRequestPanel(prompt: nil)
        }
    }

    /// Shows the "write to Jarvis" panel; `prompt` is a question Jarvis asked back. Not while a
    /// recording runs: hands-free mode takes Enter and Space for itself.
    func openTypedRequestPanel(prompt: String?) {
        guard recordingState != .recording, hotkey?.isIdle != false else {
            owLog("[TypedRequest] Recording in progress; panel not opened")
            return
        }
        // The panel never activates OpenWhisper, so the app behind it is still frontmost; its
        // focus is read before the panel takes the keyboard.
        let app = NSWorkspace.shared.frontmostApplication
        typedRequestTargetApp = app
        typedRequestPasteContext = Task.detached(priority: .userInitiated) {
            PasteContext.capture(targetApp: app)
        }
        typedRequestPanel?.show(prompt: prompt)
        if ollamaAvailable && !JarvisChat.cloudReady {
            let model = SpotifyManager.selectedOllamaModel
            Task.detached { await LLMCleanup.warmUp(model: model) }
        }
        JarvisVoice.shared.warmUp()
    }

    /// Enter in the panel: the text goes where a "Hey Jarvis" transcript goes, in the same
    /// queue, so it never runs alongside a voice session still being transcribed.
    func submitTypedRequest(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, recordingState != .recording else { return }
        owLog("[TypedRequest] '\(trimmed)'")
        let app = typedRequestTargetApp
        let contextTask = typedRequestPasteContext
        typedRequestPasteContext = nil

        nextTranscriptionID &+= 1
        let session = RecordingTranscriptionSession(
            id: nextTranscriptionID,
            targetApp: app,
            targetSpeakerEnabled: false,
            targetSpeakerProfile: nil,
            pasteContext: PasteContext.initial(targetApp: app)
        )
        session.trigger = .typed
        session.isVoiceCommand = true
        session.wakeSpeakerVerified = true
        session.segmentTexts = [trimmed]
        session.allSegmentTexts = [trimmed]
        pendingTranscriptionCount += 1
        if recordingState == .idle { recordingState = .transcribing }

        let previousTask = transcriptionQueueTail
        let task = Task { @MainActor [weak self] in
            if let contextTask { session.pasteContext = await contextTask.value }
            if let previousTask { await previousTask.value }
            guard let self else { return }
            await self.finishTranscription(session)
        }
        session.task = task
        transcriptionQueueTail = task
        transcriptionQueueTailID = session.id
    }
}
