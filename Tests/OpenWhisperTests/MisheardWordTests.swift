import XCTest
@testable import OpenWhisper

/// Transcripts are from /tmp/openwhisper.log (25 Sep 2026).
@MainActor
final class MisheardWordTests: XCTestCase {

    func testDetectorFlagsNonWordsOnly() {
        XCTAssertEqual(MisheardWordDetector.find(in: "Hadisedüm tek tek aç.").map(\.text), ["Hadisedüm"])
        XCTAssertEqual(MisheardWordDetector.find(in: "Sesifullah").map(\.text), ["Sesifullah"])
        XCTAssertEqual(MisheardWordDetector.find(in: "Ses fülle.").map(\.text), ["fülle"])
        XCTAssertEqual(MisheardWordDetector.find(in: "Tarkan'ın Şımarık şarkısını çal").map(\.text), [])
        XCTAssertEqual(MisheardWordDetector.find(in: "I lead a company that changed the world").map(\.text), [])
        XCTAssertEqual(MisheardWordDetector.find(in: "Ses biraz kısar mısın?").map(\.text), [])
    }

    func testDetectorSkipsIgnoredWordsAndAcronyms() {
        XCTAssertEqual(MisheardWordDetector.find(in: "Sesifullah", ignoring: ["sesifullah"]).map(\.text), [])
        XCTAssertEqual(MisheardWordDetector.find(in: "XQZW çalışmıyor").map(\.text), [])
    }

    /// The model kept "yani"; the old check skipped every filler and rejected this.
    func testKeptFillerIsFaithful() {
        XCTAssertTrue(LLMCleanup.isFaithfulCleanup(
            original: "Hayır bunu ben şey için istemiyorum yani fulle gibi kelimeler için değil de",
            cleaned: "Hayır bunu ben için istemiyorum. Yani fulle gibi kelimeler için değil de."
        ))
    }

    func testMisheardWordMayBeReplacedBySimilarWords() {
        let known: (String) -> Bool = { ["sesi", "fulle", "full"].contains($0) }
        XCTAssertTrue(LLMCleanup.isFaithfulCleanup(
            original: "Sesifullah", cleaned: "Sesi fulle.", misheardWords: ["sesifullah"], isKnownWord: known
        ))
        // A split alone needs no dictionary word ("düm" isn't one).
        XCTAssertTrue(LLMCleanup.isFaithfulCleanup(
            original: "Hadisedüm tek tek aç.", cleaned: "Hadise düm tek tek aç.", misheardWords: ["hadisedüm"]
        ))
        XCTAssertTrue(LLMCleanup.isFaithfulCleanup(
            original: "Sesifullah yani çal", cleaned: "Sesi fulle çal", misheardWords: ["sesifullah"], isKnownWord: known
        ))
    }

    func testMisheardReplacementMustSoundAlikeAndBeReal() {
        // Unrelated word.
        XCTAssertFalse(LLMCleanup.isFaithfulCleanup(
            original: "Sesifullah", cleaned: "Müziği durdur", misheardWords: ["sesifullah"], isKnownWord: { _ in true }
        ))
        // Similar, but not a dictionary word.
        XCTAssertFalse(LLMCleanup.isFaithfulCleanup(
            original: "Sesifullah", cleaned: "Sesi fullex", misheardWords: ["sesifullah"], isKnownWord: { _ in false }
        ))
        // Dropping a Turkish suffix isn't a correction.
        XCTAssertFalse(LLMCleanup.isFaithfulCleanup(
            original: "Frontendi refactorla", cleaned: "Frontend refactorla",
            misheardWords: ["frontendi"], isKnownWord: { _ in true }
        ))
        // Words that weren't flagged still can't change.
        XCTAssertFalse(LLMCleanup.isFaithfulCleanup(
            original: "Bu bezire yer bulamamızı", cleaned: "Bu vezire yer bulamamızı",
            misheardWords: ["sesifullah"], isKnownWord: { _ in true }
        ))
    }

    func testCorrectedCommandUndoesOnlyWhatWouldStack() {
        let search = SpotifyManager.ExplicitSpotifyIntent.search(.freeText("hadise"))
        XCTAssertFalse(SpotifyManager.correctionNeedsUndo(of: search, before: .search(.freeText("hadise düm tek tek"))))
        XCTAssertFalse(SpotifyManager.correctionNeedsUndo(of: .setVolume(40), before: .setVolume(100)))
        XCTAssertFalse(SpotifyManager.correctionNeedsUndo(of: .adjustVolume(-10), before: .setVolume(100)))
        XCTAssertTrue(SpotifyManager.correctionNeedsUndo(of: .adjustVolume(-10), before: .adjustVolume(20)))
        XCTAssertTrue(SpotifyManager.correctionNeedsUndo(of: .next, before: .previous))
        XCTAssertTrue(SpotifyManager.correctionNeedsUndo(of: search, before: .pause))
        XCTAssertTrue(SpotifyManager.correctionNeedsUndo(of: .setVolume(40), before: .adjustVolume(10)))
    }
}
