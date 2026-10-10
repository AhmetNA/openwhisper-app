import Foundation
import WhisperKit

/// A source-compatible timed representation of one Whisper word. Keeping this type separate
/// from WhisperKit's `WordTiming` means the rest of OpenWhisper does not depend on WhisperKit's
/// result model and can pass words to the speaker gate without importing WhisperKit.
struct WhisperTimedWord: Sendable, Equatable {
    let word: String
    let start: Float
    let end: Float
    let probability: Float

    init(word: String, start: Float, end: Float, probability: Float) {
        self.word = word
        self.start = start
        self.end = end
        self.probability = probability
    }
}

/// Word-level transcription output used by the optional speaker-aware path.
struct TimedTranscriptionResult: Sendable, Equatable {
    let text: String
    let words: [WhisperTimedWord]

    init(text: String, words: [WhisperTimedWord] = []) {
        self.text = text
        self.words = words
    }

    static func textOnly(_ text: String) -> TimedTranscriptionResult {
        TimedTranscriptionResult(text: text)
    }
}

protocol WhisperTranscriptionService: Sendable {
    func transcribe(audioData: [Float], language: String, overlapSampleCount: Int) async throws -> String
    /// Timed output is an additive requirement with a default implementation. Existing test
    /// fakes and integrations that only implement the long-standing String API therefore remain
    /// source-compatible; only a producer that can provide word timestamps needs to override it.
    func transcribeTimed(
        audioData: [Float],
        language: String,
        overlapSampleCount: Int
    ) async throws -> TimedTranscriptionResult
}

extension WhisperTranscriptionService {
    func transcribeTimed(
        audioData: [Float],
        language: String,
        overlapSampleCount: Int
    ) async throws -> TimedTranscriptionResult {
        .textOnly(try await transcribe(
            audioData: audioData,
            language: language,
            overlapSampleCount: overlapSampleCount
        ))
    }
}

final class WhisperTranscriber: @unchecked Sendable {
    private var whisperKit: WhisperKit?

    private struct DecodePass: Sendable {
        let text: String
        let words: [WhisperTimedWord]
        let averageLogprob: Float?
        let needsRecovery: Bool

        var confidenceScore: Float {
            averageLogprob ?? -Float.greatestFiniteMagnitude
        }
    }

    /// Check if a model is already downloaded locally
    func isModelDownloaded(name: String) -> Bool {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let localModel = appSupport.appendingPathComponent("OpenWhisper/Models/models/argmaxinc/whisperkit-coreml/openai_whisper-\(name)")
        return FileManager.default.fileExists(atPath: localModel.path)
    }

