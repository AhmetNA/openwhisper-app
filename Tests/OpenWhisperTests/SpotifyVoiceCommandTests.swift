import XCTest
@testable import OpenWhisper

/// Voice-started sessions ("Jarvis"): real transcripts from the log, with gemma4's actual
/// answers, so a wake-word command isn't pasted into the frontmost app as dictation.
final class SpotifyVoiceCommandTests: XCTestCase {
    private typealias Parse = SpotifyRequestParser.OllamaParse
    private let moodParse = Parse(intent: .search, kind: .playlist, title: "eğlenceli bir şeyler", artist: "")

    private func decide(_ transcript: String, _ parse: Parse, commandMode: Bool) -> SpotifyManager.ExplicitSpotifyIntent? {
        let text = SpotifyManager.repairPlayVerbMishearing(transcript)
        return SpotifyManager.decide(
            rules: SpotifyManager.explicitIntent(in: text), parse: parse, text: text, commandMode: commandMode
        )
    }

    func testMoodRequestPlaysAPlaylistInCommandMode() {
        for transcript in ["Eğlenceli bir şeyler çal.", "Eğlenceli bir şeyler çalk."] {
            guard case .search(let request)? = decide(transcript, moodParse, commandMode: true) else {
                return XCTFail("expected a playlist search for '\(transcript)'")
            }
            XCTAssertEqual(request.kind, .playlist)
            XCTAssertTrue(SpotifyManager.isCommandCandidate(transcript))
        }
    }

    func testDictationKeepsTheStrictGate() {
        XCTAssertNil(decide("Eğlenceli bir şeyler çal.", moodParse, commandMode: false))
        XCTAssertNil(decide("Eğlenceli bir şeyler çalk.", moodParse, commandMode: false))
    }

    func testCommandModeStillNeedsEvidenceInTheWords() {
        // Ollama's label alone never plays music: no play verb, no search.
        XCTAssertNil(decide("Bu şarkıyı çok seviyorum", moodParse, commandMode: true))
        XCTAssertNil(decide("Yarın toplantı var", Parse(intent: .none), commandMode: true))
    }

    func testCommandModeSkipsWithoutSpotifyPlayingCheck() {
        XCTAssertEqual(decide("Bu şarkıdan sıkıldım", Parse(intent: .next), commandMode: true), .next)
    }

    func testPlayVerbRepairOnlyTouchesTheClosingWord() {
        XCTAssertEqual(SpotifyManager.repairPlayVerbMishearing("Eğlenceli bir şeyler çalk."), "Eğlenceli bir şeyler çal.")
        XCTAssertEqual(SpotifyManager.repairPlayVerbMishearing("çalkala bunu"), "çalkala bunu")
        XCTAssertEqual(SpotifyManager.repairPlayVerbMishearing("Kod çalışıyor"), "Kod çalışıyor")
    }

    func testRepeatedWordHallucinationIsDetected() {
        XCTAssertTrue(AudioSegmentation.isRepetitionHallucination("Bu Bu Bu Bu Bu Bu"))
        XCTAssertFalse(AudioSegmentation.isRepetitionHallucination("Hayır hayır"))
        XCTAssertFalse(AudioSegmentation.isRepetitionHallucination("evet evet evet tamam"))
    }
}
