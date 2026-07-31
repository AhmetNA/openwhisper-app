import Foundation

final class LLMCleanup: Sendable {
    private let baseURL = "http://localhost:11434"
    private let model = "qwen2.5:7b"

    private static let basePrompt = """
        You are a transcript cleaner. The transcript is spoken by a Turkish software developer who mixes Turkish and English (code-switching). Your ONLY job: remove filler words (şey, yani, ee, ıı, hani, um, uh, falan, filan) and fix punctuation/casing.

        STRICT RULES:
        - NEVER translate any word. Turkish stays Turkish, English stays English.
        - NEVER rephrase, reorder, or substitute words. Keep every non-filler word exactly as spoken.
        - NEVER output Chinese characters, markdown lists, bullet points, or extra explanations.
        - Technical terms must appear EXACTLY as in the transcript.
        - Output ONLY the cleaned text.

        Example input: şey bu fonksiyonu yani async yapalım ee sonra await ekleyelim
        Example output: Bu fonksiyonu async yapalım, sonra await ekleyelim.
        """

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


            KNOWN TECHNICAL TERMS the speaker commonly uses: \(joined)

            If a word or short phrase in the transcript is not a real Turkish or English word and appears to be a speech-to-text mishearing of one of the known terms above (judge by sound-alike syllables AND surrounding technical context, not spelling), replace it with the exact known term. Only correct when the phonetic similarity is clearly obvious; never guess otherwise, and never touch words that are already valid Turkish or English words.
            """
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
            "prompt": "\(Self.cleanupPrompt())\n\nTranscript: \(text)",
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": max(200, text.count * 2)
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
