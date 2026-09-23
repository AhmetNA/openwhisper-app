import Foundation

final class LLMCleanup: Sendable {
    static let byT5ModelID = "byt5-small-tr-normalizer"
    private let baseURL = "http://localhost:11434"
    let model: String

    var usesByT5: Bool { model == Self.byT5ModelID }

    init(model: String = "llama3.2:3b") {
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

    /// Path to the learned-corrections store maintained by CorrectionStore.
    private static var correctionsURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenWhisper/corrections.json")
    }

    /// Minimal view of a CorrectionStore record. Uses a hand-written `init(from:)` with
    /// `decodeIfPresent` (rather than the synthesized Decodable init) so that a record missing
    /// one of these fields, or carrying fields this type doesn't know about (e.g. a future
    /// `appliedCount`/`lastApplied`), still decodes instead of throwing and losing the whole array.
    private struct LearnedCorrection: Decodable {
        let wrong: String
        let right: String
        let count: Int
        let status: String

        private enum CodingKeys: String, CodingKey {
            case wrong, right, count, status
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            wrong = try container.decodeIfPresent(String.self, forKey: .wrong) ?? ""
            right = try container.decodeIfPresent(String.self, forKey: .right) ?? ""
            count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        }
    }

    /// Reads the learned-corrections file and filters it down to entries confident enough to
    /// hand to the cleanup model: active, seen at least twice (not a one-off misfire), and
    /// capped to the most-confirmed 30 so the prompt (glossary.txt is already ~478 lines) doesn't
    /// grow large enough to make qwen2.5:7b miss instructions. Re-read from disk on every call
    /// (not cached) so a newly learned correction takes effect on the very next dictation.
    /// Tolerates a missing/corrupt file or file-level decode failure by returning empty.
    ///
    /// A multi-word `right` side (e.g. "kommitet -> commit et") is excluded: `isAllowedSubstitution`
    /// only pairs on the first word of `right`, and the span/merge check in `isFaithfulCleanup`
    /// is built to collapse several source words into one cleaned word, not to expand one source
    /// word into several cleaned words. Prompting such a correction would make the model comply
    /// and then have the entire cleanup rejected by the faithfulness check — the exact failure
    /// this feature exists to avoid — so it's dropped before it ever reaches the prompt. A
    /// multi-word `wrong` side (e.g. "çetçi biti -> chatgpt") is fine and kept.
    private static func loadLearnedCorrections() -> [LearnedCorrection] {
        guard let data = try? Data(contentsOf: correctionsURL) else { return [] }
        guard let all = try? JSONDecoder().decode([LearnedCorrection].self, from: data) else { return [] }
        return all
            .filter {
                $0.status == "active" && $0.count >= 2
                    && !$0.wrong.isEmpty && !$0.right.isEmpty
                    && normalizedWords(from: $0.right).count == 1
            }
            .sorted { $0.count > $1.count }
            .prefix(30)
            .map { $0 }
    }

    /// Cleanup prompt, extended with known technical terms from the user's glossary and with
    /// mishearings CorrectionStore has learned from this user's own edits (if either is
    /// present). Callers load both from disk once per `cleanup(text:)` call and pass them in
    /// here, rather than this function re-reading them itself, so a single cleanup pass only
    /// touches each file once even though the results are also needed by `isFaithfulCleanup`.
    /// Falls back to the base prompt when both are missing/empty.
    private static func cleanupPrompt(glossaryTerms: [String]?, corrections: [LearnedCorrection]) -> String {
        var prompt = basePrompt

        if let terms = glossaryTerms, !terms.isEmpty {
            let joined = terms.joined(separator: ", ")
            prompt += """


                KNOWN TECHNICAL TERMS: \(joined)
                If a technical term is misspelled due to speech-to-text, fix only that term's spelling. Do not change any other words.
                """
        }

        if !corrections.isEmpty {
            let joined = corrections.map { "\($0.wrong) -> \($0.right)" }.joined(separator: ", ")
            prompt += """


                KNOWN MISHEARINGS (speech-to-text errors this user has corrected before — fix these and their Turkish suffixed forms, e.g. if "komit -> commit" is listed, also fix "komitindeki" to "commitindeki"): \(joined)
                Apply a substitution only where that mishearing, or a Turkish-suffixed form of it, actually appears. Do not use this list to rephrase or rewrite anything else.
                """
        }

        return prompt
    }

