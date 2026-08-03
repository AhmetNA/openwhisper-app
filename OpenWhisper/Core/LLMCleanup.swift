import Foundation

final class LLMCleanup: Sendable {
    private let baseURL = "http://localhost:11434"
    let model: String

    init(model: String = "qwen2.5:7b") {
        self.model = model
    }

    private static let basePrompt = """
        You are a minimal transcript cleaner. Your SINGLE task is to remove spoken filler words (şey, yani, ee, ıı, hani, um, uh, falan, filan, vs.) and fix capitalization/punctuation.

        ABSOLUTE STRICT RULES:
        1. DO NOT REPHRASE: Keep every non-filler word in its exact original order and wording.
        2. DO NOT REWRITE: Do not improve grammar, do not shorten sentences, do not replace synonyms.
        3. DO NOT TRANSLATE: Keep Turkish in Turkish and English in English.
        4. REMOVE ONLY FILLER WORDS: Delete only speech hesitation words like "şey", "yani", "ee", "ıı", "hani".
        5. Do not use an example, template, or sentence from these instructions as the output.
        6. If there are no filler words, return the transcript's exact words unchanged.
        7. Output ONLY the cleaned transcript, nothing else.
        """

    private static let fillerWords: Set<String> = [
        "şey", "yani", "ee", "ıı", "hani", "um", "uh", "falan", "filan", "vs"
    ]

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

    /// Cleanup prompt, extended with known technical terms from the user's glossary (if
    /// present). Re-read from disk on every call (rather than cached) so an edit to
    /// glossary.txt takes effect on the very next dictation, with no app restart needed.
    /// Falls back to the base prompt when the glossary is missing/empty.
    private static func cleanupPrompt() -> String {
        guard let terms = loadGlossaryTerms() else {
            return basePrompt
        }
        let joined = terms.joined(separator: ", ")
        return basePrompt + """


            KNOWN TECHNICAL TERMS: \(joined)
            If a technical term is misspelled due to speech-to-text, fix only that term's spelling. Do not change any other words.
            """
    }

    private static func normalizedWords(from text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// The cleanup model may remove fillers and change punctuation/capitalization, but it must
    /// not replace the user's sentence with an unrelated sentence copied from the prompt. A
    /// glossary term may replace one source token because technical-term spelling correction is
    /// an intentional part of the cleanup contract.
    private static func isFaithfulCleanup(original: String, cleaned: String) -> Bool {
        let originalWords = normalizedWords(from: original)
        let cleanedWords = normalizedWords(from: cleaned)
        guard !originalWords.isEmpty, !cleanedWords.isEmpty else { return false }

        let glossaryWords = Set(
            (loadGlossaryTerms() ?? []).flatMap { normalizedWords(from: $0) }
        )

        var originalIndex = 0
        for cleanedWord in cleanedWords {
            while originalIndex < originalWords.count,
                  fillerWords.contains(originalWords[originalIndex]) {
                originalIndex += 1
            }

            guard originalIndex < originalWords.count else { return false }
            if originalWords[originalIndex] == cleanedWord {
                originalIndex += 1
            } else if glossaryWords.contains(cleanedWord) {
                // Permit one glossary-backed spelling correction for this source token.
                originalIndex += 1
            } else {
                return false
            }
        }

        while originalIndex < originalWords.count {
            guard fillerWords.contains(originalWords[originalIndex]) else { return false }
            originalIndex += 1
        }
        return true
    }

    /// Check if Ollama is running and responsive
    static func checkAvailability() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Clean up transcribed text using local Ollama LLM
    func cleanup(text: String) async -> String {
        guard let url = URL(string: "\(baseURL)/api/generate") else { return text }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": model,
            "prompt": "\(Self.cleanupPrompt())\n\nBEGIN TRANSCRIPT\n\(text)\nEND TRANSCRIPT\n\nCLEANED TRANSCRIPT:",
            "stream": false,
            "options": [
                "temperature": 0.0,
                "num_predict": min(max(50, text.count + 30), 200),
                "stop": ["\n", "\n\n", "</think>", "Transcript:"]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return text }

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let responseText = json["response"] as? String {
                let cleaned = responseText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

                // Sanity check: filter out Chinese characters or empty/huge outputs
                let hasChinese = cleaned.unicodeScalars.contains { scalar in
                    (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
                }

                if !hasChinese && !cleaned.isEmpty && cleaned.count < text.count * 3 {
                    guard Self.isFaithfulCleanup(original: text, cleaned: cleaned) else {
                        owLog("[LLMCleanup] Rejected unrelated cleanup output; using raw transcript")
                        return text
                    }
                    return cleaned
                } else if hasChinese {
                    // Log internally if needed: print("[LLMCleanup] Detected Chinese hallucination")
                }
            }
        } catch {
            // Silently fall back to raw text
        }

        return text
    }
}
