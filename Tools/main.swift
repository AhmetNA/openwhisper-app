import Foundation

// Standalone verification harness — NOT part of the app target (kept outside
// OpenWhisper/ so SwiftPM never compiles it into the executable).
//
// SpotifyManager.swift pulls in SpotifyController.swift and SpotifyWebAPI.swift as
// dependencies, and all three call the app's `owLog` and `OpenWhisperNotification.post`
// (both defined in OpenWhisper/App/OpenWhisperApp.swift, alongside `@main`, which
// top-level-code files like this one can't link against) — so tiny local stubs are
// passed in their place instead of pulling in the whole App/ target.
//
// Only the pure, AppKit/ApplicationServices-free logic is exercised here: CorrectionEngine,
// TurkishDateParser, SpotifyManager's query extraction. CorrectionStore is @MainActor and
// persists to the REAL ~/Library/Application Support/OpenWhisper/corrections.json, so it is
// deliberately NOT exercised by this harness — doing so from a top-level-code file would
// require hopping onto the main actor and would read/write the current user's live corrections
// store as a side effect of running tests.
//
// Run with:
//   cat > /tmp/owlog_stub.swift <<'EOF'
//   import Foundation
//   func owLog(_ msg: String) {}
//   enum OpenWhisperNotification {
//       static func post(title: String, body: String, isError: Bool = false, identifierPrefix: String = "openwhisper") {}
//   }
//   EOF
//   swiftc Tools/main.swift OpenWhisper/Core/CorrectionEngine.swift \
//     OpenWhisper/Core/TurkishDateParser.swift OpenWhisper/Core/SpotifyManager.swift \
//     OpenWhisper/Core/SpotifyController.swift OpenWhisper/Core/SpotifyWebAPI.swift \
//     OpenWhisper/Core/SpotifyRequestParser.swift \
//     /tmp/owlog_stub.swift -o /tmp/ow_harness && /tmp/ow_harness

