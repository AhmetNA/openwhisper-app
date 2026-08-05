import Foundation

/// Deterministic pass that recognizes glossary terms transliterated into Turkish phonetic
/// spelling with an attached Turkish suffix (e.g. Whisper's "puşla" for "pushla", "gitaba"
/// for "GitHub'a") and restores the correct spelling while keeping the Turkish suffix.
///
/// Pure string matching, no model call — runs on the fast path in `initialText` alongside
/// `CorrectionEngine.applyCorrections`, independent of Ollama. Deliberately conservative:
/// unlike the learned-correction store, nothing here is user-confirmed, so a match is only
/// applied when it's exact (after phonetic normalization). A fuzzy fallback used to run here
/// too; it was measured and removed — see the comment on `disabledFuzzyMatch(for:in:)` below.
enum PhoneticGlossaryCorrector {

    /// Candidate Turkish suffixes to try stripping from a word's end, longest first so a
    /// longer real suffix isn't shadowed by a shorter one that happens to be a substring.
    /// Shared with `CorrectionEngine.applyCorrections`'s suffix-symmetric matching (see
    /// `CorrectionEngine.turkishSuffixes`) so both sides agree on what counts as a Turkish
    /// inflectional ending — this is a plain alias, behavior here is unchanged.
    private static let candidateSuffixes: [String] = CorrectionEngine.turkishSuffixes

    /// Turkish-orthography approximations of English sounds that have no direct Latin
    /// letter, mapped back toward English spelling. Applied only to the candidate word —
    /// glossary terms are already correctly spelled and left untouched.
    private static let phoneticMap: [(String, String)] = [
        ("ş", "sh"), ("ç", "ch"), ("ğ", "g"), ("ı", "i"),
    ]

    private static func phoneticNormalize(_ s: String) -> String {
        var result = s.lowercased()
        for (from, to) in phoneticMap {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    /// No longer read by the live matching path (the fuzzy fallback that used them was
    /// disabled — see `disabledFuzzyMatch(for:in:)`). Left in place, still referenced by that
    /// function's dead code, so re-enabling is a one-line change if ever revisited; removing
    /// them would mean reconstructing these values from scratch instead.
    private static let minFuzzyRootLength = 5
    private static let fuzzySimilarityThreshold = 0.65
    /// Minimum root length to trust an exact (post-normalization) match when no ş/ç/ğ/ı
    /// substitution fired — below this, a bare-letter collision with a short common Turkish
    /// word stem (e.g. "bun"/"Bun", "git"/"Git") is too likely.
    private static let minRootLengthForBareMatch = 4

    private static var glossaryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenWhisper/glossary.txt")
    }

    /// Single-word glossary terms only — a multi-word entry (e.g. "AI agent") can't be the
    /// target of a one-word phonetic correction.
    private static func loadSingleWordGlossaryTerms() -> [String] {
        guard let contents = try? String(contentsOf: glossaryURL, encoding: .utf8) else { return [] }
        return contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.contains(" ") }
    }

    /// `.ambiguous` is distinct from `.none`: it means the root DID connect to the glossary,
    /// just not to a single term confidently. Callers must treat that as a stop signal, not
    /// fall through to a less precise root guess (see `correctWord`).
    ///
    /// `.ambiguous` was only ever produced by the fuzzy-fallback branch, now disabled (see
    /// `disabledFuzzyMatch(for:in:)`) — `bestMatch` itself no longer returns it. The case, and
    /// `correctWord`'s handling of it, are kept rather than removed: `disabledFuzzyMatch` still
    /// returns it in its dead code, and the early-exit in `correctWord` is cheap insurance if
    /// the fuzzy path is ever reinstated (dropping it now would just mean re-deriving the same
    /// "don't fall through past ambiguous" protection later).
    private enum MatchResult {
        case found(String)
        case ambiguous
        case none
    }

