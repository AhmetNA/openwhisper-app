import Foundation

/// Pure logic for the "learning correction" feature: word-level diffing between what
/// OpenWhisper pasted and what the user's edit left behind, filtering that diff down to
/// trustworthy correction candidates, Turkish-aware root/suffix handling, and applying
/// learned corrections to future transcripts.
///
/// Deliberately has ZERO dependency on AppKit/ApplicationServices/owLog so it can be compiled
/// and unit-tested standalone with `swiftc` (see Tools/CorrectionEngineHarness.swift) — all
/// AX/clipboard/logging concerns live in DictationSnapshot.swift and AppState.swift instead.
enum CorrectionEngine {

    // MARK: - Checkpoint Interval Settings

    static let defaultCheckpointsString = "1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30"
    static let defaultCheckpoints: [TimeInterval] = Array(1...30).map { TimeInterval($0) }

    /// Validate and parse a user-supplied comma-separated seconds string for checkpoint intervals.
    /// Returns sorted TimeInterval array if valid (1-60 items, each 1..300 integer seconds), or nil if invalid.
    static func parseCheckpoints(_ input: String) -> [TimeInterval]? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return nil }
        let parts = trimmedInput.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !parts.isEmpty, parts.count <= 60 else { return nil }
        var intervals: [TimeInterval] = []
        for part in parts {
            guard let val = Int(part), val >= 1, val <= 300 else { return nil }
            intervals.append(TimeInterval(val))
        }
        let uniqueSorted = Array(Set(intervals)).sorted()
        guard !uniqueSorted.isEmpty else { return nil }
        return uniqueSorted
    }

    // MARK: - Turkish-safe casing

    static let trLocale = Locale(identifier: "tr_TR")

    /// Turkish-correct lowercase — critical because Swift's plain `.lowercased()` maps
    /// "I" → "i" (ASCII rule), not "ı" (Turkish dotless i), which would silently corrupt
    /// every comparison/storage key built from a capitalized Turkish word.
    static func trLower(_ s: String) -> String {
        (s as NSString).lowercased(with: trLocale)
    }

    /// Turkish-correct uppercase — "i" → "İ" (dotted capital I), not "I".
    static func trUpper(_ s: String) -> String {
        (s as NSString).uppercased(with: trLocale)
    }

    // MARK: - Tokenization

    struct Token: Equatable {
        let text: String
        let isWord: Bool
    }

    /// A character counts as "word-internal" if it's a letter, digit, or apostrophe.
    /// Apostrophes are kept word-internal (not a separate token) so Turkish suffixed forms
    /// like "flagment'ı" tokenize as ONE token — splitting on the apostrophe would make the
    /// agglutination root-extraction logic below vacuous.
    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "\u{2019}" // ’ (curly apostrophe)
    }

    /// Tokenize preserving every character (words + separators/punctuation), so joining the
    /// tokens back together reproduces the original string exactly.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentIsWord: Bool?
        for ch in text {
            let chIsWord = isWordChar(ch)
            if let flag = currentIsWord, flag == chIsWord {
                current.append(ch)
            } else {
                if !current.isEmpty, let flag = currentIsWord {
                    tokens.append(Token(text: current, isWord: flag))
                }
                current = String(ch)
                currentIsWord = chIsWord
            }
        }
        if !current.isEmpty, let flag = currentIsWord {
            tokens.append(Token(text: current, isWord: flag))
        }
        return tokens
    }

    /// Just the word tokens, in order, as their original-cased strings.
    static func words(_ text: String) -> [String] {
        tokenize(text).filter(\.isWord).map(\.text)
    }

    // MARK: - Levenshtein similarity

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }
        var prev = Array(0...bChars.count)
        var curr = Array(repeating: 0, count: bChars.count + 1)
        for i in 1...aChars.count {
            curr[0] = i
            for j in 1...bChars.count {
                if aChars[i - 1] == bChars[j - 1] {
                    curr[j] = prev[j - 1]
                } else {
                    curr[j] = 1 + min(prev[j - 1], min(prev[j], curr[j - 1]))
                }
            }
            prev = curr
        }
        return prev[bChars.count]
    }

    /// 0 = completely different, 1 = identical. Case-insensitive (Turkish-aware).
    static func normalizedSimilarity(_ a: String, _ b: String) -> Double {
        let la = trLower(a), lb = trLower(b)
        let maxLen = max(la.count, lb.count)
        if maxLen == 0 { return 1.0 }
        if la == lb { return 1.0 }
        let dist = levenshtein(la, lb)
        return 1.0 - Double(dist) / Double(maxLen)
    }

    // MARK: - Word-level LCS diff

    /// Indices (into a/b) of the longest common subsequence, using Turkish-aware
    /// case-insensitive equality so "Merhaba"/"merhaba" count as a match (pure-case edits
    /// are filtered out as candidates elsewhere, not treated as a diff here).
    static func lcsMatches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        let al = a.map(trLower), bl = b.map(trLower)
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if al[i] == bl[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var i = 0, j = 0
        var matches: [(Int, Int)] = []
        while i < n && j < m {
            if al[i] == bl[j] {
                matches.append((i, j))
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matches
    }

    /// A candidate substitution surfaced by the diff: `wrong` (old phrase) replaced by
    /// `right` (new phrase), still in their ORIGINAL inflected form — filters and root
    /// extraction happen afterwards.
    struct RawSubstitution {
        let wrong: String
        let right: String
    }

    /// Walk the LCS alignment and collect true substitutions plus the supported compound-word
    /// merge shape (two old words becoming one new word). Insertions/deletions, split words,
    /// and longer rewrites are NOT candidates at all (discarded here, not later).
    static func substitutionCandidates(oldWords: [String], newWords: [String]) -> [RawSubstitution] {
        let matches = lcsMatches(oldWords, newWords)
        var candidates: [RawSubstitution] = []

        func handleGap(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) {
            let oldLen = oldEnd - oldStart
            let newLen = newEnd - newStart
            let isSameWordCount = oldLen == newLen && oldLen >= 1 && oldLen <= 3
            let isCompoundMerge = oldLen == 2 && newLen == 1
            guard isSameWordCount || isCompoundMerge else { return }
            let wrong = oldWords[oldStart..<oldEnd].joined(separator: " ")
            let right = newWords[newStart..<newEnd].joined(separator: " ")
            guard wrong != right else { return }
            candidates.append(RawSubstitution(wrong: wrong, right: right))
        }

        var prevOld = 0, prevNew = 0
        for (oi, ni) in matches {
            handleGap(oldStart: prevOld, oldEnd: oi, newStart: prevNew, newEnd: ni)
            prevOld = oi + 1
            prevNew = ni + 1
        }
        handleGap(oldStart: prevOld, oldEnd: oldWords.count, newStart: prevNew, newEnd: newWords.count)
        return candidates
    }

    // MARK: - Blacklist

    /// Common short words (TR/EN) that must never end up on the "wrong" side of a learned
    /// correction — without this, one careless edit (e.g. "bir" → "bin" while fixing an
    /// unrelated typo nearby) would silently corrupt every future transcript that contains
    /// the word "bir".
    static let blacklist: Set<String> = [
        // Turkish
        "bir", "bin", "ve", "de", "da", "ile", "için", "bu", "şu", "o", "ben", "sen", "biz",
        "siz", "onlar", "ne", "mi", "mı", "mu", "mü", "ki", "ya", "ama", "fakat", "çok", "az",
        "var", "yok", "gibi", "kadar", "ise", "her", "hiç", "daha", "en", "ki", "ise", "hem",
        "ben", "sana", "bana", "onu", "ona", "beni", "seni", "diye", "olan", "olarak",
        // English
        "the", "a", "an", "is", "to", "of", "in", "on", "at", "it", "and", "or", "but", "so",
        "for", "with", "as", "by", "be", "am", "are", "was", "were", "this", "that", "i", "you"
    ]

    static func containsBlacklistedWrongWord(_ phrase: String) -> Bool {
        phrase.split(separator: " ").contains { blacklist.contains(trLower(String($0))) }
    }

    // MARK: - Acceptance filters

    struct Candidate: Equatable {
        let wrong: String
        let right: String
    }

    /// Runs every acceptance filter from the spec. Returns nil if the candidate should be
    /// discarded (never learned); otherwise returns the (still full-inflected) accepted pair.
    static func accept(_ raw: RawSubstitution) -> Candidate? {
        let wrong = raw.wrong
        let right = raw.right

        let wrongWords = wrong.split(separator: " ").map(String.init)
        let rightWords = right.split(separator: " ").map(String.init)
        let isCompoundMerge = wrongWords.count == 2 && rightWords.count == 1

        // Case-only or punctuation-only difference — LLM cleanup already handles that.
        if trLower(wrong) == trLower(right) { return nil }
        let stripPunct: (String) -> String = { s in
            String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        // For a compound merge, whitespace is the actual semantic difference, so it must not
        // be mistaken for punctuation-only noise by the normalized comparison below.
        if !isCompoundMerge, trLower(stripPunct(wrong)) == trLower(stripPunct(right)) { return nil }

        // Word-length floor: any individual word under 2 chars kills the whole candidate.
        guard wrongWords.allSatisfy({ $0.count >= 2 }), rightWords.allSatisfy({ $0.count >= 2 }) else {
            return nil
        }

        // Blacklist: common short words may never sit on the "wrong" side.
        // A compound phrase is not a standalone occurrence of any one word, so allow common
        // components such as "her şey" or "bir çok" to be learned as a single compound.
        if !isCompoundMerge {
            guard !wrongWords.contains(where: { blacklist.contains(trLower($0)) }) else { return nil }
        }

        // 1-3 word phrase cap for ordinary substitutions; compound merges are exactly 2 -> 1.
        guard (wrongWords.count >= 1 && wrongWords.count <= 3) || isCompoundMerge else { return nil }

        // Similarity floor: normalized Levenshtein distance <= 0.4 (similarity >= 0.6).
        // A full rewrite of the phrase (different wording, not a mishearing) fails this.
        guard normalizedSimilarity(wrong, right) >= 0.6 else { return nil }

        return Candidate(wrong: wrong, right: right)
    }

    // MARK: - Turkish agglutination: root extraction

    /// Strip the shared inflectional suffix off an accepted (wrong, right) pair so what gets
    /// stored/applied is the ROOT, not one specific inflected form — e.g. "flagment'ı" /
    /// "fragment'ı" → ("flagment", "fragment"), so the learned correction also fires for
    /// "flagment'a", "flagment'ta", etc.
    ///
    /// Two strategies:
    /// 1. Apostrophe boundary (used for proper-noun-style suffixed forms): if both words
    ///    contain an apostrophe and the suffix AFTER the apostrophe is identical, split there.
    /// 2. No apostrophe: fall back to a capped (<=3 char) common-suffix strip, only applied
    ///    if both resulting stems stay at least 3 characters long and still differ — this
    ///    keeps normal (non-agglutinating) word pairs like "kod"/"kot" untouched.
    static func extractRoot(wrong: String, right: String) -> (wrong: String, right: String) {
        // Root extraction is defined for one-word inflected forms. A compound merge must keep
        // its complete phrase (e.g. "her şey" -> "herşey") so the learned pair can be applied
        // as a multi-token replacement later.
        if words(wrong).count != 1 || words(right).count != 1 {
            return (wrong, right)
        }

        if let wApos = lastApostropheIndex(wrong), let rApos = lastApostropheIndex(right) {
            let wSuffix = wrong[wApos...]
            let rSuffix = right[rApos...]
            if wSuffix == rSuffix {
                let wStem = String(wrong[wrong.startIndex..<wApos])
                let rStem = String(right[right.startIndex..<rApos])
                if !wStem.isEmpty, !rStem.isEmpty, wStem != rStem {
                    return (wStem, rStem)
                }
            }
            return (wrong, right)
        }

        let n = commonSuffixLength(wrong, right, cap: 3)
        if n > 0 {
            let wStem = String(wrong.dropLast(n))
            let rStem = String(right.dropLast(n))
            if wStem.count >= 3, rStem.count >= 3, wStem != rStem {
                return (wStem, rStem)
            }
        }
        return (wrong, right)
    }

    private static func lastApostropheIndex(_ s: String) -> String.Index? {
        s.lastIndex(where: { $0 == "'" || $0 == "\u{2019}" })
    }

    private static func commonSuffixLength(_ a: String, _ b: String, cap: Int) -> Int {
        let aChars = Array(a), bChars = Array(b)
        var n = 0
        let maxPossible = min(aChars.count, bChars.count, cap)
        while n < maxPossible, aChars[aChars.count - 1 - n] == bChars[bChars.count - 1 - n] {
            n += 1
        }
        return n
    }

    // MARK: - Applying learned corrections

    struct LearnedPair {
        let wrong: String   // root, stored lowercase (tr)
        let right: String   // root, stored with its "canonical" casing as first learned
    }

    /// Reproduce the case pattern of `original` onto `replacement`:
    /// - ALL CAPS original → all-caps replacement
    /// - Capitalized (first letter upper, rest whatever) → capitalize replacement's first letter
    /// - otherwise → replacement used as-is (its stored/learned casing)
    private static func matchCase(of original: String, applyTo replacement: String) -> String {
        guard let firstOriginal = original.first, let firstReplacement = replacement.first else {
            return replacement
        }
        if original == trUpper(original), original.count > 1 {
            return trUpper(replacement)
        }
        if firstOriginal.isUppercase {
            return String(firstReplacement).uppercased() + replacement.dropFirst()
        }
        return replacement
    }

    /// Apply every ACTIVE learned correction to `text`, matching whole words/roots or learned
    /// compound phrases (Turkish locale-aware, apostrophe-suffix preserved), and preserving
    /// the original occurrence's case pattern. Longest phrases/roots are matched first so e.g.
    /// "her şey" doesn't get shadowed by a shorter learned pair.
    /// Returns the corrected text plus the list of (wrong, right) pairs that actually fired.
    static func applyCorrections(to text: String, pairs: [LearnedPair]) -> (result: String, applied: [(String, String)]) {
        guard !pairs.isEmpty else { return (text, []) }
        let sortedPairs = pairs.sorted {
            let leftWordCount = words($0.wrong).count
            let rightWordCount = words($1.wrong).count
            if leftWordCount != rightWordCount { return leftWordCount > rightWordCount }
            return $0.wrong.count > $1.wrong.count
        }
        var tokens = tokenize(text)
        var applied: [(String, String)] = []

        var i = 0
        while i < tokens.count {
            guard tokens[i].isWord else {
                i += 1
                continue
            }

            var didApply = false
            for pair in sortedPairs {
                let patternWords = words(pair.wrong)
                guard !patternWords.isEmpty else { continue }

                if patternWords.count > 1 {
                    guard let end = phraseMatchEnd(
                        in: tokens,
                        start: i,
                        patternWords: patternWords
                    ) else { continue }

                    let firstOriginal = tokens[i].text
                    let replacement = matchCase(of: firstOriginal, applyTo: pair.right)
                    tokens.replaceSubrange(i..<end, with: [Token(text: replacement, isWord: true)])
                    applied.append((pair.wrong, pair.right))
                    didApply = true
                    break
                }

                let token = tokens[i].text
                let (stem, suffix): (String, String)
                if let aposIdx = lastApostropheIndex(token) {
                    stem = String(token[token.startIndex..<aposIdx])
                    suffix = String(token[aposIdx...])
                } else {
                    stem = token
                    suffix = ""
                }
                let lowerStem = trLower(stem)
                guard pair.wrong == lowerStem else { continue }
                let replacedStem = matchCase(of: stem, applyTo: pair.right)
                tokens[i] = Token(text: replacedStem + suffix, isWord: true)
                applied.append((pair.wrong, pair.right))
                didApply = true
                break
            }

            // Move beyond a replacement so a learned result cannot be immediately reprocessed
            // by another pair during this pass.
            i += 1
            _ = didApply
        }

        let result = tokens.map(\.text).joined()
        return (result, applied)
    }

    /// Returns the exclusive token end for a learned multi-word phrase. Only whitespace may
    /// separate phrase words; punctuation prevents a match across sentence boundaries.
    private static func phraseMatchEnd(
        in tokens: [Token],
        start: Int,
        patternWords: [String]
    ) -> Int? {
        var cursor = start
        for (index, expected) in patternWords.enumerated() {
            guard cursor < tokens.count,
                  tokens[cursor].isWord,
                  trLower(tokens[cursor].text) == trLower(expected) else {
                return nil
            }
            cursor += 1
            guard index < patternWords.count - 1 else { continue }

            guard cursor < tokens.count, !tokens[cursor].isWord else { return nil }
            guard tokens[cursor].text.allSatisfy({ $0.isWhitespace }) else { return nil }
            cursor += 1
        }
        return cursor
    }
}
