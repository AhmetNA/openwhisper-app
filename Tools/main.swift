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

print("\n\(total - failures)/\(total) passed")
if failures > 0 {
    exit(1)
}

