import XCTest
@testable import OpenWhisper

/// Bugs from the recording logs of 10–14 Oct 2026.
final class LogFixRegressionTests: XCTestCase {
    private typealias Parse = SpotifyRequestParser.OllamaParse

    private func command(_ heard: String, _ parse: Parse) -> SpotifyManager.ExplicitSpotifyIntent? {
        let text = SpotifyManager.commandModeText(heard)
        return SpotifyManager.decide(
            rules: SpotifyManager.explicitIntent(in: text), parse: parse, text: text, commandMode: true
        )
    }

    // MARK: Volume

    func testMaxVolumePhrasingsSetTheVolume() {
        // Ollama answered "volume" for both; the route stayed "dictation".
        XCTAssertEqual(command("Sesi sona getir.", Parse(intent: .volume)), .setVolume(100))
        XCTAssertEqual(command("Hey Javis, sesi son seviyeye çıkar.", Parse(intent: .volume)), .setVolume(100))
        XCTAssertEqual(command("Hey Jarvis sesi sonuna kadar aç", Parse(intent: .volume)), .setVolume(100))
        // Outside a voice session too, as natural phrasing.
        XCTAssertEqual(
            SpotifyManager.decide(rules: nil, parse: Parse(intent: .volume), text: "Sesi sona getir."),
            .setVolume(100)
        )
    }

    func testMaxVolumePhrasingNeedsAVolumeNoun() {
        XCTAssertNil(command("Listeyi sona getir", Parse(intent: .volume)))
        XCTAssertNil(command("Son seviyeye çıkar", Parse(intent: .volume)))
        // A lowering verb is never max.
        XCTAssertNil(command("Sesi son seviyeye indir", Parse(intent: .volume)))
    }

    func testLeadingWakeWordIsDroppedFromCommands() {
        XCTAssertEqual(SpotifyManager.commandModeText("Hey Javis, sesi son seviyeye çıkar."), "Sesi son seviyeye çıkar.")
        XCTAssertEqual(SpotifyManager.commandModeText("Jarvis'e sesi aç dedim"), "Jarvis'e sesi aç dedim")
    }

    // MARK: Sound-alike names

    func testSoundAlikeLeavesEverydayWordsAlone() {
        let entries = SoundAlikeCorrector.parse(SoundAlikeCorrector.defaultFile)
        let text = "Dosyalar bulutta varsa bulut varsa"
        XCTAssertEqual(SoundAlikeCorrector.correct(text, entries: entries).0, text)
        // Listed variants still fix.
        XCTAssertEqual(SoundAlikeCorrector.correct("vatsapı aç", entries: entries).0, "WhatsApp'ı aç")
    }

    // MARK: Phonetic glossary

    func testGlossaryLeavesOrdinaryLowercaseTermsAlone() {
        let terms = ["model", "GitHub", "push"]
        XCTAssertEqual(PhoneticGlossaryCorrector.correct("Bu modeli kullan", terms: terms).result, "Bu modeli kullan")
        XCTAssertEqual(PhoneticGlossaryCorrector.correct("githuba at", terms: terms).result, "GitHub'a at")
        XCTAssertEqual(PhoneticGlossaryCorrector.correct("puşla", terms: terms).result, "push'la")
    }

    // MARK: Percent sign

    func testPercentIsSpacedFromThePreviousWord() {
        XCTAssertEqual(TranscriptSanitizer.removeForbiddenArtifacts(from: "Bunun%20 kadar"), "Bunun %20 kadar")
        XCTAssertEqual(TranscriptSanitizer.removeForbiddenArtifacts(from: "Jarvis%80 yap"), "Jarvis %80 yap")
        XCTAssertEqual(TranscriptSanitizer.removeForbiddenArtifacts(from: "sesi %30 yap"), "sesi %30 yap")
        XCTAssertEqual(TranscriptSanitizer.removeForbiddenArtifacts(from: "100% emin"), "100% emin")
    }

