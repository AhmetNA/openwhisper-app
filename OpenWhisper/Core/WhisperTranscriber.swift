import WhisperKit
import Foundation

final class WhisperTranscriber: @unchecked Sendable {
    private var whisperKit: WhisperKit?

    /// Maximum number of glossary prompt tokens to condition the decoder with.
    ///
    /// WhisperKit itself hard-caps `promptTokens` internally at
    /// `(Constants.maxTokenContext / 2) - 1` (= 111 for this model) via
    /// `TextDecoder.prefillDecoderInputs`, applied with `.suffix(...)` — i.e. it would keep
    /// the *last* N tokens if we ever exceeded that, silently reversing our front-of-file
    /// priority ordering. We stay well under it ourselves so our own `.prefix(...)` below is
    /// the one that applies.
    ///
    /// Separately, CLI testing (whisperkit-cli --prompt, same turbo model) showed that
    /// decode can return an empty transcript with conditioning prompts as short as ~33
    /// tokens (8 glossary terms), while ~29 tokens (7 terms) decoded fine, on both short and
    /// medium-length synthetic audio. That is a much tighter practical ceiling than the
    /// architectural 111-token cap, so we stay conservative here too. The runtime fallback
    /// in `transcribe(audioData:language:)` (retry without prompt tokens on an empty result)
    /// is the real safety net against this fragility.
    private static let maxGlossaryPromptTokens = 24

    /// Path to the user's personal glossary file (symlinked to the project's sozluk.txt in dev setups).
    private static var glossaryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenWhisper/glossary.txt")
    }

    /// Reads and parses the glossary file, stripping `#` comments and blank lines.
    /// Tolerates a missing file by returning nil.
    private static func loadGlossaryTerms() -> [String]? {
        guard let contents = try? String(contentsOf: glossaryURL, encoding: .utf8) else {
            return nil
        }
        let terms = contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return terms.isEmpty ? nil : terms
    }

    /// Comma-joined glossary text (nil when the glossary is missing/empty). Re-read from disk
    /// on every call (rather than cached) so an edit to glossary.txt takes effect on the very
    /// next dictation, with no app restart needed.
    private static func glossaryPromptText() -> String? {
        guard let terms = loadGlossaryTerms() else { return nil }
        return terms.joined(separator: ", ")
    }

    /// Encodes the glossary text with the loaded WhisperKit tokenizer and truncates it to
    /// `maxGlossaryPromptTokens`. Returns nil when there is no glossary or no tokenizer available,
    /// so callers can pass it straight through to `DecodingOptions.promptTokens` unchanged.
    /// Re-reads the glossary file and re-tokenizes on every call — the tokenizer is already
    /// loaded in memory, so this is cheap.
    private func glossaryPromptTokens() -> [Int]? {
        guard let text = Self.glossaryPromptText(), !text.isEmpty else { return nil }
        guard let tokenizer = whisperKit?.tokenizer else { return nil }
        let tokens = tokenizer.encode(text: text)
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

        // Glossary conditioning is temporarily disabled. With the current Large v3 Turbo
        // runtime it frequently returns an empty first pass for short Turkish dictation,
        // forcing the fallback decode and adding 6–10 seconds before paste.
        let text = try await runDecode(
            whisperKit: whisperKit,
            audioData: audioData,
            language: language,
            promptTokens: nil
        )

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

    /// Runs a single WhisperKit decode pass with the given (optional) glossary prompt tokens.
    private func runDecode(
        whisperKit: WhisperKit,
        audioData: [Float],
        language: String,
        promptTokens: [Int]?
    ) async throws -> String {
        let options = DecodingOptions(
            task: .transcribe,  // Transcribe in original language, NOT translate to English
            language: language.isEmpty ? nil : language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            sampleLength: 224,
            promptTokens: promptTokens,
            suppressBlank: true,
            supressTokens: nil,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6
        )

        let results = try await whisperKit.transcribe(
            audioArray: audioData,
            decodeOptions: options
        )

        // Log detected language from results
        for (i, result) in results.enumerated() {
            owLog("[Whisper] Result[\(i)] language=\(result.language) text=\(result.text)")
        }

        return results
            .compactMap { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

enum TranscriberError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Whisper model is not loaded."
        }
    }
}
