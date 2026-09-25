import XCTest
@testable import OpenWhisper

/// Transcripts taken from real recordings (Recordings/<id>.log, 25 Sep 2026).
final class WhisperHallucinationTests: XCTestCase {
    private let aboneLoop = Array(repeating: "abone ol", count: 70).joined(separator: " ")

    func testTwoWordLoopCollapsesAndIsDropped() {
        XCTAssertEqual(AudioSegmentation.collapseRepetitionLoops(aboneLoop), "abone ol")
        XCTAssertTrue(AudioSegmentation.isKnownHallucination(aboneLoop))
        XCTAssertTrue(AudioSegmentation.isRepetitionHallucination(aboneLoop))
    }

    func testYouTubeOutrosAreDropped() {
        for text in ["İzlediğiniz için teşekkürler.", "Abone olun!", "Bir sonraki videoda görüşmek üzere.",
                     "izlediğiniz için teşekkür ederim", "Altyazı M.K."] {
            XCTAssertTrue(AudioSegmentation.isKnownHallucination(text), text)
        }
    }

    func testRealDictationQuotingThePhraseIsKept() {
        // The user's own message: three repeats are real speech and must survive untouched.
        let text = "son 2-3 şeyimize bakabilir misin konuşmamızda yani benim sesli komutuma orada bir sürü abone ol abone ol abone ol yazmış ama kayıtta ses kaydında böyle bir şey yok sorunu bul ve çöz"
        XCTAssertEqual(AudioSegmentation.collapseRepetitionLoops(text), text)
        XCTAssertFalse(AudioSegmentation.isKnownHallucination(text))
        XCTAssertFalse(AudioSegmentation.isRepetitionHallucination(text))
    }

    func testOutroInsideRealSentenceIsKept() {
        for text in ["kanala abone ol butonuna bas", "izlediğiniz için teşekkürler diye bitir videoyu",
                     "beğenilen şarkıları aç", "Eğlenceli bir şeyler çal."] {
            XCTAssertFalse(AudioSegmentation.isKnownHallucination(text), text)
            XCTAssertEqual(AudioSegmentation.collapseRepetitionLoops(text), text)
        }
    }

    func testLoopAfterRealSpeechKeepsTheSpeech() {
        let text = "yarın toplantı var " + Array(repeating: "teşekkürler.", count: 12).joined(separator: " ")
        XCTAssertEqual(AudioSegmentation.collapseRepetitionLoops(text), "yarın toplantı var teşekkürler.")
    }

    func testSingleWordLoopStillDetected() {
        XCTAssertTrue(AudioSegmentation.isRepetitionHallucination("Bu Bu Bu Bu Bu Bu"))
    }

    func testThreeWordLoop() {
        let text = Array(repeating: "hadi bakalım gel", count: 5).joined(separator: " ")
        XCTAssertEqual(AudioSegmentation.collapseRepetitionLoops(text), "hadi bakalım gel")
    }
}

final class WhisperTrailingOutroTests: XCTestCase {
    func testOutroAtTheEndIsRemoved() {
        XCTAssertEqual(AudioSegmentation.removeTrailingOutros("yarın toplantı var. Abone olun."), "yarın toplantı var.")
        XCTAssertEqual(AudioSegmentation.removeTrailingOutros("bu akşam yemeğe çıkalım mı? İzlediğiniz için teşekkürler."),
                       "bu akşam yemeğe çıkalım mı?")
        XCTAssertEqual(AudioSegmentation.removeTrailingOutros("raporu cuma bitirelim, abone ol"), "raporu cuma bitirelim")
    }

    func testStackedOutrosAreAllRemoved() {
        XCTAssertEqual(
            AudioSegmentation.removeTrailingOutros("dosyayı gönderdim. Abone olun. İzlediğiniz için teşekkürler."),
            "dosyayı gönderdim."
        )
    }

    func testCollapsedLoopAtTheEndIsRemoved() {
        let text = "yarın geliyorum " + Array(repeating: "abone ol", count: 20).joined(separator: " ")
        XCTAssertEqual(AudioSegmentation.removeTrailingOutros(AudioSegmentation.collapseRepetitionLoops(text)), "yarın geliyorum")
    }

    func testOutroOnlyTranscriptIsLeftForTheDropCheck() {
        XCTAssertEqual(AudioSegmentation.removeTrailingOutros("Abone olun."), "Abone olun.")
    }

    func testOutroInTheMiddleOrStartIsKept() {
        for text in ["abone ol butonuna bas", "kanala abone olun demiştim ona",
                     "sesli komutuma abone ol abone ol abone ol yazmış ama sorunu bul ve çöz",
                     "Eğlenceli bir şeyler çal."] {
            XCTAssertEqual(AudioSegmentation.removeTrailingOutros(text), text, text)
        }
    }
}
