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

    /// Sparse safety net for apps that do not expose AX value-change notifications.
    /// Observer-capable apps do not use checkpoint timers at all.
    static let defaultCheckpointsString = "3, 10, 30"
    static let defaultCheckpoints: [TimeInterval] = [3, 10, 30]
    static let legacyDefaultCheckpointsString = "1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30"

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

    // MARK: - Manual review: soft-anchored trim (Option+Shift+C, active-snapshot path)

    /// The automatic path's diff guard requires the field's current text to match the ORIGINAL
    /// prefix/suffix around the pasted span EXACTLY, bailing the instant anything around it also
    /// changed (see `DictationSnapshot.diffAndLearn`'s `manual == false` branch). Manual review
    /// relaxes exactly that guard — nothing else — by finding how much of `originalPrefix` still
    /// matches the START of `currentText` and how much of `originalSuffix` still matches its END,
    /// then returning the UTF-16 range of whatever's left in between: the actual candidate span
    /// to diff the originally-pasted text against. `originalPrefix`/`originalSuffix` come from
    /// the field's OWN state at paste time (`boxed.fieldTextAtPaste` sliced at `boxed.pastedRange`
    /// in the caller) — this is a soft version of the same anchor the strict path already uses,
    /// not a fallback to diffing the whole field blind.
    ///
    /// A cut is never allowed to land inside a word: `wordBoundaryBackoff`/`wordBoundaryAdvance`
    /// pull it out to the nearest whole-word boundary first, so a partially-matched word can
    /// never be sliced in half and manufacture a bogus substitution candidate out of nothing.
    ///
    /// If the two trims would overlap (nothing sensible left in between — e.g. the prefix and
    /// suffix trims eat the whole string), returns the full range of `currentText` instead of a
    /// corrupt one; callers should treat that the same as "no anchor found."
    static func softAnchorRange(currentText: String, originalPrefix: String, originalSuffix: String) -> Range<Int> {
        let fullRange = 0..<currentText.utf16.count

        let commonPrefixLen = commonPrefixUTF16Length(currentText, originalPrefix)
        let commonSuffixLen = commonSuffixUTF16Length(currentText, originalSuffix)

        let start = wordBoundaryBackoff(commonPrefixLen, in: currentText)
        let end = wordBoundaryAdvance(currentText.utf16.count - commonSuffixLen, in: currentText)

        guard start <= end else { return fullRange }
        return start..<end
    }

    /// UTF-16 length of the longest common prefix of `a` and `b`.
    static func commonPrefixUTF16Length(_ a: String, _ b: String) -> Int {
        let au = Array(a.utf16), bu = Array(b.utf16)
        var i = 0
        let limit = min(au.count, bu.count)
        while i < limit, au[i] == bu[i] { i += 1 }
        return i
    }

    /// UTF-16 length of the longest common suffix of `a` and `b`.
    static func commonSuffixUTF16Length(_ a: String, _ b: String) -> Int {
        let au = Array(a.utf16), bu = Array(b.utf16)
        var i = 0
        let limit = min(au.count, bu.count)
        while i < limit, au[au.count - 1 - i] == bu[bu.count - 1 - i] { i += 1 }
        return i
    }

    /// If UTF-16 offset `offset` in `text` falls strictly inside a word token (per `isWordChar`)
    /// rather than at a token boundary, moves it back to the start of that word. Offsets at 0,
    /// at `text.utf16.count`, or already sitting on a token boundary are returned unchanged.
    static func wordBoundaryBackoff(_ offset: Int, in text: String) -> Int {
        guard offset > 0, offset < text.utf16.count else { return offset }
        let charIdx = String.Index(utf16Offset: offset, in: text)
        guard charIdx > text.startIndex, charIdx < text.endIndex else { return offset }
        let prevIdx = text.index(before: charIdx)
        guard isWordChar(text[prevIdx]), isWordChar(text[charIdx]) else { return offset }
        var wordStart = charIdx
        while wordStart > text.startIndex, isWordChar(text[text.index(before: wordStart)]) {
            wordStart = text.index(before: wordStart)
        }
        return wordStart.utf16Offset(in: text)
    }

    /// Mirror of `wordBoundaryBackoff` for the trailing cut: moves forward to the end of the
    /// word instead of back to its start.
    static func wordBoundaryAdvance(_ offset: Int, in text: String) -> Int {
        guard offset > 0, offset < text.utf16.count else { return offset }
        let charIdx = String.Index(utf16Offset: offset, in: text)
        guard charIdx > text.startIndex, charIdx < text.endIndex else { return offset }
        let prevIdx = text.index(before: charIdx)
        guard isWordChar(text[prevIdx]), isWordChar(text[charIdx]) else { return offset }
        var wordEnd = charIdx
        while wordEnd < text.endIndex, isWordChar(text[wordEnd]) {
            wordEnd = text.index(after: wordEnd)
        }
        return wordEnd.utf16Offset(in: text)
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

    /// Walk the LCS alignment and collect true substitutions plus the two supported compound
    /// reshaping shapes: a merge (two old words becoming one new word, e.g. "her şey" ->
    /// "herşey") and its mirror, a split (one old word becoming two new words, e.g. "Komitat"
    /// -> "commit at" — Whisper mishearing an English term as one word glued to a Turkish
    /// suffix). Insertions/deletions and longer rewrites are NOT candidates at all (discarded
    /// here, not later).
    static func substitutionCandidates(oldWords: [String], newWords: [String]) -> [RawSubstitution] {
        let matches = lcsMatches(oldWords, newWords)
        var candidates: [RawSubstitution] = []

        func handleGap(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int) {
            let oldLen = oldEnd - oldStart
            let newLen = newEnd - newStart
            let isSameWordCount = oldLen == newLen && oldLen >= 1 && oldLen <= 3
            let isCompoundMerge = oldLen == 2 && newLen == 1
            let isCompoundSplit = oldLen == 1 && newLen == 2
            guard isSameWordCount || isCompoundMerge || isCompoundSplit else { return }
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
    ///
    /// Also doubles as the "protected real word" list for `applyCorrections`'s suffix-symmetric
    /// matching (see `isProtectedWrongSide`): a learned pair whose root is a common real
    /// Turkish/English word must never fire on that word's own inflected forms (e.g. a stray
    /// "kafes" -> "kafe" pair must not rewrite "kafeste"), even if `allowSuffixMatching` is set.
    /// Expanded well beyond short function words to cover common everyday vocabulary (verb
    /// roots, everyday nouns, pronouns, conjunctions, numbers) precisely so that surface. This
    /// intentionally makes `accept` more selective for anything that touches these words.
    static let blacklist: Set<String> = [
        // Turkish — pronouns / determiners
        "bir", "bin", "bu", "şu", "o", "ben", "sen", "biz", "siz", "onlar", "bunu", "şunu",
        "onu", "buna", "şuna", "ona", "bunda", "şunda", "onda", "bundan", "şundan", "ondan",
        "kendi", "kendim", "kendin", "kendisi", "kendimiz", "kendiniz", "kendileri",
        "hangi", "kim", "kime", "kimi", "kimin", "kimden", "ne", "neyi", "neye", "neyden",
        "nerede", "nereye", "nereden", "biri", "birisi", "birileri", "herkes", "hiçkimse",
        "hiçbiri", "çoğu", "bazı", "bazısı", "tümü", "hepsi", "böyle", "şöyle", "öyle",
        "beni", "seni", "bizi", "sizi", "onları", "bana", "sana", "bize", "size", "onlara",
        // Turkish — conjunctions / particles / question words
        "ve", "veya", "ya", "ama", "fakat", "ancak", "lakin", "çünkü", "zira", "ki", "de", "da",
        "ile", "veyahut", "oysa", "halbuki", "üstelik", "ayrıca", "yine", "hem", "gerek",
        "ister", "meğer", "işte", "tabii", "sanki", "güya", "mademki", "madem", "eğer", "şayet",
        "için", "mi", "mı", "mu", "mü", "diye", "olan", "olarak", "kadar", "gibi", "ise",
        // Turkish — adverbs / common function-ish words
        "çok", "az", "var", "yok", "hiç", "daha", "en", "her", "bütün", "tüm", "birçok",
        "birkaç", "hemen", "şimdi", "sonra", "önce", "artık", "hâlâ", "hala", "belki", "mutlaka",
        "kesinlikle", "galiba", "sadece", "yalnız", "yalnızca", "bile", "dahi", "üzere",
        // Turkish — numbers
        "iki", "üç", "dört", "beş", "altı", "yedi", "sekiz", "dokuz", "on", "yirmi", "otuz",
        "kırk", "elli", "altmış", "yetmiş", "seksen", "doksan", "yüz", "milyon", "milyar",
        "sıfır", "birinci", "ikinci", "üçüncü", "dördüncü", "beşinci", "altıncı", "yedinci",
        "sekizinci", "dokuzuncu", "onuncu",
        // Turkish — common verb roots / everyday verbs (incl. forms mentioned in the bug report)
        "git", "gel", "yap", "et", "ol", "al", "ver", "gör", "bil", "iste", "söyle", "konuş",
        "anla", "dur", "kalk", "otur", "yürü", "koş", "bak", "dinle", "oku", "yaz", "çalış",
        "uyu", "başla", "bitir", "aç", "kapat", "gir", "çık", "düş", "kaldır", "koy", "bırak",
        "tut", "çek", "it", "dön", "geç", "kaç", "sakla", "bul", "kaybet", "sev", "sevin",
        "üzül", "kır", "kırıl", "yıkıl", "yık", "kur", "kurul", "gönder", "getir", "götür",
        "düşün", "unut", "hatırla", "izle", "seyret", "oyna", "kazan", "kaybet", "sat", "satın",
        "öde", "harca", "biriktir", "temizle", "kirlet", "yıka", "kurut", "pişir", "ye", "iç",
        "uyan", "yat", "kalk", "koş", "atla", "düzelt", "düzeldi", "düzelmek", "düzeltmek",
        "bozul", "bozuldu", "bozmak", "kırıldı", "yandı", "söndü", "yak", "söndür",
        // Turkish — everyday nouns
        "ev", "araba", "yol", "gün", "gece", "sabah", "akşam", "öğle", "hafta", "ay", "yıl",
        "saat", "dakika", "saniye", "zaman", "yer", "şehir", "ülke", "dünya", "insan", "adam",
        "kadın", "çocuk", "anne", "baba", "kardeş", "arkadaş", "aile", "iş", "okul", "ders",
        "kitap", "kalem", "masa", "sandalye", "kapı", "pencere", "oda", "mutfak", "banyo",
        "bahçe", "park", "market", "dükkan", "mağaza", "hastane", "doktor", "öğretmen",
        "öğrenci", "para", "kart", "telefon", "bilgisayar", "internet", "su", "ekmek", "yemek",
        "çay", "kahve", "süt", "et", "sebze", "meyve", "elma", "armut", "kafe", "kafes", "çete",
        "komite", "host", "misafir", "ziyaretçi", "patron", "müdür", "şirket", "ofis", "toplantı",
        "proje", "rapor", "sorun", "problem", "çözüm", "fikir", "plan", "hedef", "başarı",
        "hata", "yanlış", "doğru", "güzel", "kötü", "büyük", "küçük", "uzun", "kısa", "yeni",
        "eski", "genç", "yaşlı", "sıcak", "soğuk", "hızlı", "yavaş", "kolay", "zor", "ucuz",
        "pahalı", "temiz", "kirli", "açık", "kapalı", "dolu", "boş", "sağ", "sol", "yukarı",
        "aşağı", "içeri", "dışarı", "üst", "alt", "ön", "arka", "yan", "orta", "köşe", "kenar",
        "sokak", "cadde", "meydan", "köy", "mahalle", "il", "ilçe", "deniz", "göl", "nehir",
        "dağ", "orman", "hava", "yağmur", "kar", "rüzgar", "güneş", "ay", "yıldız", "gökyüzü",
        "renk", "kırmızı", "mavi", "yeşil", "sarı", "siyah", "beyaz", "mor", "pembe", "gri",
        "para", "banka", "hesap", "kredi", "borç", "gelir", "gider", "fiyat", "indirim",
        // English
        "the", "a", "an", "is", "to", "of", "in", "on", "at", "it", "and", "or", "but", "so",
        "for", "with", "as", "by", "be", "am", "are", "was", "were", "this", "that", "i", "you",
        "he", "she", "we", "they", "them", "his", "her", "its", "our", "your", "their", "not",
        "no", "yes", "if", "then", "than", "when", "where", "what", "who", "why", "how",
        "there", "here", "up", "down", "out", "over", "under", "again", "just", "only", "very",
        "can", "will", "would", "could", "should", "do", "does", "did", "have", "has", "had",
        "go", "goes", "went", "get", "gets", "got", "make", "makes", "made", "take", "takes",
        "took", "come", "comes", "came", "see", "sees", "saw", "know", "knows", "knew",
        "day", "time", "year", "week", "month", "people", "man", "woman", "child", "work",
        "life", "world", "school", "house", "car", "food", "water", "money", "book", "phone",
    ]

    static func containsBlacklistedWrongWord(_ phrase: String) -> Bool {
        phrase.split(separator: " ").contains { blacklist.contains(trLower(String($0))) }
    }

    /// Public gate used by `CorrectionStore` (and by `applyCorrections`'s suffix-symmetric
    /// matching below) to check whether a single word is a protected real word that a learned
    /// correction's "wrong" side must never be allowed to shadow.
    static func isProtectedWrongSide(_ word: String) -> Bool {
        blacklist.contains(trLower(word))
    }

    // MARK: - Acceptance filters

    struct Candidate: Equatable {
        let wrong: String
        let right: String
    }

    /// Runs every acceptance filter from the spec. Returns nil if the candidate should be
    /// discarded (never learned); otherwise returns the (still full-inflected) accepted pair.
    /// Thin wrapper over `acceptWithReason` — kept so no existing call site or test needs to
    /// change when a rejection reason is needed for diagnostics (see `acceptWithReason`).
    static func accept(_ raw: RawSubstitution) -> Candidate? {
        acceptWithReason(raw).candidate
    }

    /// Same acceptance logic as `accept`, but also reports WHY a candidate was rejected —
    /// purely for diagnostics/logging (`DictationSnapshot.diffAndLearn`), so a "0 accepted"
    /// log line can say which filter fired instead of leaving the operator to guess.
    /// Reasons: "ok", "caseOrPunctuationOnly", "wordShorterThan2", "blacklistedWrongSide",
    /// "phraseTooLong", "lowSimilarity(0.42)".
    static func acceptWithReason(_ raw: RawSubstitution) -> (candidate: Candidate?, reason: String) {
        let wrong = raw.wrong
        let right = raw.right

        let wrongWords = wrong.split(separator: " ").map(String.init)
        let rightWords = right.split(separator: " ").map(String.init)
        let isCompoundMerge = wrongWords.count == 2 && rightWords.count == 1
        let isCompoundSplit = wrongWords.count == 1 && rightWords.count == 2

        // Case-only or punctuation-only difference — LLM cleanup already handles that.
        if trLower(wrong) == trLower(right) { return (nil, "caseOrPunctuationOnly") }
        let stripPunct: (String) -> String = { s in
            String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
        // For a compound merge/split, whitespace is the actual semantic difference (e.g.
        // "Komitat" vs "commit at" strip-punct-equal to "komitat"/"commitat" only if you ignore
        // the space, which IS the correction), so it must not be mistaken for punctuation-only
        // noise by the normalized comparison below.
        if !isCompoundMerge, !isCompoundSplit, trLower(stripPunct(wrong)) == trLower(stripPunct(right)) {
            return (nil, "caseOrPunctuationOnly")
        }

        // Word-length floor: any individual word under 2 chars kills the whole candidate.
        guard wrongWords.allSatisfy({ $0.count >= 2 }), rightWords.allSatisfy({ $0.count >= 2 }) else {
            return (nil, "wordShorterThan2")
        }

        // Blacklist: common short words may never sit on the "wrong" side.
        // A compound MERGE's wrong side is not a standalone occurrence of any one word, so
        // allow common components such as "her şey" or "bir çok" to be learned as a single
        // compound. A compound SPLIT's wrong side, in contrast, IS a single standalone word
        // (e.g. "Komitat"), so the ordinary blacklist protection must stay in force — otherwise
        // a stray edit near a common word (e.g. "et" -> "e t") could corrupt every future
        // occurrence of that word.
        if !isCompoundMerge {
            guard !wrongWords.contains(where: { blacklist.contains(trLower($0)) }) else {
                return (nil, "blacklistedWrongSide")
            }
        }

        // 1-3 word phrase cap for ordinary substitutions; compound merges are exactly 2 -> 1
        // and compound splits are exactly 1 -> 2 (both already satisfy wrongWords.count <= 3,
        // spelled out explicitly here for clarity/symmetry with isCompoundMerge).
        guard (wrongWords.count >= 1 && wrongWords.count <= 3) || isCompoundMerge || isCompoundSplit else {
            return (nil, "phraseTooLong")
        }

        // Similarity floor: normally 0.6 (normalized Levenshtein distance <= 0.4). A full
        // rewrite of the phrase (different wording, not a mishearing) fails this.
        //
        // The floor drops to `relaxedSimilarityFloor` when the two sides share a real leading
        // stretch — see `sharedOnsetLength`. Whisper decodes left to right, so a misheard
        // technical term usually keeps the START of the word and mangles the tail; the plain
        // normalized distance punishes exactly that shape on short words. Live case that forced
        // this: "gitap" -> "github" scores 0.50 and was refused even though the user had
        // explicitly typed the fix and pressed Option+Shift+C twice ("git ha" -> "github" is the
        // same 0.50). Every harmful substitution this project has recorded fails the onset test
        // and is therefore untouched by the relaxation: "kitaba"/"GitLab'a" and "kışla"/"pushla"
        // share nothing, "tekrardan"/"Terra'dan" shares only 2.
        let similarity = normalizedSimilarity(wrong, right)
        let onset = sharedOnsetLength(wrong, right)
        let lengthGap = abs(wrong.count - right.count)
        // A mishearing is roughly as long as what was actually said. Without this second gate
        // the onset rule alone lets a genuine rewrite through on nothing but a shared stem:
        // "kitaplar" -> "kitapçıklarımızdan" shares a 5-character onset and scores 0.44, which
        // clears the relaxed floor while being obviously not a mishearing. Caught by a test that
        // was written expecting a rejection and initially failed.
        let relaxed = onset >= minSharedOnsetForRelaxedSimilarity
            && lengthGap <= maxLengthGapForRelaxedSimilarity
        let floor = relaxed ? relaxedSimilarityFloor : defaultSimilarityFloor
        guard similarity >= floor else {
            return (nil, "lowSimilarity(\(String(format: "%.2f", similarity)), floor \(String(format: "%.2f", floor)), onset \(onset), lengthGap \(lengthGap))")
        }

        return (Candidate(wrong: wrong, right: right), "ok")
    }

    static let defaultSimilarityFloor = 0.6
    static let relaxedSimilarityFloor = 0.4
    static let minSharedOnsetForRelaxedSimilarity = 3
    static let maxLengthGapForRelaxedSimilarity = 3

    /// Length of the common leading run of `a` and `b` (Turkish-aware lowercase), but **0
    /// whenever one side is a pure prefix of the other**.
    ///
    /// That exclusion is the whole safety of the relaxed floor. "git" -> "github" shares a
    /// 3-character onset, yet it is an EXTENSION, not a mishearing: learning it would rewrite
    /// every future occurrence of the standalone word. Only pairs that share an onset and then
    /// genuinely diverge ("gitap" / "github" — common "git", then "ap" vs "hub") describe the
    /// left-to-right decoding error the relaxation exists for.
    static func sharedOnsetLength(_ a: String, _ b: String) -> Int {
        let la = Array(trLower(a))
        let lb = Array(trLower(b))
        var n = 0
        while n < la.count, n < lb.count, la[n] == lb[n] { n += 1 }
        if n == la.count || n == lb.count { return 0 }
        return n
    }

    // MARK: - Shared Turkish suffix list

    /// Turkish inflectional suffixes, longest first so a longer real suffix isn't shadowed by
    /// a shorter one that happens to be a substring. Single source of truth shared by
    /// `PhoneticGlossaryCorrector` (one-shot single-suffix stripping — see its
    /// `candidateSuffixes` alias, behavior there is unchanged by this move) and by
    /// `applyCorrections`'s suffix-symmetric matching below.
    static let turkishSuffixes: [String] = [
        "lamak", "lemek", "ladım", "ledim", "ladık", "ledik", "ladı", "ledi",
        "luyorum", "lüyorum", "luyor", "lüyor", "ları", "leri",
        "dan", "den", "tan", "ten", "nın", "nin", "nun", "nün",
        "da", "de", "ta", "te", "la", "le", "a", "e", "ı", "i", "u", "ü",
    ].sorted { $0.count > $1.count }

    /// Extra morphemes needed ONLY to decompose a CHAIN of several suffixes stacked on one
    /// root (e.g. "komitindeki" = komit + in/nde + ki), which `turkishSuffixes` alone can't
    /// do because it only strips a single suffix. Kept separate — never folded into
    /// `turkishSuffixes` — so `PhoneticGlossaryCorrector`'s one-shot matching is provably
    /// unaffected by this addition; only `matchSuffixChain` below sees it.
    private static let chainOnlyExtraSuffixes: [String] = [
        "ki", "nde", "nda", "in", "ın", "un", "ün", "ler", "lar", "si", "sı", "su", "sü",
    ]

    private static let suffixChainCandidates: [String] =
        (turkishSuffixes + chainOnlyExtraSuffixes).sorted { $0.count > $1.count }

    /// Minimum learned-root length to trust suffix-symmetric matching in `applyCorrections`.
    /// Mirrors `PhoneticGlossaryCorrector.minRootLengthForBareMatch` (also 4) — same rationale:
    /// below this, a bare-letter/short-suffix strip collides too easily with unrelated real
    /// Turkish words (e.g. "çet" -> "çete" must NOT be treated as "çet" + "e").
    static let minRootLengthForSuffixMatch = 4

    /// Attempts to reduce `token` down to `root` by repeatedly stripping known Turkish
    /// suffixes off its end (longest match first, case-insensitive), so a learned root
    /// correction fires on any inflected form ("komitindeki", "komiti", ...) and not just the
    /// one exact form the user happened to correct. Returns the ORIGINAL-cased tail (the part
    /// of `token` after the root) if a chain of at most `maxStrips` suffixes fully reduces the
    /// token to `root`; nil otherwise (including when `token` doesn't even start with `root`).
    static func matchSuffixChain(token: String, root: String, maxStrips: Int = 3) -> String? {
        guard token.count > root.count, trLower(token).hasPrefix(root) else { return nil }
        var remaining = trLower(token)
        var strips = 0
        while remaining.count > root.count, strips < maxStrips {
            guard let suffix = suffixChainCandidates.first(where: {
                remaining.hasSuffix($0) && remaining.count - $0.count >= root.count
            }) else {
                return nil
            }
            remaining.removeLast(suffix.count)
            strips += 1
        }
        guard remaining == root else { return nil }
        return String(token.suffix(token.count - root.count))
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
        /// Opt-in: when true, `applyCorrections` may match this pair against ANY Turkish-
        /// suffixed form of `wrong` via `matchSuffixChain` (e.g. "komitindeki", "komiti"), not
        /// just an exact or apostrophe-suffixed token. Defaults to false so existing call sites
        /// that only supply wrong/right keep compiling and stay on the safe, exact-match-only
        /// behavior. Intended to be set true by `CorrectionStore` once a pair has accumulated
        /// enough confirmed occurrences to trust the looser match.
        var allowSuffixMatching: Bool = false
    }

    /// Reproduce the case pattern of `original` onto `replacement`:
    /// - ALL CAPS original → all-caps replacement
    /// - Capitalized (first letter upper, rest whatever) → capitalize replacement's first letter
    /// - otherwise → replacement used as-is (its stored/learned casing)
    static func matchCase(of original: String, applyTo replacement: String) -> String {
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

            // Second, strictly-lower-priority pass: suffix-symmetric (chain) matching for
            // pairs opted into it, tried ONLY when no exact/apostrophe/phrase match fired
            // above. Kept as a separate pass (not interleaved into the loop above) so a long
            // suffix-matching pair can never preempt a shorter exact match. Restricted to
            // tokens with no apostrophe — the apostrophe path above already owns those.
            if !didApply, lastApostropheIndex(tokens[i].text) == nil {
                let token = tokens[i].text
                for pair in sortedPairs {
                    guard pair.allowSuffixMatching,
                          words(pair.wrong).count == 1,
                          // A learned compound SPLIT (wrong: one word, right: multiple words,
                          // e.g. "komitat" -> "commit at") must NOT go through suffix-chain
                          // matching: the stripped tail would get glued onto only the LAST word
                          // of the replacement phrase (e.g. "Komitatı" -> "Commit atı"), which
                          // is not a valid inflection of anything — the suffix belongs to the
                          // whole original word, not to one word of its multi-word replacement.
                          // Exact/apostrophe matching above already handles split pairs fine;
                          // only this looser opt-in chain path needs the extra restriction.
                          words(pair.right).count == 1,
                          pair.wrong.count >= minRootLengthForSuffixMatch,
                          !isProtectedWrongSide(pair.wrong),
                          let tail = matchSuffixChain(token: token, root: pair.wrong)
                    else { continue }
                    let rootPortion = String(token.prefix(token.count - tail.count))
                    let replacedRoot = matchCase(of: rootPortion, applyTo: pair.right)
                    tokens[i] = Token(text: replacedRoot + tail, isWord: true)
                    applied.append((pair.wrong, pair.right))
                    didApply = true
                    break
                }
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
