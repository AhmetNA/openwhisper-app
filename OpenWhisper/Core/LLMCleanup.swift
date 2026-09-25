import Foundation

final class LLMCleanup: Sendable {
    private let baseURL = "http://localhost:11434"
    let model: String

    /// Default cleanup model. Chosen after a side-by-side run on TR/EN code-switched dictation
    /// with the glossary in the prompt: llama3.2:3b translated English phrases and swapped words
    /// in half the samples (so the faithfulness check threw its output away), qwen3.5:4b was
    /// accurate but ~1s per sentence, gemma4:e2b-it-qat kept every sample intact at ~0.3s.
    static let defaultModel = "gemma4:e2b-it-qat"

    init(model: String = LLMCleanup.defaultModel) {
        self.model = model
    }

    /// Cleanup models offered in Settings, fastest first. Each must be `ollama pull`-ed
    /// separately; `isModelInstalled` guards against picking one that isn't.
    static let supportedModels: [(tag: String, label: String)] = [
        ("gemma4:e2b-it-qat", "⚡ Hızlı (Gemma 4 E2B)"),
        ("qwen3.5:4b", "🧠 Dikkatli (Qwen 3.5 4B)")
    ]

    /// How long Ollama keeps the model resident after a request. Every request to the model
    /// (cleanup, Spotify, reminders) must send this: Ollama resets the timer to whatever the
    /// latest request asked for, so one request without it would drop back to the 5 min default
    /// and the next push-to-talk would pay the cold load again.
    static let keepAlive = "30m"

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
    private static func cleanupPrompt(
        glossaryTerms: [String]?,
        corrections: [LearnedCorrection],
        misheard: [MisheardWordDetector.Word] = []
    ) -> String {
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

        if !misheard.isEmpty {
            // No spell checker guesses: they point the wrong way too often ("fülle" → "gülle").
            let listed = misheard.map { "\"\($0.text)\"" }.joined(separator: "; ")
            prompt += """


                MISHEARD WORDS: speech-to-text produced these words, which are neither Turkish nor English: \(listed)
                Replace each with the word the speaker most likely said, judged by how it sounds and by the sentence. Prefer a Turkish word; use English only if no Turkish word fits. It may be two words run together (e.g. "Sesifullah" -> "Sesi fulle"). If it is a name of a person, artist, song or brand, keep it as it is. Change no other word.
                """
        }

        return prompt
    }

