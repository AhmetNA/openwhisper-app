import Foundation

/// Deterministic pass that recognizes glossary terms transliterated into Turkish phonetic
/// spelling with an attached Turkish suffix (e.g. Whisper's "puşla" for "pushla", "gitaba"
/// for "GitHub'a") and restores the correct spelling while keeping the Turkish suffix.
///
/// Pure string matching, no model call — runs on the fast path in `initialText` alongside
/// `CorrectionEngine.applyCorrections`, independent of Ollama. Deliberately conservative:
/// unlike the learned-correction store, nothing here is user-confirmed, so a match is only
/// applied when it's exact (after phonetic normalization). A fuzzy (edit-distance) fallback
/// used to run here too; it was measured and removed — see the note in `bestMatch`.
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

    /// Minimum root length to trust an exact (post-normalization) match when no ş/ç/ğ/ı
    /// substitution fired — below this, a bare-letter collision with a short common Turkish
    /// word stem (e.g. "bun"/"Bun", "git"/"Git") is too likely.
    private static let minRootLengthForBareMatch = 4

    private enum MatchResult {
        case found(String)
        case none
    }

    private static func bestMatch(for root: String, in terms: [String]) -> MatchResult {
        let normalizedRoot = phoneticNormalize(root)
        let hadPhoneticSubstitution = normalizedRoot != root.lowercased()

        // Exact match after phonetic normalization is the ONLY matching strategy. A fuzzy
        // (edit-distance) fallback was measured against 22 real logged corrections and removed:
        // all 7 harmful rewrites came from it ("kitaba"->"GitLab'a", "tekrardan"->"Terra'dan",
        // "Shift"->"Swift"…), and its one useful case ("komitle"->"commit'le") sat at the same
        // 0.67 similarity as the worst misfires, so no threshold separates them. That case is now
        // owned by the user-confirmed learned-correction store (`CorrectionEngine`).
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

    /// Attempts to correct a single word against the glossary. Returns the corrected word
    /// (glossary casing + original Turkish suffix reattached) or nil if no confident match.
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
        let terms = GlossaryStore.singleWordTerms()
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