var failures = 0
var total = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    total += 1
    if condition() {
        print("OK   \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

// MARK: - 1. Turkish agglutination root extraction: flagment'ı -> fragment'ı

do {
    let (wrong, right) = CorrectionEngine.extractRoot(wrong: "flagment'ı", right: "fragment'ı")
    check("root extraction flagment'ı -> fragment'ı gives roots", wrong == "flagment" && right == "fragment")
}

do {
    // No apostrophe, ordinary word pair should NOT be stripped into nonsense.
    let (wrong, right) = CorrectionEngine.extractRoot(wrong: "kod", right: "kot")
    check("no-apostrophe short words left alone", wrong == "kod" && right == "kot")
}

// MARK: - 2. Turkish I/ı locale casing

check("trLower(\"I\") == ı (Turkish, not ASCII i)", CorrectionEngine.trLower("I") == "ı")
check("trUpper(\"i\") == İ (Turkish dotted capital I)", CorrectionEngine.trUpper("i") == "İ")
check("trLower(\"İstanbul\") == istanbul", CorrectionEngine.trLower("İstanbul") == "istanbul")

// MARK: - 3. "bir" -> "bin" candidate rejected via blacklist

do {
    let oldWords = CorrectionEngine.words("bir saat sonra gel")
    let newWords = CorrectionEngine.words("bin saat sonra gel")
    let raws = CorrectionEngine.substitutionCandidates(oldWords: oldWords, newWords: newWords)
    check("diff finds the bir->bin substitution before filtering", raws.contains { $0.wrong == "bir" && $0.right == "bin" })
    let accepted = raws.compactMap(CorrectionEngine.accept)
    check("bir->bin rejected by blacklist", !accepted.contains { $0.wrong == "bir" && $0.right == "bin" })
}

// MARK: - 4. Full sentence rewrite rejected (style preference, not a mishearing)

do {
    let oldText = "Yarın toplantıya geç kalabilirim çünkü trafik çok yoğun olacak"
    let newText = "Sanırım yarın işe zamanında yetişemem, yollar tıkalı olur genelde"
    let raws = CorrectionEngine.substitutionCandidates(oldWords: CorrectionEngine.words(oldText), newWords: CorrectionEngine.words(newText))
    let accepted = raws.compactMap(CorrectionEngine.accept)
    check("full sentence rewrite yields no accepted candidates", accepted.isEmpty)
}

// MARK: - 5. Mishearing correction end-to-end: diff -> accept -> root -> apply

do {
    let oldText = "flagment'ı bana gönderir misin"
    let newText = "fragment'ı bana gönderir misin"
    let raws = CorrectionEngine.substitutionCandidates(oldWords: CorrectionEngine.words(oldText), newWords: CorrectionEngine.words(newText))
    check("mishearing diff finds exactly one substitution", raws.count == 1)
    let accepted = raws.compactMap(CorrectionEngine.accept)
    check("mishearing candidate accepted", accepted.count == 1)
    if let candidate = accepted.first {
        let (root, rightRoot) = CorrectionEngine.extractRoot(wrong: candidate.wrong, right: candidate.right)
        check("extracted root pair", root == "flagment" && rightRoot == "fragment")
        let pair = CorrectionEngine.LearnedPair(wrong: CorrectionEngine.trLower(root), right: rightRoot)
        let (applied, pairs) = CorrectionEngine.applyCorrections(to: "Şu flagment'a bak, flagment'ı da kontrol et", pairs: [pair])
        check("applied correction transfers suffix (flagment'a -> fragment'a)", applied.contains("fragment'a"))
        check("applied correction transfers suffix (flagment'ı -> fragment'ı)", applied.contains("fragment'ı"))
        check("apply reports 2 firings", pairs.count == 2)
    }
}

// MARK: - 6. Case preservation on apply

do {
    let pair = CorrectionEngine.LearnedPair(wrong: "flagment", right: "fragment")
    let (applied, _) = CorrectionEngine.applyCorrections(to: "Flagment'ı gönder", pairs: [pair])
    check("capitalized occurrence keeps capitalization", applied.hasPrefix("Fragment'ı"))
}

// MARK: - 7. Case-only diffs are not learned

do {
    let raws = CorrectionEngine.substitutionCandidates(oldWords: CorrectionEngine.words("merhaba dünya"), newWords: CorrectionEngine.words("Merhaba dünya"))
    let accepted = raws.compactMap(CorrectionEngine.accept)
    check("case-only diff not accepted", accepted.isEmpty)
}

// MARK: - 8. Short words (<2 chars) rejected

do {
    let raws = CorrectionEngine.substitutionCandidates(oldWords: CorrectionEngine.words("o adam geldi"), newWords: CorrectionEngine.words("a adam geldi"))
    let accepted = raws.compactMap(CorrectionEngine.accept)
    check("short (<2 char) word candidate rejected", accepted.isEmpty)
}

// MARK: - 9. Content appended after the pasted span isn't learned from

do {
    // Simulates: user fixed the mishearing AND kept typing more sentence after it.
    // Only the aligned 1:1 substitution should be accepted; the trailing appended words
    // must not turn into (bogus) insertion/deletion candidates.
    let oldText = "flagment'ı bana gönderir misin"
    let newText = "fragment'ı bana gönderir misin ayrıca yarın toplantı var"
    let raws = CorrectionEngine.substitutionCandidates(oldWords: CorrectionEngine.words(oldText), newWords: CorrectionEngine.words(newText))
    let accepted = raws.compactMap(CorrectionEngine.accept)
    check("append-after-paste yields exactly one accepted candidate", accepted.count == 1)
    check("append-after-paste candidate is the real mishearing", accepted.first == CorrectionEngine.Candidate(wrong: "flagment'ı", right: "fragment'ı"))
}

// MARK: - 10. Checkpoint interval setting validation (parseCheckpoints)

check("parseCheckpoints default '5, 10, 40'", CorrectionEngine.parseCheckpoints("5, 10, 40") == [5.0, 10.0, 40.0])
check("parseCheckpoints unordered '40, 5, 10'", CorrectionEngine.parseCheckpoints("40, 5, 10") == [5.0, 10.0, 40.0])
check("parseCheckpoints invalid letters '5, 10, abc'", CorrectionEngine.parseCheckpoints("5, 10, abc") == nil)
check("parseCheckpoints negative '-5, 10'", CorrectionEngine.parseCheckpoints("-5, 10") == nil)
check("parseCheckpoints zero '0, 10'", CorrectionEngine.parseCheckpoints("0, 10") == nil)
check("parseCheckpoints >300 '5, 301'", CorrectionEngine.parseCheckpoints("5, 301") == nil)
check("parseCheckpoints >60 items", CorrectionEngine.parseCheckpoints((1...61).map { "\($0)" }.joined(separator: ",")) == nil)
check("parseCheckpoints empty ''", CorrectionEngine.parseCheckpoints("") == nil)

// MARK: - 11. Compound-word merge learning: two words -> one word

do {
    let oldText = "her şey bugün hazır"
    let newText = "herşey bugün hazır"
    let raws = CorrectionEngine.substitutionCandidates(
        oldWords: CorrectionEngine.words(oldText),
        newWords: CorrectionEngine.words(newText)
    )
    check("compound merge diff finds her şey -> herşey", raws.contains { $0.wrong == "her şey" && $0.right == "herşey" })
    let accepted = raws.compactMap(CorrectionEngine.accept)
    check("compound merge candidate is accepted", accepted.contains { $0.wrong == "her şey" && $0.right == "herşey" })
    if let candidate = accepted.first(where: { $0.wrong == "her şey" && $0.right == "herşey" }) {
        let (wrong, right) = CorrectionEngine.extractRoot(wrong: candidate.wrong, right: candidate.right)
        check("compound merge keeps the full phrase", wrong == "her şey" && right == "herşey")
        let pair = CorrectionEngine.LearnedPair(wrong: wrong, right: right)
        let (applied, pairs) = CorrectionEngine.applyCorrections(
            to: "Her şey güzel. Her şey tamam.",
            pairs: [pair]
        )
        check("compound merge applies as one word", applied == "Herşey güzel. Herşey tamam.")
        check("compound merge reports both applications", pairs.count == 2)
    }
}

// MARK: - 12. TurkishDateParser — relative date/time parsing for voice reminders

do {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Istanbul")!
    // Fixed reference "now": Friday 2026-07-31 10:00:00 (matches system prompt's currentDate).
    var comps = DateComponents()
    comps.year = 2026; comps.month = 7; comps.day = 31; comps.hour = 10; comps.minute = 0; comps.second = 0
    comps.timeZone = cal.timeZone
    let now = cal.date(from: comps)!

    func dateAt(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = 0
        c.timeZone = cal.timeZone
        return cal.date(from: c)!
    }

    func run(_ input: String) -> TurkishDateParser.ParsedResult? {
        TurkishDateParser.parse(input, now: now, calendar: cal)
    }

    if let r = run("hatırlatıcı iki gün sonra telefonu yıka") {
        check("'iki gün sonra' -> +2 days at default 09:00", r.fireDate == dateAt(2026, 8, 2, 9, 0))
        check("'iki gün sonra' task extracted", r.task.lowercased() == "telefonu yıka")
    } else {
        check("'iki gün sonra telefonu yıka' parses", false)
    }

    if let r = run("hatırlatıcı 3 gün sonra saat 14'te rapor gönder") {
        check("'3 gün sonra saat 14'te' -> +3 days at 14:00", r.fireDate == dateAt(2026, 8, 3, 14, 0))
        check("'3 gün sonra saat 14'te' task extracted", r.task.lowercased() == "rapor gönder")
    } else {
        check("'3 gün sonra saat 14'te rapor gönder' parses", false)
    }

    if let r = run("hatırlatıcı öbür gün doktora git") {
        check("'öbür gün' -> +2 days at default 09:00", r.fireDate == dateAt(2026, 8, 2, 9, 0))
        check("'öbür gün' task extracted", r.task.lowercased() == "doktora git")
    } else {
        check("'öbür gün doktora git' parses", false)
    }

    if let r = run("hatırlatıcı haftaya market") {
        check("'haftaya' -> +7 days at default 09:00", r.fireDate == dateAt(2026, 8, 7, 9, 0))
        check("'haftaya' task extracted", r.task.lowercased() == "market")
    } else {
        check("'haftaya market' parses", false)
    }

    if let r = run("hatırlatıcı yarın 17'ye telefonu yıka") {
        check("'yarın 17'ye' -> tomorrow 17:00", r.fireDate == dateAt(2026, 8, 1, 17, 0))
        check("'yarın 17'ye' task extracted", r.task.lowercased() == "telefonu yıka")
    } else {
        check("'yarın 17'ye telefonu yıka' parses", false)
    }

    if let r = run("bana 10 dakika sonra kahve içmeyi hatırlat") {
        check("'10 dakika sonra' -> now + 10 minutes", r.fireDate == now.addingTimeInterval(600))
        check("'bana ... hatırlat' strips dangling 'bana' from task", r.task.lowercased() == "kahve içmeyi")
    } else {
        check("'10 dakika sonra kahve içmeyi hatırlat' parses", false)
    }

    if let r = run("hatırlatıcı önümüzdeki salı toplantı") {
        // 2026-07-31 is a Friday; next Tuesday is 2026-08-04.
        check("'önümüzdeki salı' -> next Tuesday at default 09:00", r.fireDate == dateAt(2026, 8, 4, 9, 0))
        check("'önümüzdeki salı' task extracted", r.task.lowercased() == "toplantı")
    } else {
        check("'önümüzdeki salı toplantı' parses", false)
    }

    // Non-date sentence should NOT be claimed by the deterministic parser (falls back to LLM).
    check("plain sentence with no date expression returns nil", run("hatırlatıcı telefonu yıka") == nil)

    // Bare dative suffixes ("e"/"a" with no leading consonant) — the exact phrasing used in
    // ReminderManager's own in-code Ollama prompt examples ("bugün 18'de", "yarın 17 ye"), plus
    // the bare-vowel variants ("18 e", "9'a") that a naive suffix regex could silently drop.
    if let r = run("hatırlatıcı bugün 18 e markete git") {
        check("'bugün 18 e' -> today 18:00", r.fireDate == dateAt(2026, 7, 31, 18, 0))
        check("'bugün 18 e' task extracted", r.task.lowercased() == "markete git")
    } else {
        check("'bugün 18 e markete git' parses", false)
    }

    if let r = run("hatırlatıcı yarın 9'a spor") {
        check("'yarın 9'a' -> tomorrow 09:00", r.fireDate == dateAt(2026, 8, 1, 9, 0))
        check("'yarın 9'a' task extracted", r.task.lowercased() == "spor")
    } else {
        check("'yarın 9'a spor' parses", false)
    }

    // "ayın 15'i" (day-of-month with possessive suffix) — the apostrophe + bare "i" must be
    // fully consumed so it doesn't leak into the task as a stray "İ".
    if let r = run("hatırlatıcı ayın 15'i markete git") {
        check("'ayın 15'i' -> day 15 of current month at default 09:00", r.fireDate == dateAt(2026, 8, 15, 9, 0))
        check("'ayın 15'i' task extracted (no stray apostrophe remnant)", r.task.lowercased() == "markete git")
    } else {
        check("'ayın 15'i markete git' parses", false)
    }

    if let r = run("hatırlatıcı gelecek ay diş hekimine git") {
        check("'gelecek ay' -> +1 month at default 09:00", r.fireDate == dateAt(2026, 8, 31, 9, 0))
        check("'gelecek ay' task extracted", r.task.lowercased() == "diş hekimine git")
    } else {
        check("'gelecek ay diş hekimine git' parses", false)
    }

    if let r = run("hatırlatıcı iki hafta sonra kira öde") {
        check("'iki hafta sonra' -> +14 days at default 09:00", r.fireDate == dateAt(2026, 8, 14, 9, 0))
        check("'iki hafta sonra' task extracted", r.task.lowercased() == "kira öde")
    } else {
        check("'iki hafta sonra kira öde' parses", false)
    }

    if let r = run("hatırlatıcı gelecek hafta diş randevusu") {
        check("'gelecek hafta' -> +7 days at default 09:00", r.fireDate == dateAt(2026, 8, 7, 9, 0))
        check("'gelecek hafta' task extracted", r.task.lowercased() == "diş randevusu")
    } else {
        check("'gelecek hafta diş randevusu' parses", false)
    }
}

// MARK: - 13. Suffix-symmetric matching in applyCorrections (bare, apostrophe-less agglutination)

do {
    // allowSuffixMatching = true, chained suffixes (komit + in/nde + ki, komit + i)
    let pair = CorrectionEngine.LearnedPair(wrong: "komit", right: "commit", allowSuffixMatching: true)
    let (r1, applied1) = CorrectionEngine.applyCorrections(to: "komitindeki değişiklik", pairs: [pair])
    check("suffix-chain match: komitindeki -> commitindeki", r1.hasPrefix("commitindeki"))
    check("suffix-chain match reports firing", applied1.contains(where: { $0.0 == "komit" && $0.1 == "commit" }))

    let (r2, _) = CorrectionEngine.applyCorrections(to: "komiti gönder", pairs: [pair])
    check("suffix-chain match: komiti -> commiti", r2.hasPrefix("commiti"))

    let (r3, _) = CorrectionEngine.applyCorrections(to: "komit gönder", pairs: [pair])
    check("suffix-chain match: exact komit -> commit still works", r3.hasPrefix("commit "))
}

do {
    // Same pair, allowSuffixMatching = false (default) -> gate must block the suffix-chain path.
    let pair = CorrectionEngine.LearnedPair(wrong: "komit", right: "commit")
    let (r, applied) = CorrectionEngine.applyCorrections(to: "komitindeki değişiklik", pairs: [pair])
    check("allowSuffixMatching=false blocks komitindeki from changing", r.hasPrefix("komitindeki"))
    check("allowSuffixMatching=false reports no firing", applied.isEmpty)
}

do {
    // THE critical safety case: short root (3 chars, below minRootLengthForSuffixMatch) must
    // NEVER be suffix-matched, even with allowSuffixMatching=true — "çete" is a real Turkish
    // word ("gang") and must not become "chate".
    let pair = CorrectionEngine.LearnedPair(wrong: "çet", right: "chat", allowSuffixMatching: true)
    let (r, applied) = CorrectionEngine.applyCorrections(to: "çete büyük bir sorun", pairs: [pair])
    check("short root (çet, 3 chars) does not corrupt real word çete", r.hasPrefix("çete "))
    check("short root gate reports no firing", applied.isEmpty)
}

do {
    // Second safety net: even a root that clears the length gate (kafes, 5 chars) must be
    // blocked if it's a protected real word (isProtectedWrongSide), so "kafeste" isn't
    // corrupted by a stray kafes->kafe learned pair.
    let pair = CorrectionEngine.LearnedPair(wrong: "kafes", right: "kafe", allowSuffixMatching: true)
    let (r, applied) = CorrectionEngine.applyCorrections(to: "kafeste bir kuş var", pairs: [pair])
    check("protected-word gate: kafeste not corrupted despite length gate passing", r.hasPrefix("kafeste "))
    check("protected-word gate reports no firing", applied.isEmpty)
}

do {
    // Existing apostrophe behavior must be untouched by the new suffix-chain branch.
    let pair = CorrectionEngine.LearnedPair(wrong: "flagment", right: "fragment", allowSuffixMatching: true)
    let (r, _) = CorrectionEngine.applyCorrections(to: "flagment'ı gönder", pairs: [pair])
    check("existing apostrophe path unaffected: flagment'ı -> fragment'ı", r.hasPrefix("fragment'ı"))
}

// MARK: - 14. isProtectedWrongSide public API

check("isProtectedWrongSide(\"kafes\") == true", CorrectionEngine.isProtectedWrongSide("kafes"))
check("isProtectedWrongSide(\"KAFES\") == true (case-insensitive)", CorrectionEngine.isProtectedWrongSide("KAFES"))
check("isProtectedWrongSide(\"çete\") == true", CorrectionEngine.isProtectedWrongSide("çete"))
check("isProtectedWrongSide(\"düzeldi\") == true", CorrectionEngine.isProtectedWrongSide("düzeldi"))
check("isProtectedWrongSide(\"düzelt\") == true", CorrectionEngine.isProtectedWrongSide("düzelt"))
check("isProtectedWrongSide(\"komite\") == true", CorrectionEngine.isProtectedWrongSide("komite"))
check("isProtectedWrongSide(\"host\") == true", CorrectionEngine.isProtectedWrongSide("host"))
check("isProtectedWrongSide(\"komit\") == false", !CorrectionEngine.isProtectedWrongSide("komit"))

// MARK: - 15. Compound-word SPLIT learning: one word -> two words (mirror of MARK 11's merge)

do {
    // Core bug-report case: Whisper glues an English term onto a Turkish word as one token.
    let oldText = "Komitat"
    let newText = "commit at"
    let raws = CorrectionEngine.substitutionCandidates(
        oldWords: CorrectionEngine.words(oldText),
        newWords: CorrectionEngine.words(newText)
    )
    check("split diff finds Komitat -> commit at", raws.contains { $0.wrong == "Komitat" && $0.right == "commit at" })
    let accepted = raws.compactMap(CorrectionEngine.accept)
    check("split candidate is accepted", accepted.contains { $0.wrong == "Komitat" && $0.right == "commit at" })
}

do {
    // Same split, but embedded in a sentence (the realistic dictation case).
    let oldText = "Komitat yapalım"
    let newText = "commit at yapalım"
    let raws = CorrectionEngine.substitutionCandidates(
        oldWords: CorrectionEngine.words(oldText),
        newWords: CorrectionEngine.words(newText)
    )
    let accepted = raws.compactMap(CorrectionEngine.accept)
    check("in-sentence split yields exactly the Komitat -> commit at pair",
          accepted == [CorrectionEngine.Candidate(wrong: "Komitat", right: "commit at")])
}

do {
    // A very different mishearing of the same rough shape must be rejected by the similarity
    // floor (0.6) — "Komizatsu" vs "commit at" is a different-enough mishearing that it should
    // NOT be learned as if it were the same correction.
    let sim = CorrectionEngine.normalizedSimilarity("Komizatsu", "commit at")
    check("Komizatsu vs commit at similarity is below the 0.6 floor", sim < 0.6)
    let accepted = CorrectionEngine.accept(CorrectionEngine.RawSubstitution(wrong: "Komizatsu", right: "commit at"))
    check("Komizatsu -> commit at rejected by similarity floor", accepted == nil)
}

do {
    // Regression: the existing 2->1 compound MERGE must still work exactly as before — this is
    // the most important check, since the split shape shares code paths (accept's stripPunct /
    // blacklist / word-count-cap branches) with the merge shape.
    let oldText = "her şey bugün hazır"
    let newText = "herşey bugün hazır"
    let raws = CorrectionEngine.substitutionCandidates(
        oldWords: CorrectionEngine.words(oldText),
        newWords: CorrectionEngine.words(newText)
    )
    let accepted = raws.compactMap(CorrectionEngine.accept)
    check("regression: compound merge her şey -> herşey still accepted",
          accepted.contains { $0.wrong == "her şey" && $0.right == "herşey" })
}

do {
    // extractRoot must leave a split pair's "right" side as the full two-word phrase (not
    // stripped down), and applyCorrections must place that full phrase back in, case-matched
    // to the original single wrong word's casing.
    let candidate = CorrectionEngine.Candidate(wrong: "Komitat", right: "commit at")
    let (wrong, right) = CorrectionEngine.extractRoot(wrong: candidate.wrong, right: candidate.right)
    check("split extractRoot leaves the pair untouched", wrong == "Komitat" && right == "commit at")
    let pair = CorrectionEngine.LearnedPair(wrong: CorrectionEngine.trLower(wrong), right: right)
    let (applied, pairs) = CorrectionEngine.applyCorrections(to: "Komitat yapalım", pairs: [pair])
    // matchCase capitalizes the replacement's first letter because "Komitat" is capitalized
    // in the source text — same contract as every other learned-pair application.
    check("applyCorrections turns Komitat yapalım into Commit at yapalım", applied == "Commit at yapalım")
    check("apply reports 1 firing for the split pair", pairs.count == 1)
}

do {
    // Case preservation: a capitalized wrong-side occurrence should capitalize just the first
    // word of the two-word replacement (matchCase's existing contract).
    let pair = CorrectionEngine.LearnedPair(wrong: "komitat", right: "commit at")
    let (applied, _) = CorrectionEngine.applyCorrections(to: "Komitat gönder", pairs: [pair])
    check("capitalized split occurrence capitalizes first replacement word", applied.hasPrefix("Commit at"))
}

do {
    // Blacklist protection MUST still apply to a split's wrong side (single standalone word) —
    // unlike a merge, a split's "wrong" is a real standalone occurrence of that word, so a
    // blacklisted word must never be learnable as the wrong side of a split.
    let accepted = CorrectionEngine.accept(CorrectionEngine.RawSubstitution(wrong: "çete", right: "çe te"))
    check("blacklisted word rejected as a split's wrong side", accepted == nil)
}

do {
    // Suffixed form of a learned split root ("Komitatı") with allowSuffixMatching opted in.
    // Without the multi-word-right guard, this would glue the "ı" tail onto only the LAST
    // word of the replacement ("Commit atı" — a nonsense inflection). The guard added to
    // applyCorrections' suffix-chain pass blocks split pairs (right side > 1 word) from that
    // path entirely, so this must NOT fire — it falls through unchanged.
    let pair = CorrectionEngine.LearnedPair(wrong: "komitat", right: "commit at", allowSuffixMatching: true)
    let (applied, firings) = CorrectionEngine.applyCorrections(to: "Komitatı gönder", pairs: [pair])
    check("suffix-chain matching is blocked for a split pair (multi-word right)", applied == "Komitatı gönder")
    check("blocked suffix-chain split reports no firing", firings.isEmpty)

    // Exact-form matching for a split pair must still work fine regardless (unaffected by the
    // multi-word-right guard, which only touches the suffix-CHAIN pass).
    let (applied2, firings2) = CorrectionEngine.applyCorrections(to: "Komitat gönder", pairs: [pair])
    check("exact-form split match still works with allowSuffixMatching=true", applied2 == "Commit at gönder")
    check("exact-form split match reports 1 firing", firings2.count == 1)
}

// MARK: - 12. SpotifyManager.extractSearchQuery — Turkish "şarkı" command residue extraction

do {
    let sm = SpotifyManager.shared
    check("'şarkıyı çal' -> empty residue (resume, not literal search)",
          sm.extractSearchQuery("şarkıyı çal").isEmpty)
    check("'şarkıyı durdur' residue is just 'durdur' (pause branch, unaffected by junk-word list)",
          sm.extractSearchQuery("şarkıyı durdur") == "durdur")
    check("'... şarkısına aç' junk word stripped: 'tarkan şarkısına aç' -> 'tarkan'",
          sm.extractSearchQuery("tarkan şarkısına aç") == "tarkan")
    check("'tarkan çal' -> 'tarkan' (step 5 search not shadowed by resume guard)",
          sm.extractSearchQuery("tarkan çal") == "tarkan")
    check("'sporda dinlemek için hareketli bir müzik aç' -> non-empty residue (mood search, not resume)",
          !sm.extractSearchQuery("sporda dinlemek için hareketli bir müzik aç").isEmpty)
    check("'müziği aç' -> empty residue (resume)",
          sm.extractSearchQuery("müziği aç").isEmpty)
}

// MARK: - 16. Manual soft-anchored diff (active-snapshot path): CorrectionEngine.softAnchorRange
//             tolerates changed surroundings without discarding the known prefix/suffix anchor;
//             automatic strict path on the same input still bails where it genuinely differs.
//
// These mirror DictationSnapshot.diffAndLearn's `manual == true` branch exactly — soft-anchor
// trim via CorrectionEngine.softAnchorRange, then the existing substitutionCandidates/accept —
// so they exercise the actual production algorithm, not a re-description of it. DictationSnapshot
// itself is AppKit/ApplicationServices-dependent and can't be linked into this harness.

func softAnchorUTF16Substring(_ text: String, _ range: Range<Int>) -> String? {
    let utf16View = text.utf16
    guard range.lowerBound >= 0, range.upperBound <= utf16View.count, range.lowerBound <= range.upperBound,
          let startU = utf16View.index(utf16View.startIndex, offsetBy: range.lowerBound, limitedBy: utf16View.endIndex),
          let endU = utf16View.index(utf16View.startIndex, offsetBy: range.upperBound, limitedBy: utf16View.endIndex),
          let start = String.Index(startU, within: text),
          let end = String.Index(endU, within: text) else {
        return nil
    }
    return String(text[start..<end])
}

func manualAccepted(pastedText: String, prefix: String, suffix: String, newFieldText: String) -> [CorrectionEngine.Candidate] {
    let range = CorrectionEngine.softAnchorRange(currentText: newFieldText, originalPrefix: prefix, originalSuffix: suffix)
    guard let trimmed = softAnchorUTF16Substring(newFieldText, range) else { return [] }
    let raws = CorrectionEngine.substitutionCandidates(
        oldWords: CorrectionEngine.words(pastedText),
        newWords: CorrectionEngine.words(trimmed)
    )
    return raws.compactMap(CorrectionEngine.accept)
}

do {
    // Realistic mid-sentence correction: OpenWhisper pasted a mishearing anchored by unrelated
    // words on both sides ("bana" before, "gönderir misin" after), and the user both fixes the
    // mishearing AND edits text OUTSIDE the pasted span (the suffix sentence gains more words) —
    // exactly the "surrounding text changed too" shape the automatic strict path bails on.
    let pastedText = "bana flagment'ı gönderir misin"
    let fieldTextAtPaste = "Merhaba, " + pastedText + ". İyi günler."
    let prefix = "Merhaba, "
    let suffix = ". İyi günler."
    let newFieldText = "Merhaba, bana fragment'ı gönderir misin. İyi günler dilerim. Ayrıca yarın görüşürüz."
    check("sanity: field text actually changed", fieldTextAtPaste != newFieldText)

    let automaticStrictPathBails = !(newFieldText.hasPrefix(prefix) && newFieldText.hasSuffix(suffix))
    check("automatic strict path bails when the suffix outside the pasted span also changed", automaticStrictPathBails)

    let accepted = manualAccepted(pastedText: pastedText, prefix: prefix, suffix: suffix, newFieldText: newFieldText)
    check("soft anchor finds the mishearing despite the edited suffix",
          accepted.contains { $0.wrong == "flagment'ı" && $0.right == "fragment'ı" })
    check("soft anchor accepts only the real mishearing, nothing spurious from the appended sentence",
          accepted.count == 1)
}

do {
    // Coordinator's concrete trace (prefix side): a single dictated word glued right onto
    // existing chat-box content — the dominant real-world shape ("Komitat", "komit", "kithuba").
    // pastedText is the WHOLE dictation here, so there is no internal anchor word at all; the
    // only anchor available is the pre-existing "şunu " the field already had before the paste.
    let pastedText = "Komitat"
    let prefix = "şunu "
    let suffix = ""
    let newFieldText = "şunu commit at"

    // In this minimal trace the prefix/suffix happen to be untouched by the user's edit, so the
    // automatic strict path's exact hasPrefix/hasSuffix guard actually succeeds here too — the
    // soft anchor's advantage over the strict guard is that it degrades gracefully once the
    // surroundings DO differ even slightly (see the tests immediately above and below this one),
    // rather than an all-or-nothing match. Recorded here rather than assumed.
    let automaticStrictPathGuardPasses = newFieldText.hasPrefix(prefix) && newFieldText.hasSuffix(suffix)
    check("this minimal trace happens to leave prefix/suffix untouched, so the strict guard also passes here",
          automaticStrictPathGuardPasses)

    let accepted = manualAccepted(pastedText: pastedText, prefix: prefix, suffix: suffix, newFieldText: newFieldText)
    check("soft anchor (prefix side): 'şunu Komitat' -> 'şunu commit at' learns Komitat -> commit at",
          accepted.contains { $0.wrong == "Komitat" && $0.right == "commit at" })
    if let candidate = accepted.first(where: { $0.wrong == "Komitat" }) {
        let (rootWrong, rootRight) = CorrectionEngine.extractRoot(wrong: candidate.wrong, right: candidate.right)
        check("root pair stores as komitat -> commit at",
              CorrectionEngine.trLower(rootWrong) == "komitat" && rootRight == "commit at")
    }
}

do {
    // Mirror of the trace above with the pre-existing content AFTER the dictation instead of
    // before it — the suffix-side anchor.
    let pastedText = "Komitat"
    let prefix = ""
    let suffix = " şunu"
    let newFieldText = "commit at şunu"

    let accepted = manualAccepted(pastedText: pastedText, prefix: prefix, suffix: suffix, newFieldText: newFieldText)
    check("soft anchor (suffix side): 'Komitat şunu' -> 'commit at şunu' learns Komitat -> commit at",
          accepted.contains { $0.wrong == "Komitat" && $0.right == "commit at" })
}

do {
    // The pre-existing surrounding text ALSO changed ("şunu " -> "bunu "), so there is NO common
    // prefix at all (mismatch at the very first character) — softAnchorRange correctly falls
    // back to the whole field as the candidate span (same as having no anchor). DOCUMENTED
    // BEHAVIOR, not a requirement: diffing the 1-word pasted text against the resulting 3-word
    // span ("bunu", "commit", "at") doesn't fit substitutionCandidates' same-count/merge/split
    // shapes, so nothing is learned from this specific combination. This is strictly better than
    // before (no bogus candidate is manufactured either), just not a full recovery — asserting
    // what actually happens rather than pretending it doesn't matter.
    let pastedText = "Komitat"
    let prefix = "şunu "
    let suffix = ""
    let newFieldText = "bunu commit at"

    let automaticStrictPathBails = !(newFieldText.hasPrefix(prefix) && newFieldText.hasSuffix(suffix))
    check("automatic strict path bails once the anchor word itself was also edited", automaticStrictPathBails)

    let accepted = manualAccepted(pastedText: pastedText, prefix: prefix, suffix: suffix, newFieldText: newFieldText)
    check("documented: soft anchor with a fully-changed prefix anchor learns nothing here (no anchor left to trim)",
          accepted.isEmpty)
}

do {
    // Word-boundary backoff: the common-prefix match ends INSIDE a word. "test" is common to
    // both "testxyz" (the original prefix) and "testqr" (the field's new leading word), but the
    // raw character-by-character match ends mid-word, right before 'q'. Naively cutting there
    // leaves a stray "qr" glued onto the replacement side — proven below to actually clear the
    // 0.6 similarity floor and get WRONGLY accepted. `wordBoundaryBackoff` must pull the cut back
    // to the start of "testqr" so the whole word stays out of the diff instead of being sliced.
    let pastedText = "flagment'ı"
    let prefix = "testxyz "
    let suffix = ""
    let newFieldText = "testqr fragment'ı"

    let naiveCut = CorrectionEngine.commonPrefixUTF16Length(newFieldText, prefix)
    check("sanity: the naive (no-backoff) common-prefix cut lands mid-word, inside 'testqr'",
          naiveCut > 0 && naiveCut < 6)
    if let naiveSlice = softAnchorUTF16Substring(newFieldText, naiveCut..<newFieldText.utf16.count) {
        let naiveRaws = CorrectionEngine.substitutionCandidates(
            oldWords: CorrectionEngine.words(pastedText),
            newWords: CorrectionEngine.words(naiveSlice)
        )
        let naiveAccepted = naiveRaws.compactMap(CorrectionEngine.accept)
        check("sanity: without word-boundary backoff this WOULD wrongly accept a stray-fragment candidate",
              naiveAccepted.contains { $0.right == "qr fragment'ı" })
    }

    check("wordBoundaryBackoff pulls the mid-word cut back to the start of 'testqr'",
          CorrectionEngine.wordBoundaryBackoff(naiveCut, in: newFieldText) == 0)

    let accepted = manualAccepted(pastedText: pastedText, prefix: prefix, suffix: suffix, newFieldText: newFieldText)
    check("word-boundary backoff: no bogus stray-fragment candidate is produced by the real path",
          !accepted.contains { $0.right == "qr fragment'ı" })
}

// MARK: - 17. 50% LCS-coverage guard (no-active-snapshot fallback in reviewCurrentDifference)

do {
    // Mirrors DictationSnapshot.reviewRetained's coverage check: at least 50% of the retained
    // pasted text's words must reappear (LCS) in the freshly-read field before diffing at all.
    let pastedText = "flagment'ı bana gönderir misin lütfen"
    let oldWords = CorrectionEngine.words(pastedText)

    // Unrelated field the user happens to have focused later — shares no real words.
    let unrelatedField = "Bugün hava çok güzel, dışarı çıkalım mı acaba"
    let unrelatedMatches = CorrectionEngine.lcsMatches(oldWords, CorrectionEngine.words(unrelatedField))
    let unrelatedCoverage = Double(unrelatedMatches.count) / Double(oldWords.count)
    check("50% LCS coverage guard rejects an unrelated field (\(String(format: "%.2f", unrelatedCoverage)) < 0.5)",
          unrelatedCoverage < 0.5)

    // A real edit of the same dictation, plus some appended chatter, keeps most of the words.
    let editedField = "fragment'ı bana gönderir misin lütfen, ayrıca teşekkürler"
    let editedMatches = CorrectionEngine.lcsMatches(oldWords, CorrectionEngine.words(editedField))
    let editedCoverage = Double(editedMatches.count) / Double(oldWords.count)
    check("50% LCS coverage guard accepts a real edit of the same dictation (\(String(format: "%.2f", editedCoverage)) >= 0.5)",
          editedCoverage >= 0.5)
}

// MARK: - 18. acceptWithReason — rejection reason for each filter class

do {
    check("acceptWithReason: ok",
          CorrectionEngine.acceptWithReason(CorrectionEngine.RawSubstitution(wrong: "flagment'ı", right: "fragment'ı")).reason == "ok")

    check("acceptWithReason: caseOrPunctuationOnly",
          CorrectionEngine.acceptWithReason(CorrectionEngine.RawSubstitution(wrong: "merhaba", right: "Merhaba")).reason == "caseOrPunctuationOnly")

    check("acceptWithReason: wordShorterThan2",
          CorrectionEngine.acceptWithReason(CorrectionEngine.RawSubstitution(wrong: "o", right: "a")).reason == "wordShorterThan2")

    check("acceptWithReason: blacklistedWrongSide",
          CorrectionEngine.acceptWithReason(CorrectionEngine.RawSubstitution(wrong: "bir", right: "bin")).reason == "blacklistedWrongSide")

    check("acceptWithReason: phraseTooLong",
          CorrectionEngine.acceptWithReason(CorrectionEngine.RawSubstitution(wrong: "arabalar yollar dükkanlar bahçeler", right: "otomobiller caddeler mağazalar parklar")).reason == "phraseTooLong")

    let lowSim = CorrectionEngine.acceptWithReason(CorrectionEngine.RawSubstitution(wrong: "Komizatsu", right: "commit at"))
    check("acceptWithReason: lowSimilarity(...)", lowSim.reason.hasPrefix("lowSimilarity("))
    check("acceptWithReason candidate is nil for every rejection reason above", lowSim.candidate == nil)

    // accept() must be byte-identical to acceptWithReason(...).candidate for every case above.
    check("accept()/acceptWithReason() agree: ok case",
          CorrectionEngine.accept(CorrectionEngine.RawSubstitution(wrong: "flagment'ı", right: "fragment'ı")) != nil)
    check("accept()/acceptWithReason() agree: blacklisted case",
          CorrectionEngine.accept(CorrectionEngine.RawSubstitution(wrong: "bir", right: "bin")) == nil)
}

// MARK: - 19. CorrectionStore.recordManualObservation — NOT exercised by this harness
//
// CorrectionStore is @MainActor and its `storageURL` points at the REAL
// ~/Library/Application Support/OpenWhisper/corrections.json — there is no test seam to
// redirect it, and this harness is plain top-level code (not main-actor-isolated, not async).
// Exercising `recordManualObservation` here would mean either fighting actor isolation from a
// script-like entry point or, worse, actually reading/mutating the current user's live learned
// corrections as a side effect of running tests. Per the task spec, this is intentionally left
// untested by Tools/main.swift; `recordManualObservation`'s logic (learningEnabled gate,
// isProtectedWrongSide guard, wrong<->right cycle guard, disabled-record guard, count = max(n+1,2)
// promotion straight to `.active`) was verified by inspection against `recordObservation`'s
// already-tested guards, which it copies verbatim, but not by an automated run here.

// MARK: - 20. Relaxed similarity floor gated on a shared word onset
//
// Whisper decodes left to right, so a misheard technical term usually keeps the START of the
// word. The plain 0.6 normalized-Levenshtein floor refuses exactly that shape on short words.
// The relaxation drops the floor to 0.4 only when the two sides share a >=3 character onset AND
// neither side is a pure prefix of the other (see `sharedOnsetLength`).
do {
    func accepted(_ wrong: String, _ right: String) -> Bool {
        CorrectionEngine.accept(CorrectionEngine.RawSubstitution(wrong: wrong, right: right)) != nil
    }
    func reason(_ wrong: String, _ right: String) -> String {
        CorrectionEngine.acceptWithReason(CorrectionEngine.RawSubstitution(wrong: wrong, right: right)).reason
    }

    // The live case that forced this rule: similarity 0.50, refused under the old 0.6 floor.
    check("onset: 'gitap' -> 'github' similarity is below the default floor",
          CorrectionEngine.normalizedSimilarity("gitap", "github") < CorrectionEngine.defaultSimilarityFloor)
    check("onset: 'gitap' -> 'github' shares a 3-char onset",
          CorrectionEngine.sharedOnsetLength("gitap", "github") == 3)
    check("onset: 'gitap' -> 'github' is now accepted", accepted("gitap", "github"))
    // Same edit as the user actually made it, with Whisper's two-word split of the term.
    check("onset: 'git ha' -> 'github' is now accepted", accepted("git ha", "github"))

    // Pure-prefix exclusion: an EXTENSION is not a mishearing. Learning it would rewrite every
    // future standalone occurrence of the short word.
    check("onset: pure prefix scores 0 ('kod' vs 'kodlama')",
          CorrectionEngine.sharedOnsetLength("kod", "kodlama") == 0)
    check("onset: pure-prefix extension stays rejected", !accepted("kod", "kodlama"))

    // The substitutions this project's logs record as harmful must not gain anything from the
    // relaxation: they share no usable onset, so they stay judged against the strict floor.
    // (Note: those cases came from PhoneticGlossaryCorrector's now-disabled fuzzy path, not from
    // the learned store — "kitaba"/"GitLab'a" scores 0.63 and would clear even the strict floor
    // if the USER typed that edit themselves. What matters here is only that the relaxation
    // does not widen the gate for them.)
    check("onset: 'kitaba' vs 'GitLab'a' share no onset",
          CorrectionEngine.sharedOnsetLength("kitaba", "GitLab'a") == 0)
    check("onset: 'kışla' vs 'pushla' share no onset",
          CorrectionEngine.sharedOnsetLength("kışla", "pushla") == 0)
    check("onset: 'kışla' -> 'pushla' stays rejected (0.33, no onset)", !accepted("kışla", "pushla"))
    check("onset: 'tekrardan' vs 'Terra'dan' share only 2 (below the 3 gate)",
          CorrectionEngine.sharedOnsetLength("tekrardan", "Terra'dan") == 2)

    // Second gate: a mishearing is roughly as long as what was said. A shared stem alone must
    // not admit a genuine rewrite. This assertion FAILED on the first implementation (onset 5,
    // similarity 0.44 — it cleared the relaxed floor) and is what forced the length-gap rule.
    check("onset: 'kitaplar' vs 'kitapçıklarımızdan' share a long onset",
          CorrectionEngine.sharedOnsetLength("kitaplar", "kitapçıklarımızdan") == 5)
    check("onset: but the length gap disqualifies the relaxation",
          abs("kitaplar".count - "kitapçıklarımızdan".count) > CorrectionEngine.maxLengthGapForRelaxedSimilarity)
    check("onset: genuine rewrite 'kitaplar' -> 'kitapçıklarımızdan' stays rejected",
          !accepted("kitaplar", "kitapçıklarımızdan"))

    // The rejection reason must stay diagnosable and name the floor that was applied.
    check("onset: strict-floor rejection reports floor 0.60",
          reason("kışla", "pushla").contains("floor 0.60"))
    check("onset: length-gap rejection reports floor 0.60 and the gap",
          reason("kitaplar", "kitapçıklarımızdan").contains("floor 0.60")
          && reason("kitaplar", "kitapçıklarımızdan").contains("lengthGap 10"))

    // Guards ahead of the similarity check are unaffected by the relaxation.
    check("onset: blacklisted wrong side still wins over a shared onset",
          reason("git", "github") == "blacklistedWrongSide")
}

print("\n\(total - failures)/\(total) passed")
if failures > 0 {
    exit(1)
}
