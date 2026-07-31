import Foundation

final class LLMCleanup: Sendable {
    private let baseURL = "http://localhost:11434"
    private let model = "qwen2.5:7b"

    private static let basePrompt = """
        You are an expert AI prompt engineer and transcript polisher for a Turkish software developer. Your task is to polish spoken transcripts into clear, professional, AI-prompt-ready text.

        STRICT RULES:
        1. NO TRANSLATION: Keep Turkish in Turkish, English in English. Preserve code-switching exactly.
        2. FILLER REMOVAL: Remove all filler words (şey, yani, ee, ıı, hani, um, uh, falan, filan, vs.).
        3. AI PROMPT TONE: Format the text with clear, direct, well-punctuated, and precise phrasing as if it is written as a prompt/instruction for an AI model.
        4. AUTOMATIC BULLET POINTS: 
           - If the speaker dictates multiple items, sequential steps, or enumerated points (e.g., "birincisi...", "ikincisi...", "ilk olarak...", "sonrasında...", "1...", "2..."), automatically format them into a clean Markdown bullet list (`- Item 1\n- Item 2`).
           - IMPORTANT: If the content is a normal paragraph, continuous text, or single thought, keep it as a clean paragraph. Do NOT force bullet points on normal prose.
        5. TECHNICAL ACCURACY: Keep technical terms and variable names intact.
        6. OUTPUT ONLY: Return only the polished final text with no introductory or meta comments.

        Example 1 (Paragraph):
        Input: "şey bu fonksiyonu yani async yapalım ee sonra await ekleyelim"
        Output: "Bu fonksiyonu async yapalım, sonra await ekleyelim."

        Example 2 (Automatic Bullet List):
        Input: "ilk olarak database bağlantısını kuralım ikincisi auth middleware ekleyelim üçüncüsü testleri çalıştıralım"
        Output:
        - Database bağlantısını kurun
        - Auth middleware ekleyin
        - Testleri çalıştırın
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

                // Sanity check: don't return empty or much longer than input
                if !cleaned.isEmpty && cleaned.count < text.count * 3 {
                    return cleaned
                }
            }
        } catch {
            // Silently fall back to raw text
        }

        return text
    }
}