    private static func normalizedWords(from text: String) -> [String] {
        text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// STT frequently splits a compound technical name across several words (e.g. "Cloudflare"
    /// heard as "Claude Flare", "TypeScript" as "Type Script"). A glossary correction is allowed
    /// to collapse up to this many source words into the single glossary term.
    private static let maxGlossaryMergeSpan = 4

    /// A `wrong`-side word shorter than this is too easy to prefix-match by coincidence (e.g. the
    /// real corrections store has "çe çe biti -> chatgpt", whose first word normalizes to just
    /// "çe" — without a floor, any source word starting with "çe" such as "çekiyorum" or "çeviri"
    /// would authorize a cleaned word starting with "chatgpt"). Chosen well below the shortest
    /// intentional correction in practice (5+ letters, e.g. "komit", "pısla").
    private static let minCorrectionPrefixLength = 4

    /// Whether `cleanedWord` is allowed to stand in for `sourceWord` at this position: either
    /// it's an exact known glossary term (unchanged pre-existing behavior — the model may use
    /// a glossary word regardless of what the mismatched source word looked like), or the pair
    /// matches a learned mishearing correction by PREFIX on both sides. The prefix pairing (not
    /// a bare `corrections` word set) is what lets a Turkish-suffixed form the model has never
    /// seen before — e.g. source "komitindeki" / cleaned "commitindeki" from a learned
    /// "komit -> commit" — pass, while still refusing to authorize "commitindeki" as a stand-in
    /// for an unrelated source word like "bugün". Only the first word of `wrong`/`right` is used;
    /// `loadLearnedCorrections` already excludes multi-word `right` sides, so this only ever
    /// discards nothing there, but stays defensive against a same-process caller passing raw data.
    private static func isAllowedSubstitution(
        cleanedWord: String,
        sourceWord: String,
        glossaryWords: Set<String>,
        corrections: [LearnedCorrection]
    ) -> Bool {
        if glossaryWords.contains(cleanedWord) { return true }
        return corrections.contains { correction in
            let wrong = normalizedWords(from: correction.wrong).first ?? ""
            let right = normalizedWords(from: correction.right).first ?? ""
            guard wrong.count >= minCorrectionPrefixLength, !right.isEmpty else { return false }
            return sourceWord.hasPrefix(wrong) && cleanedWord.hasPrefix(right)
        }
    }

    /// The cleanup model may remove fillers and change punctuation/capitalization, but it must
    /// not replace the user's sentence with an unrelated sentence copied from the prompt. A
    /// glossary term may replace a short run of source tokens because technical-term spelling
    /// correction is an intentional part of the cleanup contract — and a learned mishearing
    /// correction (`isAllowedSubstitution`) is authorized for the same reason.
    /// `glossaryTerms`/`corrections` must be the same values passed to `cleanupPrompt`, so what's
    /// allowed to appear "out of nowhere" here matches what was actually offered to the model.
    private static func isFaithfulCleanup(
        original: String,
        cleaned: String,
        glossaryTerms: [String]?,
        corrections: [LearnedCorrection]
    ) -> Bool {
        let originalWords = normalizedWords(from: original)
        let cleanedWords = normalizedWords(from: cleaned)
        guard !originalWords.isEmpty, !cleanedWords.isEmpty else { return false }

        let glossaryWords = Set((glossaryTerms ?? []).flatMap { normalizedWords(from: $0) })

        var originalIndex = 0
        for (cleanedIndex, cleanedWord) in cleanedWords.enumerated() {
            while originalIndex < originalWords.count,
                  fillerWords.contains(originalWords[originalIndex]) {
                originalIndex += 1
            }

            guard originalIndex < originalWords.count else { return false }
            if originalWords[originalIndex] == cleanedWord {
                originalIndex += 1
            } else if isAllowedSubstitution(
                cleanedWord: cleanedWord,
                sourceWord: originalWords[originalIndex],
                glossaryWords: glossaryWords,
                corrections: corrections
            ) {
                // Find the smallest run of source words this glossary term can stand in for.
                // With a following cleaned word, resync against it; at the end of the
                // transcript, consume whatever source words remain (bounded by the span cap).
                let nextCleanedWord = cleanedIndex + 1 < cleanedWords.count ? cleanedWords[cleanedIndex + 1] : nil
                var span = 1
                if let nextCleanedWord {
                    while span <= maxGlossaryMergeSpan,
                          originalIndex + span < originalWords.count,
                          originalWords[originalIndex + span] != nextCleanedWord {
                        span += 1
                    }
                    guard span <= maxGlossaryMergeSpan,
                          originalIndex + span < originalWords.count,
                          originalWords[originalIndex + span] == nextCleanedWord
                    else { return false }
                } else {
                    span = originalWords.count - originalIndex
                    guard span <= maxGlossaryMergeSpan else { return false }
                }
                originalIndex += span
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
    static func checkAvailability(model: String? = nil) async -> Bool {
        if model == byT5ModelID {
            return await ByT5Normalizer.checkAvailability()
        }
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
        if usesByT5 {
            return await cleanupWithByT5(text: text)
        }

        guard let url = URL(string: "\(baseURL)/api/generate") else { return text }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        // Read glossary + learned corrections once per cleanup call (fresh from disk each
        // time, not cached across calls) and thread them through to both the prompt builder
        // and the faithfulness check below, instead of each re-reading the files itself.
        let glossaryTerms = GlossaryStore.terms()
        let corrections = Self.loadLearnedCorrections()

        let body: [String: Any] = [
            "model": model,
            "prompt": "\(Self.cleanupPrompt(glossaryTerms: glossaryTerms, corrections: corrections))\n\nBEGIN TRANSCRIPT\n\(text)\nEND TRANSCRIPT\n\nCLEANED TRANSCRIPT:",
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
                    guard Self.isFaithfulCleanup(
                        original: text,
                        cleaned: cleaned,
                        glossaryTerms: glossaryTerms,
                        corrections: corrections
                    ) else {
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

    // MARK: - ByT5-specific cleanup

    /// ByT5 is allowed to normalize Turkish word forms, unlike the deliberately strict Ollama
    /// contract above. It therefore has its own input preparation and safety checks; changing
    /// these rules cannot loosen the existing Ollama path.
    private func cleanupWithByT5(text: String) async -> String {
        let prepared = Self.removingStandaloneFillers(from: text)
        guard !prepared.isEmpty else { return text }

        do {
            let generated = try await ByT5Normalizer.shared.normalize(prepared)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let restored = Self.restoringProtectedTerms(
                in: generated,
                from: prepared,
                glossaryTerms: GlossaryStore.terms()
            )
            guard Self.isSafeByT5Normalization(
                original: prepared,
                normalized: restored,
                glossaryTerms: GlossaryStore.terms()
            ) else {
                owLog("[ByT5] Unsafe normalization rejected; using pre-normalization transcript")
                return prepared
            }
            return restored
        } catch {
            owLog("[ByT5] Normalization failed: \(error.localizedDescription)")
            return text
        }
    }

    static func removingStandaloneFillers(from text: String) -> String {
        let pattern = #"(?iu)(?<![\p{L}\p{N}_])(şey|yani|ee+|ıı+|hani|um+|uh+|falan|filan|vs)(?![\p{L}\p{N}_])[,;:\s]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var result = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func protectedTerms(in text: String, glossaryTerms: [String]?) -> [String] {
        var terms: [String] = []
        let patterns = [
            #"https?://[^\s]+"#,
            #"[\p{L}\p{N}._%+\-]+@[\p{L}\p{N}.\-]+\.[A-Za-z]{2,}"#,
            #"\b\d+(?:[.,:/\-]\d+)*\b"#,
            #"\b[\p{L}\p{N}]*[_/#@`][\p{L}\p{N}_/#@`.\-]*\b"#,
            #"\b[a-zçğıöşü]+[A-ZÇĞİÖŞÜ][\p{L}\p{N}]*\b"#,
            #"\b[A-ZÇĞİÖŞÜ]{2,}[\p{L}\p{N}]*\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                if let swiftRange = Range(match.range, in: text) {
                    terms.append(String(text[swiftRange]))
                }
            }
        }
        for term in glossaryTerms ?? [] where !term.isEmpty {
            if text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                terms.append(term)
            }
        }
        return Array(Set(terms)).sorted { $0.count > $1.count }
    }

    static func restoringProtectedTerms(
        in normalized: String,
        from original: String,
        glossaryTerms: [String]?
    ) -> String {
        var result = normalized
        for term in protectedTerms(in: original, glossaryTerms: glossaryTerms) {
            if let range = result.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                result.replaceSubrange(range, with: term)
            }
        }
        return result
    }

    static func isSafeByT5Normalization(
        original: String,
        normalized: String,
        glossaryTerms: [String]?
    ) -> Bool {
        guard !normalized.isEmpty else { return false }
        let originalCount = max(1, original.count)
        let lengthRatio = Double(normalized.count) / Double(originalCount)
        guard (0.55...1.80).contains(lengthRatio) else { return false }

        // URLs, numbers, code-shaped tokens, acronyms and glossary terms must survive. The
        // casing restoration happens first, so this exact check also protects their spelling.
        for term in protectedTerms(in: original, glossaryTerms: glossaryTerms) {
            guard normalized.contains(term) else { return false }
        }

        // Turkish normalization may legitimately make sizeable edits to one short word
        // ("alcam" -> "alacağım"), but a majority rewrite is not acceptable for dictation.
        let distance = levenshtein(Array(original.lowercased()), Array(normalized.lowercased()))
        let editRatio = Double(distance) / Double(max(original.count, normalized.count, 1))
        guard editRatio <= 0.55 else { return false }

        // Reject scripts outside Latin/Latin-extended while allowing punctuation, emoji and
        // combining marks already present in normal Turkish text.
        for scalar in normalized.unicodeScalars where CharacterSet.letters.contains(scalar) {
            let value = scalar.value
            let isLatin = (0x0041...0x007A).contains(value)
                || (0x00C0...0x024F).contains(value)
                || (0x1E00...0x1EFF).contains(value)
            if !isLatin { return false }
        }
        return true
    }

    private static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: rhs.count)
            for (rightIndex, right) in rhs.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