    /// Lowercased, diacritics removed, dotless ı folded to i: how close two spellings sound.
    private static func folded(_ word: String) -> String {
        word.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// A misheard word may become up to this many words ("sesifullah" -> "sesi fulle").
    private static let maxMisheardSplit = 3

    /// How many cleaned words, starting at `cleanedIndex`, stand in for the misheard source
    /// word `source`, or nil if none do. The replacement must sound like the source (small
    /// edit distance once diacritics are folded) and be made of real words, unless it is only
    /// the source split apart ("hadisedüm" -> "hadise düm"). The walk must resync right after
    /// it on `remainingSource`, the source words that follow (fillers may have been dropped).
    static func misheardReplacementLength(
        source: String,
        cleanedWords: [String],
        cleanedIndex: Int,
        remainingSource: ArraySlice<String>,
        isKnownWord: (String) -> Bool
    ) -> Int? {
        let foldedSource = folded(source)
        let tolerance = max(2, foldedSource.count / 4)
        func resyncs(at end: Int) -> Bool {
            guard end < cleanedWords.count else { return remainingSource.allSatisfy(fillerWords.contains) }
            for word in remainingSource {
                if word == cleanedWords[end] { return true }
                if !fillerWords.contains(word) { return false }
            }
            return false
        }
        for length in 1...maxMisheardSplit {
            let end = cleanedIndex + length
            guard end <= cleanedWords.count else { return nil }
            let replacement = Array(cleanedWords[cleanedIndex..<end])
            let joined = folded(replacement.joined())
            // Only cutting the end off ("frontendi" -> "frontend") strips a Turkish suffix.
            guard resyncs(at: end), editDistance(joined, foldedSource) <= tolerance,
                  !(foldedSource.hasPrefix(joined) && joined != foldedSource) else { continue }
            if joined == foldedSource || replacement.allSatisfy(isKnownWord) {
                return length
            }
        }
        return nil
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
    ///
    /// A word `MisheardWordDetector` flagged (`misheardWords`, normalized) may also be replaced,
    /// under the rules of `misheardReplacementLength`; `isKnownWord` checks the replacement.
    ///
    /// A filler the model kept is fine: fillers are skipped only when they don't match.
    private static func isFaithfulCleanup(
        original: String,
        cleaned: String,
        glossaryTerms: [String]?,
        corrections: [LearnedCorrection],
        misheardWords: Set<String> = [],
        isKnownWord: (String) -> Bool = { _ in false }
    ) -> Bool {
        let originalWords = normalizedWords(from: original)
        let cleanedWords = normalizedWords(from: cleaned)
        guard !originalWords.isEmpty, !cleanedWords.isEmpty else { return false }

        let glossaryWords = Set((glossaryTerms ?? []).flatMap { normalizedWords(from: $0) })

        var originalIndex = 0
        var cleanedIndex = 0
        while cleanedIndex < cleanedWords.count {
            let cleanedWord = cleanedWords[cleanedIndex]
            while originalIndex < originalWords.count,
                  originalWords[originalIndex] != cleanedWord,
                  fillerWords.contains(originalWords[originalIndex]) {
                originalIndex += 1
            }

            guard originalIndex < originalWords.count else {
                owLog("[LLMCleanup] Faithfulness: extra cleaned word '\(cleanedWord)'")
                return false
            }
            if originalWords[originalIndex] == cleanedWord {
                originalIndex += 1
                cleanedIndex += 1
                continue
            }
            if misheardWords.contains(originalWords[originalIndex]),
               let length = misheardReplacementLength(
                source: originalWords[originalIndex],
                cleanedWords: cleanedWords,
                cleanedIndex: cleanedIndex,
                remainingSource: originalWords[(originalIndex + 1)...],
                isKnownWord: isKnownWord
               ) {
                owLog("[LLMCleanup] Misheard word replaced: \(originalWords[originalIndex]) -> \(cleanedWords[cleanedIndex..<(cleanedIndex + length)].joined(separator: " "))")
                originalIndex += 1
                cleanedIndex += length
                continue
            }
            if isAllowedSubstitution(
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
                cleanedIndex += 1
            } else {
                owLog("[LLMCleanup] Faithfulness: '\(originalWords[originalIndex])' became '\(cleanedWord)'")
                return false
            }
        }

        while originalIndex < originalWords.count {
            guard fillerWords.contains(originalWords[originalIndex]) else {
                owLog("[LLMCleanup] Faithfulness: dropped '\(originalWords[originalIndex])'")
                return false
            }
            originalIndex += 1
        }
        return true
    }

    /// Same words in the same order, ignoring case and punctuation: a cleanup that only
    /// changed those didn't correct anything.
    static func sameWords(_ a: String, _ b: String) -> Bool {
        normalizedWords(from: a) == normalizedWords(from: b)
    }

    /// `isFaithfulCleanup` without glossary or learned corrections, for tests.
    static func isFaithfulCleanup(
        original: String,
        cleaned: String,
        misheardWords: Set<String> = [],
        isKnownWord: (String) -> Bool = { _ in false }
    ) -> Bool {
        isFaithfulCleanup(
            original: original, cleaned: cleaned, glossaryTerms: nil, corrections: [],
            misheardWords: misheardWords, isKnownWord: isKnownWord
        )
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

    /// Whether `model` shows up in Ollama's installed-model list. A tag without an explicit
    /// `:variant` matches its `:latest` entry.
    static func isModelInstalled(_ model: String) async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return false }

        let wanted = model.contains(":") ? model : "\(model):latest"
        return models.contains { ($0["name"] as? String) == wanted }
    }

    /// Loads `model` into memory ahead of the first dictation (an empty prompt makes Ollama
    /// load the model without generating), so push-to-talk doesn't pay the cold load.
    static func warmUp(model: String) async {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = ["model": model, "prompt": "", "keep_alive": keepAlive]
        guard let requestData = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = requestData
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Clean up transcribed text using local Ollama LLM. `misheard` are the words
    /// `MisheardWordDetector` found in `text`; only these may be replaced by other words.
    func cleanup(text: String, misheard: [MisheardWordDetector.Word] = []) async -> String {
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
            "prompt": "\(Self.cleanupPrompt(glossaryTerms: glossaryTerms, corrections: corrections, misheard: misheard))\n\nBEGIN TRANSCRIPT\n\(text)\nEND TRANSCRIPT\n\nCLEANED TRANSCRIPT:",
            "stream": false,
            // Qwen 3.5 / Gemma 4 think by default: without this the answer arrives only after a
            // long hidden reasoning pass (or the num_predict budget runs out inside it).
            "think": false,
            "keep_alive": Self.keepAlive,
            "options": [
                "temperature": 0.0,
                // Turkish runs to ~1 token per 2-3 characters; a lower cap cut long dictations
                // short and the faithfulness check then rejected the whole cleanup.
                "num_predict": min(max(50, text.count + 30), 800),
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
                    let misheardWords = Set(misheard.flatMap { Self.normalizedWords(from: $0.text) })
                    let knownCleanedWords: Set<String> = misheard.isEmpty ? [] : await MainActor.run {
                        Set(Self.normalizedWords(from: cleaned).filter(MisheardWordDetector.isKnown))
                    }
                    guard Self.isFaithfulCleanup(
                        original: text,
                        cleaned: cleaned,
                        glossaryTerms: glossaryTerms,
                        corrections: corrections,
                        misheardWords: misheardWords,
                        isKnownWord: knownCleanedWords.contains
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
}
