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

    /// Maximum number of glossary prompt tokens to condition the decoder with, IF glossary
    /// conditioning is ever re-enabled (see the `promptTokens: [Int]? = nil` line in
    /// `transcribe(audioData:language:)` — it currently is not).
    ///
    /// EMPIRICAL VERDICT FIRST: glossary conditioning via `DecodingOptions.promptTokens` is not
    /// usable as a general-purpose feature on this model, at any token cap. Testing against the
    /// real glossary.txt (159 terms) and 3 unrelated Turkish test sentences, synthesized with
    /// `say` and transcribed with a temporary local verification harness (since deleted; full
    /// logs are in the task report that introduced this comment), found: at 48 tokens
    /// (sanitized, see below), 2 of 3 sentences decoded to an EMPTY transcript, and the 1 that
    /// didn't came back WORSE than the unprompted baseline ("Cloudflare" was corrupted into
    /// "Claude Flare" — the prompt actively misled the decoder rather than helping it). A cap
    /// sweep at 16/24/32/40/48/64/80/96 tokens against one fixed sentence showed the same
    /// pattern: works or breaks depending on which specific tokens land in which prefill
    /// position, not on token count. There is no cap that reliably fixes this.
    ///
    /// Root causes, both confirmed by reading `TextDecoder.swift`:
    ///
    /// 1. `DecodingOptions.firstTokenLogProbThreshold` (default -1.5) — REAL BUG, FULLY FIXED
    ///    (app-side, see `runDecode`). When `promptTokens` is set, WhisperKit skips the prefill
    ///    KV-cache (`prefilledIndex` stays 0 — `TextDecoder.prefillDecoderInputs`'s
    ///    `options?.promptTokens == nil` guard), so the decode loop's very first inference step
    ///    (`tokenIndex == 0`, right after `<|startofprev|>`) is misclassified as `isFirstToken`.
    ///    The model's prediction there is immediately discarded and overwritten by the forced
    ///    prompt token one line later, but its log-probability is still checked against
    ///    `firstTokenLogProbThreshold`; a low score aborts the whole segment. We now pass `nil`
    ///    for this threshold whenever a prompt is present. This was NOT, however, the actual
    ///    cause of the empty transcripts reproduced above — disabling it did not fix them.
    /// 2. `TextDecoder.decodeText`'s `isSegmentCompleted` check (`sampleResult.completed || ...`,
    ///    TextDecoder.swift ~858-861) has NO `isPrefill` guard — NOT FIXABLE app-side. If the
    ///    sampler's argmax at ANY forced prompt position happens to be `<|endoftext|>` (again, a
    ///    prediction that would otherwise be silently discarded and overwritten by the forced
    ///    prompt token), the whole decode aborts with an empty transcript. This is what actually
    ///    produced every empty result above. It is not gated by prompt length in any clean way —
    ///    a single 4-token prompt ("ChatGPT", unrelated to the test audio) triggered it just as a
    ///    96-token one did — and fixing it requires forking WhisperKit's `TextDecoder`, which is
    ///    out of scope.
    ///
    /// Mitigations applied (kept, and correct, but insufficient on their own — see verdict above):
    ///  - `glossaryPromptText()` strips `.`/`!`/`?` from each term. Sentence-final punctuation
    ///    inside the prompt measurably raised the odds of triggering bug #2 in testing (a 7-term
    ///    prompt ending "...Claude.md, Sonnet..." reliably produced an empty transcript before
    ///    stripping the `.`, and decoded correctly after) — but did not make the full glossary
    ///    reliable, as the verdict above shows.
    ///  - Staying far under WhisperKit's own hard cap on `promptTokens`
    ///    (`(Constants.maxTokenContext / 2) - 1` = `(224 / 2) - 1` = 111, applied via
    ///    `.suffix(...)` in `TextDecoder.prefillDecoderInputs`, which would silently reverse our
    ///    front-of-file term-priority ordering if we ever hit it). This bound is real but was
    ///    never the binding constraint in practice — bug #2 hits well before 111 tokens.
    ///
    /// The glossary is not wasted, though: `LLMCleanup.cleanupPrompt()` (LLMCleanup.swift:44-59)
    /// independently reads the full, untruncated glossary.txt and appends it to the Ollama
    /// cleanup prompt as "KNOWN TECHNICAL TERMS", asking the model to fix misspelled terms
    /// against that list post-decode. That path is entirely separate from this file, has no
    /// token limit, is unaffected by anything above, and is verified (by reading the code, not
    /// just glossary.txt's own header comment) to be live and wired up today.
    private static let maxGlossaryPromptTokens = 48

    /// Comma-joined glossary text (nil when the glossary is missing/empty). Terms come from
    /// `GlossaryStore.terms()`, which caches its parse but invalidates it as soon as the
    /// glossary file's mtime/size changes — so an edit to glossary.txt still takes effect on
    /// the very next dictation, with no app restart needed; we just no longer re-read and
    /// re-parse the file from scratch when nothing has changed.
    ///
    /// Strips `.`/`!`/`?` from each term (e.g. "Claude.md" -> "Claudemd") before joining. This
    /// is a mitigation, not a full fix, for a real WhisperKit bug: `TextDecoder.decodeText`'s
    /// `isSegmentCompleted` check (TextDecoder.swift:858-861) has no `isPrefill` guard, so if
    /// the sampler's argmax at ANY forced prompt position happens to be `<|endoftext|>` — a
    /// prediction that would otherwise be silently discarded and overwritten by the forced
    /// prompt token one line later — the entire decode aborts with an empty transcript. Sentence-
    /// final punctuation inside the prompt measurably raises the odds of that happening (verified
    /// empirically: a 7-term prompt ending in "...Claude.md, Sonnet..." reliably produced an
    /// empty transcript pre-sanitization, and decoded correctly once the `.` was stripped). This
    /// does not eliminate the underlying bug — a long enough / sufficiently audio-irrelevant
    /// prompt can still trigger it even without punctuation — which is why the empty-result
    /// fallback in `transcribe(audioData:language:)` is a real safety net, not a formality. We
    /// cannot fix the root cause without forking WhisperKit's TextDecoder.
    private static func glossaryPromptText() -> String? {
        guard let terms = GlossaryStore.terms() else { return nil }
        let sanitizedTerms = terms.map { term in
            term.filter { !".!?".contains($0) }
        }
        return sanitizedTerms.joined(separator: ", ")
    }

    /// Encodes the glossary text with the loaded WhisperKit tokenizer and truncates it to
    /// `maxGlossaryPromptTokens`. Returns nil when there is no glossary or no tokenizer available,
    /// so callers can pass it straight through to `DecodingOptions.promptTokens` unchanged.
    /// Re-reads the glossary file and re-tokenizes on every call — the tokenizer is already
    /// loaded in memory, so this is cheap.
    private func glossaryPromptTokens() -> [Int]? {
        guard let text = Self.glossaryPromptText(), !text.isEmpty else { return nil }
        guard let tokenizer = whisperKit?.tokenizer else { return nil }
        // `tokenizer.encode(text:)` may include special tokens (e.g. BOS/EOS) depending on the
        // tokenizer implementation. WhisperKit's own prefill strips anything
        // `>= specialTokenBegin` (TextDecoder.swift, prefillDecoderInputs), so keeping them here
        // would waste our `.prefix` budget on tokens that never reach the model. Strip them
        // first so the token count we truncate to is the count that actually lands in the prompt.
        let specialTokenBegin = tokenizer.specialTokens.specialTokenBegin
        let tokens = tokenizer.encode(text: text).filter { $0 < specialTokenBegin }
        guard !tokens.isEmpty else { return nil }
        return Array(tokens.prefix(Self.maxGlossaryPromptTokens))
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

    /// Transcribe 16kHz mono Float32 audio to text
    func transcribe(audioData: [Float], language: String) async throws -> String {
        guard let whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        owLog("[Whisper] Transcribing with language='\(language)' task=transcribe samples=\(audioData.count)")

        // Glossary conditioning via `DecodingOptions.promptTokens` stays DISABLED. This is a
        // deliberate decision, not a leftover — see the long comment on `maxGlossaryPromptTokens`
        // below for the full investigation. Short version: WhisperKit has a real bug
        // (`TextDecoder.decodeText`'s `isSegmentCompleted` has no `isPrefill` guard, so any
        // forced prompt token the sampler would have predicted as `<|endoftext|>` — a prediction
        // that is normally discarded — kills the whole segment) that empirically produces empty
        // or WORSE transcripts even with a short (48-token), punctuation-sanitized glossary
        // prompt (verified with `Tools/GlossaryCheck`, a temporary harness): 2 of 3 test
        // sentences came back empty, and the one that didn't ("Cloudflare" -> "Claude Flare")
        // was actively corrupted relative to the unprompted baseline. We cannot fix the
        // WhisperKit bug without forking `TextDecoder`, which is out of scope. The glossary is
        // still put to use elsewhere: `LLMCleanup.cleanupPrompt()` (LLMCleanup.swift:44-59)
        // independently gives the full glossary (no token limit) to the Ollama cleanup pass and
        // corrects misheard terms against it post-decode — that path is unaffected by any of
        // this and remains the mechanism actually doing glossary-driven correction today.
        //
        // `glossaryPromptTokens()`, the `firstTokenLogProbThreshold` conditional in `runDecode`,
        // and the empty-result fallback below are all still correct, verified fixes to real bugs
        // — they're just currently unused because the whole feature is off. Re-enabling for a
        // short (a handful of terms), hand-picked, audio-relevant prompt is a one-line change
        // (pass `glossaryPromptTokens()` instead of `nil` here) if that's ever worth revisiting.
        let promptTokens: [Int]? = nil

        async let primaryTask = runDecode(
            whisperKit: whisperKit,
            audioData: audioData,
            language: language,
            promptTokens: promptTokens,
            isRecovery: false
        )

        async let recoveryTask = runDecode(
            whisperKit: whisperKit,
            audioData: AudioSignalProcessor.recoverySamples(from: audioData),
            language: language,
            promptTokens: nil,
            isRecovery: true
        )

        var selectedPass = try await primaryTask

        // If primary decode is low confidence, check the parallel recovery decode pass.
        if selectedPass.needsRecovery {
            owLog("[Whisper] Low-confidence decode; evaluating parallel recovery pass")
            let recoveryPass = try await recoveryTask
            if Self.isBetter(recoveryPass, than: selectedPass) {
                owLog("[Whisper] Recovery decode selected text=\(recoveryPass.text)")
                selectedPass = recoveryPass
            } else {
                owLog("[Whisper] Primary decode retained text=\(selectedPass.text)")
            }
        }

        var text = selectedPass.text

        // Whisper can hallucinate the Turkish subtitle-credit phrase "Altyazı M.K."
        // at the end of a recording, especially when the recording ends in silence.
        // Remove only a terminal credit-shaped suffix; an occurrence in the middle of
        // an intentionally dictated sentence must remain untouched.
        let filteredText = Self.removeTrailingSubtitleCredit(from: text)
        if filteredText != text {
            owLog("[Whisper] Removed hallucinated trailing subtitle credit")
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
        async let primaryTimedTask = runDecode(
            whisperKit: whisperKit,
            audioData: audioData,
            language: language,
            promptTokens: nil,
            wordTimestamps: true
        )

        async let recoveryTimedTask = runDecode(
            whisperKit: whisperKit,
            audioData: AudioSignalProcessor.recoverySamples(from: audioData),
            language: language,
            promptTokens: nil,
            wordTimestamps: true
        )

        var selectedPass = try await primaryTimedTask

        if selectedPass.needsRecovery {
            owLog("[Whisper] Low-confidence timed decode; evaluating parallel recovery pass")
            let recoveryPass = try await recoveryTimedTask
            if Self.isBetter(recoveryPass, than: selectedPass) {
                selectedPass = recoveryPass
            }
        }

        var text = selectedPass.text
        let filteredText = Self.removeTrailingSubtitleCredit(from: text)
        if filteredText != text {
            owLog("[Whisper] Removed hallucinated trailing subtitle credit from timed result")
            text = filteredText
        }
        let cleanedText = Self.removeLoopsAndOutros(from: text)
        if cleanedText != text {
            // The word timestamps no longer match the text; keep the text only.
            return cleanedText.isEmpty ? .textOnly("") : .textOnly(cleanedText)
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

        return TimedTranscriptionResult(text: text, words: selectedPass.words)
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

    private static func removeTrailingSubtitleCredit(from text: String) -> String {
        let pattern = #"(?is)(?:^|\s)altyaz(?:ı|i)\s+m\.?\s*k\.?\s*[.!?…]*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let filtered = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
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
