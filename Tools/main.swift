import Foundation

// Standalone verification harness for CorrectionEngine — NOT part of the app target
// (kept outside OpenWhisper/ so SwiftPM never compiles it into the executable).
// Run with:
//   swiftc Tools/CorrectionEngineHarness.swift OpenWhisper/Core/CorrectionEngine.swift -o /tmp/ce_harness && /tmp/ce_harness

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

// MARK: - 11. TurkishDateParser — relative date/time parsing for voice reminders

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

print("\n\(total - failures)/\(total) passed")
if failures > 0 {
    exit(1)
}

