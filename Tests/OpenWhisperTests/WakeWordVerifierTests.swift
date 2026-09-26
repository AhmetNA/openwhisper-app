import XCTest
@testable import OpenWhisper

final class WakeWordVerifierTests: XCTestCase {
    func testWhisperSpellingsOfJarvisMatch() {
        for text in ["Jarvis.", "Cervis", "Carvis?", "Jarvıs", "Çarvis", "Jervis", "Jarviz", "Car vis",
                     "Jarvis'e bir şey sorayım", "Hey Jarvis, şarkıyı durdur"] {
            XCTAssertTrue(WakeWordVerifier.containsWakeWord(text), text)
        }
    }

    func testOtherWordsDoNotMatch() {
        for text in ["", "Servis geldi mi", "Harvey", "Çarşı", "Jarse", "Bugün hava güzel"] {
            XCTAssertFalse(WakeWordVerifier.containsWakeWord(text), text)
        }
    }

    func testBareCallNeedsNoLLM() {
        XCTAssertTrue(WakeWordVerifier.isBareCall("Jarvis."))
        XCTAssertTrue(WakeWordVerifier.isBareCall("Hey, Cervis!"))
        XCTAssertTrue(WakeWordVerifier.isBareCall("Selam Jarvis."))
        XCTAssertTrue(WakeWordVerifier.isBareCall("Merhaba, Carvis!"))
        XCTAssertTrue(WakeWordVerifier.isBareCall("Günaydın Jarvis"))
        XCTAssertFalse(WakeWordVerifier.isBareCall("Selam Jarvis sesi kıs"))
        XCTAssertFalse(WakeWordVerifier.isBareCall("Jarvis şarkıyı durdur"))
        XCTAssertFalse(WakeWordVerifier.isBareCall("I am Jarvis tonight"))
    }

    func testNormalizationLiftsQuietAudioWithCap() {
        let quiet = [Float](repeating: 0.01, count: 10)
        XCTAssertEqual(WakeWordListener.normalizedForWhisper(quiet).first!, 0.3, accuracy: 1e-6)
        let loud = [Float](repeating: 0.25, count: 10)
        XCTAssertEqual(WakeWordListener.normalizedForWhisper(loud).first!, 0.5, accuracy: 1e-6)
    }
}