    private static func bestMatch(for root: String, in terms: [String]) -> MatchResult {
        let normalizedRoot = phoneticNormalize(root)
        let hadPhoneticSubstitution = normalizedRoot != root.lowercased()

        // Exact match after phonetic normalization is the ONLY matching strategy now — this
        // used to be step 1 of 2, with a fuzzy-distance fallback as step 2. The fallback was
        // measured against real logged corrections and removed; see `disabledFuzzyMatch(for:in:)`
        // immediately below for the data and reasoning.
        //
        // Trusted at any length when a real ş/ç/ğ/ı substitution fired (a strong signal this is
        // a Turkish transliteration, not an ordinary short Turkish word) — otherwise only at
        // minRootLengthForBareMatch, since several glossary terms happen to collide with common
        // Turkish word stems verbatim (e.g. "Bun" the JS runtime vs. "bun" in "bunu"/"buna";
        // "Git" vs. the verb "git").
        if let exact = terms.first(where: { $0.lowercased() == normalizedRoot }) {
            return (hadPhoneticSubstitution || root.count >= minRootLengthForBareMatch) ? .found(exact) : .none
        }
        return .none
    }

    /// DISABLED. Not called from `bestMatch` or anywhere else — kept, uncalled, as a record of
    /// what was tried and why it was rejected, following the same pattern as
    /// `WhisperTranscriber.maxGlossaryPromptTokens`'s glossary-prompt-conditioning writeup
    /// (WhisperTranscriber.swift:76-132) and its disabled call site (WhisperTranscriber.swift
    /// ~269-290): empirical verdict first, mechanism preserved for anyone tempted to re-add it.
    ///
    /// EMPIRICAL VERDICT: this fuzzy fallback did more harm than good. Extracted from live usage
    /// logs (`/tmp/openwhisper.log`), every one of the 22 corrections this corrector fired broke
    /// down as follows.
    ///
    /// Harmful (7 cases, ALL via this fuzzy branch — none were exact matches):
    ///   - "kitaba" -> "GitLab'a" (x3) — "kitaba" is an ordinary Turkish word (root/term
    ///     distance 2, similarity 0.67, no phonetic substitution involved)
    ///   - "tekrardan" -> "Terra'dan" — ordinary Turkish word (distance 2, similarity 0.67)
    ///   - "basınca" -> "async'a" — ordinary Turkish word (distance 2, similarity 0.67, DID
    ///     involve a phonetic substitution — that alone isn't a reliable enough signal)
    ///   - "kışla" -> "pushla" — ordinary Turkish word (distance 2, similarity 0.67, phonetic
    ///     substitution fired)
    ///   - "Shift" -> "Swift" — ordinary word, a keyboard key name (distance 1, similarity 0.80)
    ///
    /// Helpful (15 cases): all but one were EXACT matches (distance 0) — i.e. already covered
    /// by the exact-match branch above and unaffected by removing this fallback: "pushla" ->
    /// "push'la" (x5), "puşla" -> "push'la" (x3, via the ş->sh phonetic substitution, still
    /// exact after normalization), "commitle" -> "commit'le", "Commiti" -> "Commit'i", "Codexi"
    /// -> "Codex'i".
    ///
    /// The ONE helpful case that actually depended on this fuzzy branch: "komitle" ->
    /// "commit'le" (x5), root/term distance 2, similarity 0.67.
    ///
    /// WHY TUNING THE THRESHOLD DOESN'T WORK: the one helpful case and the two worst harmful
    /// cases ("kitaba"->"GitLab", "tekrardan"->"Terra") sit at the EXACT SAME similarity, 0.67.
    /// No threshold value separates them — they are indistinguishable on this metric. Tightening
    /// to distance <=1 kills "komitle" (distance 2) while leaving "Shift"->"Swift" (distance 1)
    /// alive. This was measured, not assumed; there is no knob here that fixes it.
    ///
    /// WHERE THE ONE HELPFUL CASE IS HANDLED NOW: "komitle"->"commit'le" is covered by the
    /// learned-correction store plus `CorrectionEngine.applyCorrections`'s Turkish
    /// suffix-chain matching, with a confirmed `komit -> commit` entry already active there.
    /// That path only fires on corrections a user has actually confirmed, which is exactly the
    /// confidence bar this unconfirmed, automatic corrector cannot offer for a fuzzy (non-exact)
    /// match. Verified directly: with this fallback disabled, "komitle" is no longer touched by
    /// `PhoneticGlossaryCorrector` (as expected — the learned store now owns it), while all 7
    /// harmful cases above are also no longer touched, and all 15 helpful cases still fire via
    /// the exact-match branch.
    private static func disabledFuzzyMatch(for root: String, in terms: [String]) -> MatchResult {
        // Gated by root length, to catch cases phonetic substitution alone can't (e.g. a dropped
        // mid-word letter, "gitab" for "GitHub"). Rejected outright if MORE THAN ONE glossary
        // term clears the threshold: with sibling terms present (GitHub/GitLab, push/pull), edit
        // distance alone can't tell which one is right, and a confident wrong guess (silently
        // rewriting GitHub as GitLab) is worse than no correction at all. None of this saves it
        // from the 0.67 collision documented above.
        guard root.count >= minFuzzyRootLength else { return .none }
        let normalizedRoot = phoneticNormalize(root)
        let qualifiers = terms
            .map { (term: $0, score: CorrectionEngine.normalizedSimilarity(normalizedRoot, $0)) }
            .filter { $0.score >= fuzzySimilarityThreshold }
        if qualifiers.count == 1 { return .found(qualifiers[0].term) }
        return qualifiers.isEmpty ? .none : .ambiguous
    }