    /// Load a Whisper model by name (e.g., "tiny", "base", "small", "small.en")
    func loadModel(name: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Store models in Application Support (persistent) instead of Caches (macOS purges Caches)
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelBase = appSupport.appendingPathComponent("OpenWhisper/Models")
        try FileManager.default.createDirectory(at: modelBase, withIntermediateDirectories: true)

        // Check if model already exists locally
        let localModel = modelBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(name)")
        let modelFolder: URL

        if FileManager.default.fileExists(atPath: localModel.path) {
            owLog("[Whisper] Model found locally: openai_whisper-\(name)")
            modelFolder = localModel
            progress(0.8)
        } else {
            owLog("[Whisper] Downloading model: openai_whisper-\(name)...")
            modelFolder = try await WhisperKit.download(
                variant: "openai_whisper-\(name)",
                downloadBase: modelBase
            ) { downloadProgress in
                let pct = downloadProgress.fractionCompleted * 0.8
                progress(pct)
            }
            owLog("[Whisper] Download complete at: \(modelFolder.path)")
        }

        // Load from local folder (80% → 100%)
        progress(0.85)
        whisperKit = try await WhisperKit(
            modelFolder: modelFolder.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        progress(1.0)

        // Delete other models to save disk space — only keep the active one
        removeOtherModels(keeping: name, in: modelBase)
    }

    /// Frees the loaded model (~1.5 GB) when another speech model takes over. `loadModel`
    /// loads it again when a Whisper variant is picked.
    func unloadModel() async {
        guard let whisperKit else { return }
        self.whisperKit = nil
        await whisperKit.unloadModels()
        owLog("[Whisper] Model unloaded")
    }

    /// Transcribe 16kHz mono Float32 audio to text
    func transcribe(audioData: [Float], language: String) async throws -> String {
        guard let whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        owLog("[Whisper] Transcribing with language='\(language)' task=transcribe samples=\(audioData.count)")

        // Glossary conditioning via `DecodingOptions.promptTokens` stays DISABLED — a deliberate
        // decision. WhisperKit's `TextDecoder.decodeText` has no `isPrefill` guard on
        // `isSegmentCompleted`, so if the sampler predicts `<|endoftext|>` at any forced prompt
        // position the whole segment aborts. With the real glossary (159 terms, 48-token cap,
        // `.`/`!`/`?` stripped) 2 of 3 test sentences came back empty and the third was worse than
        // baseline ("Cloudflare" -> "Claude Flare"); a 16–96 token cap sweep showed no safe cap.
        // Fixing it needs a WhisperKit fork. Glossary-driven correction happens instead in
        // `LLMCleanup.cleanupPrompt()` (full glossary, post-decode). The prompt-building helpers
        // were removed; see git history if this is ever revisited. The
        // `firstTokenLogProbThreshold` conditional in `runDecode` and the empty-result fallback
        // below are real fixes kept for that case.
        let promptTokens: [Int]? = nil

        // One decode at a time on the shared WhisperKit instance. Running the recovery pass in
        // parallel (`async let`) and dropping it when the primary was confident cancelled a live
        // decode mid-flight; with both on one model that crashed the app (EXC_BAD_ACCESS in an
        // autorelease pool pop, 25–26 Sep 2026, three times). Recovery now runs only when needed.
        var selectedPass = try await runDecode(
            whisperKit: whisperKit,
            audioData: audioData,
            language: language,
            promptTokens: promptTokens,
            isRecovery: false
        )

        if selectedPass.needsRecovery {
            owLog("[Whisper] Low-confidence decode; running recovery pass")
            let recoveryPass = try await runDecode(
                whisperKit: whisperKit,
                audioData: AudioSignalProcessor.recoverySamples(from: audioData),
                language: language,
                promptTokens: nil,
                isRecovery: true
            )
            if Self.isBetter(recoveryPass, than: selectedPass) {
                owLog("[Whisper] Recovery decode selected text=\(recoveryPass.text)")
                selectedPass = recoveryPass
            } else {
                owLog("[Whisper] Primary decode retained text=\(selectedPass.text)")
            }
        }

        var text = selectedPass.text

        // This subtitle-credit hallucination is a hard-denied output artifact. Strip it
        // regardless of position, capitalization, punctuation, or decoder/provider path.
        let filteredText = TranscriptSanitizer.removeForbiddenArtifacts(from: text)
        if filteredText != text {
            owLog("[Whisper] Removed forbidden subtitle credit artifact")
            text = filteredText
        }

        // Remove adjacent repetitive hallucinated sentence loops (e.g. "x. x. x.")
        text = Self.deduplicateRepetitivePhrases(in: text)
        text = Self.removeLoopsAndOutros(from: text)

        // Filter out Whisper hallucinations on silence/noise
        let hallucinations: Set<String> = [
            "Thank you.", "Thanks for watching.", "Subscribe.",
            "you", "You", ".", "", "...", "Thank you for watching.",
            "Bye.", "Bye bye.", "Bye-bye.", "The end.",
            "Thanks.", "Thank you so much.", "See you next time.",
        ]
        if hallucinations.contains(text) { return "" }
        if text.hasPrefix("[") || text.hasPrefix("(") { return "" }  // [BLANK_AUDIO], (silence), etc.
        if text.count < 3 { return "" }  // Too short to be meaningful

        return text
    }

    private static func deduplicateRepetitivePhrases(in text: String) -> String {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count > 1 else { return text }

        var unique: [String] = []
        for part in parts {
            if unique.last?.lowercased() != part.lowercased() {
                unique.append(part)
            }
        }
        let joined = unique.joined(separator: ". ")
        return joined.isEmpty ? text : (joined + ".")
    }

    /// Streaming-aware entry point. The overlap is metadata for the ordered session owner;
    /// samples remain exactly length-preserving after speaker masking and Whisper receives the
    /// same overlap-bearing batch it would have received on the feature-off path.
    func transcribe(
        audioData: [Float],
        language: String,
        overlapSampleCount: Int
    ) async throws -> String {
        owLog("[Whisper] Transcribing batch samples=\(audioData.count) overlap=\(overlapSampleCount)")
        return try await transcribe(audioData: audioData, language: language)
    }

    /// Produces Whisper word timestamps for the optional speaker-aware integration path. This
    /// deliberately shares the normal decode/recovery logic, but enables WhisperKit's alignment
    /// pass with `DecodingOptions.wordTimestamps`. The existing String API remains the fast,
    /// source-compatible default for callers that do not need timed filtering.
    func transcribeTimed(
        audioData: [Float],
        language: String,
        overlapSampleCount: Int
    ) async throws -> TimedTranscriptionResult {
        guard let whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        owLog("[Whisper] Timed transcription samples=\(audioData.count) overlap=\(overlapSampleCount)")
        // Sequential for the same reason as `transcribe(audioData:language:)`.
        var selectedPass = try await runDecode(
            whisperKit: whisperKit,
            audioData: audioData,
            language: language,
            promptTokens: nil,
            wordTimestamps: true
        )

        if selectedPass.needsRecovery {
            owLog("[Whisper] Low-confidence timed decode; running recovery pass")
            let recoveryPass = try await runDecode(
                whisperKit: whisperKit,
                audioData: AudioSignalProcessor.recoverySamples(from: audioData),
                language: language,
                promptTokens: nil,
                wordTimestamps: true
            )
            if Self.isBetter(recoveryPass, than: selectedPass) {
                selectedPass = recoveryPass
            }
        }

        var text = selectedPass.text
        var words = selectedPass.words
        let filteredText = TranscriptSanitizer.removeForbiddenArtifacts(from: text)
        if filteredText != text {
            owLog("[Whisper] Removed forbidden subtitle credit artifact from timed result")
            text = filteredText
        }
        text = Self.removeLoopsAndOutros(from: text)
        if text != selectedPass.text {
            // Returning text without timings used to make diarization drop the whole batch
            // ("Metin çıkarılamadı" after 30 s of speech). Keep the timings of the surviving words.
            words = Self.alignWords(words, to: text)
            owLog("[Whisper] Timed result cleaned; kept \(words.count)/\(selectedPass.words.count) word timings")
            if text.isEmpty { return .textOnly("") }
            if words.isEmpty { return .textOnly(text) }
        }

        let hallucinations: Set<String> = [
            "Thank you.", "Thanks for watching.", "Subscribe.",
            "you", "You", ".", "", "...", "Thank you for watching.",
            "Bye.", "Bye bye.", "Bye-bye.", "The end.",
            "Thanks.", "Thank you so much.", "See you next time.",
        ]
        if hallucinations.contains(text) || text.hasPrefix("[") || text.hasPrefix("(") || text.count < 3 {
            return .textOnly("")
        }

        return TimedTranscriptionResult(text: text, words: words)
    }

    /// Keeps, in order, the timed words that still appear in `cleanedText` after an artifact,
    /// outro, or loop was removed from the decoded text. A word Whisper split into pieces
    /// ("Cer" + "vis") is kept when its pieces together form one remaining token.
    static func alignWords(_ words: [WhisperTimedWord], to cleanedText: String) -> [WhisperTimedWord] {
        func normalized(_ text: String) -> String {
            String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }
        let tokens = cleanedText.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }.filter { !$0.isEmpty }
        let keys = words.map { normalized($0.word) }
        var kept: [WhisperTimedWord] = []
        var tokenIndex = 0
        var wordIndex = 0
        while wordIndex < words.count, tokenIndex < tokens.count {
            if keys[wordIndex].isEmpty {
                wordIndex += 1
                continue
            }
            var joined = ""
            var end = wordIndex
            while end < words.count, joined.count < tokens[tokenIndex].count, end - wordIndex < 6 {
                joined += keys[end]
                end += 1
            }
            if joined == tokens[tokenIndex] {
                kept.append(contentsOf: words[wordIndex..<end])
                wordIndex = end
                tokenIndex += 1
            } else if let skip = (1...3).first(where: {
                tokenIndex + $0 < tokens.count && tokens[tokenIndex + $0] == keys[wordIndex]
            }) {
                // A cleaned token with no timed word of its own; resync on the next ones.
                tokenIndex += skip
            } else {
                wordIndex += 1
            }
        }
        return kept
    }

