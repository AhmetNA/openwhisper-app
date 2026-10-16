import Foundation

/// The audio half of `WakeWordVerifier`: Whisper on the clip, then SetFit or the local LLM.
extension WakeWordVerifier {
    enum Verdict: Equatable {
        case accepted(String)
        case rejected(String)
    }

    /// Word-only check for a direct detection below `WakeWordListener.confirmedScore`: the
    /// session is already recording, so this only decides whether to throw it away. No LLM:
    /// a clip that really holds "Jarvis" is kept.
    static func heardWakeWord(audio: [Float], transcriber: WhisperTranscriptionService) async -> Verdict {
        do {
            let transcript = try await transcriber.transcribe(audioData: audio, language: "tr", overlapSampleCount: 0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return containsWakeWord(transcript) ? .accepted("heard '\(transcript)'")
                                                : .rejected("no wake word in '\(transcript)'")
        } catch {
            // Whisper trouble must not silence real calls.
            return .accepted("whisper failed, keeping: \(error)")
        }
    }

    /// Runs Whisper and, when needed, the LLM. `audio` is 16 kHz mono in -1…1.
    static func verify(
        audio: [Float],
        transcriber: WhisperTranscriptionService,
        mediaPlaying: Bool,
        ollamaAvailable: Bool,
        model: String
    ) async -> Verdict {
        let transcript: String
        do {
            transcript = try await transcriber.transcribe(audioData: audio, language: "tr", overlapSampleCount: 0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return .rejected("whisper failed: \(error)")
        }
        guard containsWakeWord(transcript) else { return .rejected("no wake word in '\(transcript)'") }
        if isBareCall(transcript) { return .accepted("bare call '\(transcript)'") }
        // The LLM starts together with SetFit, so an unsure SetFit answer costs no extra wait.
        let llm: Task<Bool?, Never>? = ollamaAvailable
            ? Task { await askLLM(transcript: transcript, mediaPlaying: mediaPlaying, model: model) }
            : nil
        // SetFit reads the words only, not whether a song is playing: with media on it may reject
        // but never accept — lyrics are what this check exists to catch, so Ollama (told about
        // the media) or the no-LLM rule still decides those.
        if SetFitDecider.isActive, let decision = await SetFitDecider.decide(.wakeCall, text: transcript), decision.confident {
            if decision.label == "not_call" {
                llm?.cancel()
                return .rejected("SetFit not_call \(decision.confidence): '\(transcript)'")
            }
            if !mediaPlaying {
                llm?.cancel()
                return .accepted("SetFit call \(decision.confidence): '\(transcript)'")
            }
        }
        guard let llm else {
            // Without the LLM, trust the word only when nothing is playing that could have sung it.
            return mediaPlaying ? .rejected("media playing, no LLM: '\(transcript)'")
                                : .accepted("wake word, no LLM: '\(transcript)'")
        }
        switch await llm.value {
        case true?: return .accepted("LLM yes: '\(transcript)'")
        case false?: return .rejected("LLM no: '\(transcript)'")
        case nil:
            return mediaPlaying ? .rejected("LLM unavailable, media playing: '\(transcript)'")
                                : .accepted("LLM unavailable: '\(transcript)'")
        }
    }

    /// true = someone is calling the assistant, false = song/video/talk about it, nil = no answer.
    private static func askLLM(transcript: String, mediaPlaying: Bool, model: String) async -> Bool? {
        let prompt = """
            A voice assistant named Jarvis runs on a Mac and listens to the microphone. It heard a word \
            like "Jarvis" and transcribed the 3 seconds around it (Turkish speech-to-text, so Jarvis may \
            be spelled Cervis, Carvis, Jarvıs and so on).
            Music or video playing on the Mac right now: \(mediaPlaying ? "yes" : "no").

            Answer YES if a person in the room is calling the assistant, for example "Jarvis", \
            "hey Jarvis", "selam Jarvis", "merhaba Jarvis", "Jarvis şarkıyı durdur", "Jarvis bir dakika", "Jarvis sesi kıs".
            Answer NO if it sounds like song lyrics, a video or film, or someone talking about \
            Jarvis to another person, for example "Jarvis'i dün kurdum", "Iron Man'deki Jarvis".

            Transcript: "\(transcript)"
            Answer with one word, YES or NO:
            """
        let request = LLMRequest(model: model, prompt: prompt, timeout: 4, temperature: 0.0, maxTokens: 3)
        guard let answer = (try? await LLM.default.generate(request))?.uppercased() else { return nil }
        if answer.contains("YES") || answer.contains("EVET") { return true }
        if answer.contains("NO") || answer.contains("HAYIR") { return false }
        return nil
    }
}
