import Foundation

/// Second stage for wake-word scores in the grey zone (between the candidate and the direct
/// threshold): Whisper transcribes the ~3.5 s around the candidate, the transcript must contain
/// a "Jarvis"-like word, and then the local LLM judges whether someone is calling the assistant
/// or the word came from a song, a video or talk about Jarvis. It checks the word only, never
/// who said it.
enum WakeWordVerifier {
    enum Verdict: Equatable {
        case accepted(String)
        case rejected(String)
    }

    /// Word shapes after `fold`: Whisper writes a Turkish "Jarvis" as Cervis, Carvis, Jarvıs,
    /// Çarvis, Jervis, Jarviz…; folding maps all of those to "jarvis".
    private static let target = "jarvis"

    /// Lowercases and merges the letters Whisper swaps for this word.
    static func fold(_ word: String) -> String {
        let lowered = word.lowercased(with: Locale(identifier: "tr_TR"))
        var out = ""
        for ch in lowered {
            switch ch {
            case "c", "ç", "j", "ş", "g": out.append("j")
            case "e", "a", "â": out.append("a")
            case "ı", "i", "î", "y": out.append("i")
            case "w", "b", "v": out.append("v")
            case "z", "s": out.append("s")
            default:
                if ch.isLetter { out.append(ch) }
            }
        }
        return out
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
            .map { String($0.split(whereSeparator: { $0 == "'" || $0 == "’" }).first ?? $0) }
            .filter { !$0.isEmpty }
    }

    /// Whether the transcript holds the wake word, also split in two ("Car vis") or carrying a
    /// Turkish suffix ("Jarvis'e", "Cervisim").
    static func containsWakeWord(_ text: String) -> Bool {
        let folded = words(text).map(fold)
        var candidates = folded
        for i in folded.indices.dropLast() { candidates.append(folded[i] + folded[i + 1]) }
        return candidates.contains { word in
            // "Servis", "Harvey"… sit one edit away; a real call always starts with a j-like sound.
            guard word.count >= 5, word.first == "j" else { return false }
            if editDistance(word, target) <= 1 { return true }
            // Suffixed forms: compare the stem only.
            return word.count > target.count && editDistance(String(word.prefix(target.count)), target) <= 1
        }
    }

    /// "Jarvis" alone or with a filler ("hey Jarvis", "Jarvis?") is plainly a call: no LLM needed.
    static func isBareCall(_ text: String) -> Bool {
        let rest = words(text).map(fold).filter { editDistance($0, target) > 1 && !fillers.contains($0) }
        return rest.isEmpty
    }

    /// Greetings count too: "Selam Jarvis", "Merhaba Jarvis", "Günaydın Jarvis" are calls.
    private static let fillers = Set(["hey", "hi", "hello", "ah", "eh", "ee", "hadi", "ok", "okay", "alo", "şey",
                                      "selam", "selamlar", "merhaba", "günaydın", "naber", "iyi", "akşamlar", "geceler"].map(fold))

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
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
        guard ollamaAvailable else {
            // Without the LLM, trust the word only when nothing is playing that could have sung it.
            return mediaPlaying ? .rejected("media playing, no LLM: '\(transcript)'")
                                : .accepted("wake word, no LLM: '\(transcript)'")
        }
        switch await askLLM(transcript: transcript, mediaPlaying: mediaPlaying, model: model) {
        case true?: return .accepted("LLM yes: '\(transcript)'")
        case false?: return .rejected("LLM no: '\(transcript)'")
        case nil:
            return mediaPlaying ? .rejected("LLM unavailable, media playing: '\(transcript)'")
                                : .accepted("LLM unavailable: '\(transcript)'")
        }
    }

    /// true = someone is calling the assistant, false = song/video/talk about it, nil = no answer.
    private static func askLLM(transcript: String, mediaPlaying: Bool, model: String) async -> Bool? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 4
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "think": false,
            "keep_alive": LLMCleanup.keepAlive,
            "options": ["temperature": 0.0, "num_predict": 3]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = data
        guard let (reply, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let answer = (json["response"] as? String)?.uppercased()
        else { return nil }
        if answer.contains("YES") || answer.contains("EVET") { return true }
        if answer.contains("NO") || answer.contains("HAYIR") { return false }
        return nil
    }
}