    // MARK: Misheard words

    @MainActor
    func testTurkishSuffixesOnEnglishWordsAreNotMisheard() {
        XCTAssertEqual(MisheardWordDetector.find(
            in: "Bu son kayıtları logları incele, o loglar üzerinden fullscreen'de aç"
        ).map(\.text), [])
        // Still caught.
        XCTAssertEqual(MisheardWordDetector.find(in: "Sesifullah").map(\.text), ["Sesifullah"])
        XCTAssertEqual(MisheardWordDetector.find(in: "Sputfay'da aç").map(\.text), ["Sputfay'da"])
    }

    // MARK: Unidentified speaker in a held-key dictation

    func testHeldKeyDictationKeepsSpeechWhenNoSpeakerIsIdentified() {
        let notIdentified = TargetSpeakerDiarizationError.targetSpeakerNotIdentified(bestScore: 0.59)
        for trigger: RecordingTrigger in [.fnHold, .fnSpace, .keyboardShortcut] {
            XCTAssertTrue(TargetSpeakerOutputGate.keepsUnidentifiedSpeech(trigger: trigger, error: notIdentified))
        }
        for trigger: RecordingTrigger in [.wakeWord, .followUp, .jarvisKey, .confirmation, .external, .typed] {
            XCTAssertFalse(TargetSpeakerOutputGate.keepsUnidentifiedSpeech(trigger: trigger, error: notIdentified))
        }
        // Any other diarization error keeps the masked-audio safety path.
        XCTAssertFalse(TargetSpeakerOutputGate.keepsUnidentifiedSpeech(
            trigger: .fnHold, error: TargetSpeakerDiarizationError.incompatibleProfile(expected: "a", actual: "b")
        ))
    }

    // MARK: Lock screen and follow-up

    @MainActor
    func testGarbledTextOnTheLockScreenGetsNoChat() {
        let garbled = MisheardWordDetector.find(in: "Siz se sonhalen.").count
        XCTAssertGreaterThan(garbled, 0)
        XCTAssertTrue(JarvisAddressee.skipsChat(frontBundleID: "com.apple.loginwindow", misheardWordCount: garbled))
        XCTAssertFalse(JarvisAddressee.skipsChat(frontBundleID: "com.apple.loginwindow", misheardWordCount: 0))
        XCTAssertFalse(JarvisAddressee.skipsChat(frontBundleID: "com.apple.finder", misheardWordCount: garbled))
    }

    func testFollowUpThatHeardOnlyOthersKeepsNoCandidate() {
        XCTAssertFalse(TargetSpeakerOutputGate.retainsRejectedCandidate(trigger: .followUp, hadSingleSpeakerUncertain: false))
        XCTAssertTrue(TargetSpeakerOutputGate.retainsRejectedCandidate(trigger: .followUp, hadSingleSpeakerUncertain: true))
        XCTAssertTrue(TargetSpeakerOutputGate.retainsRejectedCandidate(trigger: .wakeWord, hadSingleSpeakerUncertain: false))
    }

    // MARK: LLM cleanup swap

    func testCleanupThatChangesNothingVisibleIsNotSwapped() {
        XCTAssertTrue(LLMCleanup.isNoOpCleanup(original: "Sesi sona getir", cleaned: "Sesi sona getir."))
        XCTAssertTrue(LLMCleanup.isNoOpCleanup(original: "Tarkan’ın  şarkısı , güzel", cleaned: "Tarkan'ın şarkısı, güzel"))
        XCTAssertFalse(LLMCleanup.isNoOpCleanup(original: "istemiyorum yani", cleaned: "istemiyorum. Yani"))
        XCTAssertFalse(LLMCleanup.isNoOpCleanup(original: "sesi sona getir", cleaned: "Sesi sona getir"))
        XCTAssertFalse(LLMCleanup.isNoOpCleanup(original: "Sesifullah", cleaned: "Sesi fulle"))
    }
}
