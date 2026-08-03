import XCTest
@testable import OpenWhisper

final class SpotifyIntentRegressionTests: XCTestCase {
    func testOrdinaryDictationDoesNotBecomeSpotifyIntentWithoutOllama() async {
        let ordinaryDictation = [
            "Bu şarkı çok güzel",
            "Spotify komutu istemiyorum",
            "Şarkı aç gibi şeyler demiyorum",
            "Şu anda benim sesimi anlıyor musun?",
            "Sesimi anlıyor musun?",
            "Sesim geliyor mu? 3-2-1",
            "Ses 123, ses kontrol.",
            "Bu projede müzik bölümünü yarın konuşalım",
            "Müziği aç gibi bir şey dedi",
            "Sakın müziği aç",
            "Sonraki şarkı çok güzel",
            "Bu sistem ne çalıyor acaba?",
        ]

        for transcript in ordinaryDictation {
            let detected = await SpotifyManager.isSpotifyCommand(
                transcript,
                ollamaAvailable: false
            )
            XCTAssertFalse(detected, "Ordinary dictation was routed to Spotify: \(transcript)")
        }
    }

    func testExplicitSpotifyActionsRemainRecognizedWithoutOllama() async {
        let explicitCommands = [
            "Spotify'da Tarkan çal",
            "Müziği durdur",
            "Sonraki şarkıya geç",
            "Spotify sesini yüzde 40 yap",
            "Şu an hangi şarkı çalıyor",
            "Şu an çalan şarkı ne?",
            "Şu an çalan parça ne?",
        ]

        for transcript in explicitCommands {
            let detected = await SpotifyManager.isSpotifyCommand(
                transcript,
                ollamaAvailable: false
            )
            XCTAssertTrue(detected, "Explicit Spotify action was not recognized: \(transcript)")
        }
    }
}
