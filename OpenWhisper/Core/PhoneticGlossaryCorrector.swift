import Foundation

/// Deterministic pass that recognizes glossary terms transliterated into Turkish phonetic
/// spelling with an attached Turkish suffix (e.g. Whisper's "puşla" for "pushla", "gitaba"
/// for "GitHub'a") and restores the correct spelling while keeping the Turkish suffix.
///
/// Pure string matching, no model call — runs on the fast path in `initialText` alongside
/// `CorrectionEngine.applyCorrections`, independent of Ollama. Deliberately conservative:
/// unlike the learned-correction store, nothing here is user-confirmed, so a match is only
/// applied when it's either exact (after phonetic normalization) or long+unambiguous enough
/// that a false positive is unlikely.
enum PhoneticGlossaryCorrector {

    /// Candidate Turkish suffixes to try stripping from a word's end, longest first so a
    /// longer real suffix isn't shadowed by a shorter one that happens to be a substring.
    private static let candidateSuffixes: [String] = [
        "lamak", "lemek", "ladım", "ledim", "ladık", "ledik", "ladı", "ledi",
        "luyorum", "lüyorum", "luyor", "lüyor", "ları", "leri",
        "dan", "den", "tan", "ten", "nın", "nin", "nun", "nün",
        "da", "de", "ta", "te", "la", "le", "a", "e", "ı", "i", "u", "ü",
    ].sorted { $0.count > $1.count }

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

    /// Below this stripped-root length, only an exact (post-normalization) match is trusted —
    /// short roots collide too easily with unrelated Turkish words for an unconfirmed fuzzy
    /// automatic rewrite to be safe.
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
    private enum MatchResult {
        case found(String)
        case ambiguous
        case none
    }

    private static func bestMatch(for root: String, in terms: [String]) -> MatchResult {
        let normalizedRoot = phoneticNormalize(root)
        let hadPhoneticSubstitution = normalizedRoot != root.lowercased()

        // 1. Exact match after phonetic normalization. Trusted at any length when a real
        // ş/ç/ğ/ı substitution fired (a strong signal this is a Turkish transliteration, not
        // an ordinary short Turkish word) — otherwise only at minRootLengthForBareMatch, since
        // several glossary terms happen to collide with common Turkish word stems verbatim
        // (e.g. "Bun" the JS runtime vs. "bun" in "bunu"/"buna"; "Git" vs. the verb "git").
        if let exact = terms.first(where: { $0.lowercased() == normalizedRoot }) {
            return (hadPhoneticSubstitution || root.count >= minRootLengthForBareMatch) ? .found(exact) : .none
        }

        // 2. Fuzzy fallback — gated by root length, to catch cases phonetic substitution
        // alone can't (e.g. a dropped mid-word letter, "gitab" for "GitHub"). Rejected outright
        // if MORE THAN ONE glossary term clears the threshold: with sibling terms present
        // (GitHub/GitLab, push/pull), edit distance alone can't tell which one is right, and a
        // confident wrong guess (silently rewriting GitHub as GitLab) is worse than no
        // correction at all.
        guard root.count >= minFuzzyRootLength else { return .none }
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