    /// Collapses decoding loops ("abone ol" ×70), strips a YouTube outro from the end, and
    /// drops a transcript that is only an outro. Both decode passes can loop the same way, so this runs on the chosen one.
    private static func removeLoopsAndOutros(from text: String) -> String {
        var result = AudioSegmentation.collapseRepetitionLoops(text)
        if result != text {
            owLog("[Whisper] Collapsed repetition loop: '\(text.prefix(80))…' → '\(result)'")
        }
        let withoutOutro = AudioSegmentation.removeTrailingOutros(result)
        if withoutOutro != result {
            owLog("[Whisper] Removed hallucinated trailing outro: '\(result)' → '\(withoutOutro)'")
            result = withoutOutro
        }
        if AudioSegmentation.isKnownHallucination(result) {
            owLog("[Whisper] Dropped hallucinated outro: '\(result)'")
            result = ""
        }
        return result
    }

    /// Runs a single WhisperKit decode pass with the given (optional) glossary prompt tokens.
    private func runDecode(
        whisperKit: WhisperKit,
        audioData: [Float],
        language: String,
        promptTokens: [Int]?,
        wordTimestamps: Bool = false,
        isRecovery: Bool = false
    ) async throws -> DecodePass {
        // Disabling `firstTokenLogProbThreshold` (setting to `nil`) prevents WhisperKit from aborting
        // token generation when initial quiet frames or room noise precede speech.
        let firstTokenLogProbThreshold: Float? = nil

        let options = DecodingOptions(
            task: .transcribe,  // Transcribe in original language, NOT translate to English
            language: language.isEmpty ? nil : language,
            temperature: 0.0,
            temperatureFallbackCount: 0,
            sampleLength: 224,
            wordTimestamps: wordTimestamps,
            promptTokens: promptTokens,
            suppressBlank: true,
            supressTokens: nil,
            compressionRatioThreshold: 2.0,
            logProbThreshold: isRecovery ? -1.8 : -1.2,
            firstTokenLogProbThreshold: firstTokenLogProbThreshold,
            // Relax non-speech threshold (0.65 on primary, 0.85 on recovery) so quiet or delayed speech
            // is not prematurely discarded before decoding completes.
            noSpeechThreshold: isRecovery ? 0.85 : 0.65,
            // Let WhisperKit seek through a long three-minute batch using its own timestamps.
            // The app must not pre-split that batch into many independent decoder calls.
            chunkingStrategy: ChunkingStrategy.none
        )

        let results = try await whisperKit.transcribe(
            audioArray: audioData,
            decodeOptions: options
        )

        // Log detected language and confidence metrics from results. The metrics let the caller
        // retry only weak passes instead of blindly decoding every recording twice.
        for (i, result) in results.enumerated() {
            let avgLogprob = result.segments.isEmpty
                ? nil
                : result.segments.map(\.avgLogprob).reduce(0, +) / Float(result.segments.count)
            let maxNoSpeech = result.segments.map(\.noSpeechProb).max() ?? 0
            let maxCompression = result.segments.map(\.compressionRatio).max() ?? 0
            owLog("[Whisper] Result[\(i)] language=\(result.language) avgLogprob=\(String(describing: avgLogprob)) noSpeech=\(maxNoSpeech) compression=\(maxCompression) text=\(result.text)")
        }

        let text = results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let segments = results.flatMap(\.segments)
        let words = wordTimestamps
            ? segments.flatMap { segment in
                (segment.words ?? []).map {
                    WhisperTimedWord(
                        word: $0.word,
                        start: $0.start,
                        end: $0.end,
                        probability: $0.probability
                    )
                }
            }
            : []
        let averageLogprob = segments.isEmpty
            ? nil
            : segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
        let weakLogprob = averageLogprob.map { $0 < -0.72 } ?? true
        let suspiciousCompression = segments.contains { $0.compressionRatio > 2.2 }

        return DecodePass(
            text: text,
            words: words,
            averageLogprob: averageLogprob,
            needsRecovery: text.isEmpty || weakLogprob || suspiciousCompression
        )
    }