    /// Attempts to correct a single word against the glossary. Returns the corrected word
    /// (glossary casing + original Turkish suffix reattached) or nil if no confident match.
    /// An ambiguous result for ANY interpretation of the word stops the search immediately —
    /// falling through to a looser root guess after an ambiguous hit would silently trade a
    /// "don't know" for a "guessed wrong" (this is exactly how "gitaba" first got miscorrected
    /// to "GitLab" during testing: the suffix-stripped "gitab" root was correctly flagged
    /// ambiguous between GitHub/GitLab, but the code kept going and matched the unstripped
    /// whole word instead).
    private static func correctWord(_ word: String, terms: [String]) -> String? {
        for suffix in candidateSuffixes where word.count > suffix.count {
            guard word.lowercased().hasSuffix(suffix) else { continue }
            let root = String(word.dropLast(suffix.count))
            guard root.count >= 2 else { continue }
            switch bestMatch(for: root, in: terms) {
            case .found(let match):
                let cased = CorrectionEngine.matchCase(of: root, applyTo: match)
                let needsApostrophe = match.last?.isLetter == true && suffix.first?.isLetter == true
                return cased + (needsApostrophe ? "'" : "") + suffix
            case .ambiguous:
                return nil
            case .none:
                continue
            }
        }
        // Fall back to trying the whole word with no suffix stripped.
        guard word.count >= 2 else { return nil }
        if case .found(let match) = bestMatch(for: word, in: terms) {
            return CorrectionEngine.matchCase(of: word, applyTo: match)
        }
        return nil
    }

    /// Applies phonetic glossary correction to every word in `text`, leaving separators and
    /// punctuation untouched. Returns the corrected text plus the (original, corrected) pairs
    /// that fired, for logging.
    static func correct(_ text: String) -> (result: String, applied: [(String, String)]) {
        let terms = loadSingleWordGlossaryTerms()
        guard !terms.isEmpty else { return (text, []) }

        var tokens = CorrectionEngine.tokenize(text)
        var applied: [(String, String)] = []
        for i in tokens.indices where tokens[i].isWord {
            let original = tokens[i].text
            guard let corrected = correctWord(original, terms: terms), corrected != original else { continue }
            tokens[i] = CorrectionEngine.Token(text: corrected, isWord: true)
            applied.append((original, corrected))
        }
        guard !applied.isEmpty else { return (text, []) }
        return (tokens.map(\.text).joined(), applied)
    }
}