    private static func isBetter(_ candidate: DecodePass, than current: DecodePass) -> Bool {
        guard !candidate.text.isEmpty else { return false }
        guard current.text.isEmpty else {
            if candidate.confidenceScore >= current.confidenceScore + 0.08 {
                return true
            }
            // If confidence is effectively tied, prefer the recovery result only when it
            // recovered a meaningful amount of text rather than adding random words.
            return candidate.text.count >= current.text.count + 4
                && candidate.confidenceScore >= current.confidenceScore - 0.10
        }
        return true
    }

    /// Keep only the 2 most recent models on disk, delete the rest
    private func removeOtherModels(keeping activeName: String, in modelBase: URL) {
        let fm = FileManager.default
        let activeModel = "openai_whisper-\(activeName)"
        guard let repos = try? fm.contentsOfDirectory(at: modelBase, includingPropertiesForKeys: nil) else { return }
        for repo in repos where repo.hasDirectoryPath {
            guard let variants = try? fm.contentsOfDirectory(
                at: repo,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            // Get all model folders sorted by modification date (newest first)
            let models = variants
                .filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
                .sorted {
                    let d1 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let d2 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return d1 > d2
                }

            // Keep the active model + 1 most recent other model (max 2 total)
            var kept = Set<String>()
            kept.insert(activeModel)
            for model in models where kept.count < 2 {
                kept.insert(model.lastPathComponent)
            }

            for model in models where !kept.contains(model.lastPathComponent) {
                try? fm.removeItem(at: model)
                owLog("[Whisper] Removed old model: \(model.lastPathComponent)")
            }
        }
    }
}

extension WhisperTranscriber: WhisperTranscriptionService {}

enum TranscriberError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Whisper model is not loaded."
        }
    }
}
