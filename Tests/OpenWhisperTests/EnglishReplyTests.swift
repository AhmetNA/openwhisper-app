import XCTest
@testable import OpenWhisper

/// Records what it was asked to read and answers at once with a short clip.
@MainActor
private final class RecordingProvider: SpeechSynthesisProvider {
    let displayName: String
    let cacheIdentity: String
    let replyLanguage: ReplyLanguage
    let isReady = true
    let notReadyReason = ""
    let prefetchesAcks = false
    var spoken: [String] = []

    init(_ name: String, language: ReplyLanguage) {
        displayName = name
        cacheIdentity = "\(name)|test"
        replyLanguage = language
    }

    func prepare() async {}
    func synthesize(_ text: String) async throws -> Data {
        spoken.append(text)
        return SpeechSynthesisProviderTests.wav(seconds: 0.05)
    }
}

final class EnglishReplyTests: XCTestCase {
    private var cache: URL!
    private var suiteName = ""

    override func setUp() {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suiteName = "EnglishReplyTests.\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cache)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private var cachedClips: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).count
    }

    @MainActor
    private func makeVoice(_ provider: RecordingProvider) -> JarvisVoice {
        let store = SpeechSettingsStore(defaults: UserDefaults(suiteName: suiteName)!, secrets: KeychainSecretStore(service: "test.\(suiteName)"))
        return JarvisVoice(settings: store, provider: provider, cacheDirectory: cache)
    }

    // MARK: Fixed phrases and language

    func testEveryAckHasAFixedEnglishFormWithAndWithoutAddress() {
        for phrase in JarvisReply.acks + JarvisReply.fixedPhrases {
            let english = ReplyTranslator.fixedEnglish(phrase)
            XCTAssertNotNil(english, phrase)
            let body = String(phrase.dropLast())
            for who in JarvisReply.addresses {
                XCTAssertEqual(ReplyTranslator.fixedEnglish("\(body), \(who)."), english.map { "\($0.dropLast()), sir." }, who)
            }
        }
        XCTAssertEqual(ReplyTranslator.fixedEnglish("Tamamdır, patron."), "Right away, sir.")
        XCTAssertNil(ReplyTranslator.fixedEnglish("Saat 14:05, patron."))
    }

    func testOnlyClearlyEnglishSentencesSkipTranslation() {
        let turkish = JarvisReply.acks + JarvisReply.fixedPhrases + JarvisVoice.testSentences + [
            "Okay patron.", "Spotify'da Daft Punk çalıyorum.", "Pil %87, şarj oluyor.", "Saat 14:05.",
            "Mail bulunamadı", "Daft Punk çalıyor.",
        ]
        for sentence in turkish {
            XCTAssertFalse(ReplyTranslator.isClearlyEnglish(sentence), sentence)
        }
        for sentence in JarvisVoice.englishTestSentences.dropFirst() + ["I'm sorry, I didn't catch that.", "Playing Daft Punk now."] {
            XCTAssertTrue(ReplyTranslator.isClearlyEnglish(sentence), sentence)
        }
    }

    func testModelAnswerIsCleanedOrRejected() {
        XCTAssertEqual(ReplyTranslator.cleaned("\"It is 2:05, sir.\"", source: "Saat 14:05, patron."), "It is 2:05, sir.")
        XCTAssertEqual(ReplyTranslator.cleaned("Here is the translation: Noted.\n", source: "Not ettim."), "Noted.")
        XCTAssertNil(ReplyTranslator.cleaned("  ", source: "Tamam."))
        XCTAssertNil(ReplyTranslator.cleaned(String(repeating: "word ", count: 40), source: "Oldu."))
    }

    func testClockTimesAreSpokenInWords() {
        XCTAssertEqual(ReplyTranslator.spokenTimes("It is 2:05 PM, sir."), "It is two oh five PM, sir.")
        XCTAssertEqual(ReplyTranslator.spokenTimes("At 14:30 and 9:00."), "At fourteen thirty and nine o'clock.")
        XCTAssertEqual(ReplyTranslator.spokenTimes("Battery is at 87%."), "Battery is at 87%.")
    }

    // MARK: English voice

    @MainActor
    func testEnglishVoiceReadsAcksFromTheTableAndCachesThem() async {
        let piper = RecordingProvider("piper", language: .english)
        let voice = makeVoice(piper)
        var asked: [String] = []
        voice.translator = { asked.append($0); return "unused" }
        let heard = await voice.speak("Tamamdır, patron.")
        XCTAssertTrue(heard)
        XCTAssertEqual(piper.spoken, ["Right away, sir."])
        XCTAssertEqual(asked, [])
        XCTAssertEqual(cachedClips, 1)
    }

    @MainActor
    func testEnglishVoiceTranslatesStatusWithItsDigitsAndDoesNotCacheIt() async {
        let piper = RecordingProvider("piper", language: .english)
        let voice = makeVoice(piper)
        var asked: [String] = []
        voice.translator = { asked.append($0); return "Battery is at 87%." }
        _ = await voice.speak("Pil yüzde seksen.")
        XCTAssertEqual(asked, ["Pil yüzde seksen."])
        XCTAssertEqual(piper.spoken, ["Battery is at 87%."])
        XCTAssertEqual(cachedClips, 0, "a model's translation may vary, so it isn't cached")

        asked = []
        voice.translator = { asked.append($0); return "It is 14:05." }
        _ = await voice.speak("Saat 14:05.")
        XCTAssertEqual(asked, ["Saat 14:05."], "digits reach the translator as digits, not Turkish words")
        XCTAssertEqual(piper.spoken.last, "It is fourteen oh five.")
    }

    @MainActor
    func testEnglishChatSentencePassesUnchanged() async {
        let piper = RecordingProvider("piper", language: .english)
        let voice = makeVoice(piper)
        var asked = 0
        voice.translator = { _ in asked += 1; return nil }
        _ = await voice.speak("I'm sorry, I didn't catch that.")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(piper.spoken, ["I'm sorry, I didn't catch that."])
    }

    @MainActor
    func testWithoutTranslationTheTurkishFallbackReadsItAndNothingIsCached() async {
        let piper = RecordingProvider("piper", language: .english)
        let pocket = RecordingProvider("pocket", language: .turkish)
        let voice = makeVoice(piper)
        voice.translator = { _ in nil }
        voice.turkishFallback = { pocket }
        let heard = await voice.speak("Bunu anlayamadım.")
        XCTAssertTrue(heard)
        XCTAssertEqual(piper.spoken, [])
        XCTAssertEqual(pocket.spoken, ["Bunu anlayamadım."])
        XCTAssertEqual(cachedClips, 0)
    }

    @MainActor
    func testTurkishVoiceNeverTranslates() async {
        let pocket = RecordingProvider("pocket", language: .turkish)
        let voice = makeVoice(pocket)
        var asked = 0
        voice.translator = { _ in asked += 1; return "x" }
        _ = await voice.speak("Saat 14:05, patron.")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(pocket.spoken, ["Saat on dört sıfır beş, patron."])
    }

    // MARK: Registry and chat

    @MainActor
    func testPiperJarvisIsAnEnglishOptionAndPocketStaysTheTurkishDefault() {
        let piper = SpeechProviders.descriptor(for: "piper")
        XCTAssertEqual(piper.id, "piper")
        XCTAssertFalse(piper.needsAPIKey)
        XCTAssertEqual(LocalPiperJarvisProvider.shared.replyLanguage, .english)
        XCTAssertEqual(LocalPocketTTSProvider.shared.replyLanguage, .turkish)
        XCTAssertEqual(SpeechProviders.defaultID, "pocket")
        let ports = [LocalPocketTTSProvider.port, LocalPiperJarvisProvider.port, LocalEMALightningProvider.port]
        XCTAssertEqual(Set(ports).count, ports.count)
        XCTAssertNotEqual(LocalPiperJarvisProvider.shared.cacheIdentity, LocalPocketTTSProvider.shared.cacheIdentity)
    }

    func testChatAnswersInEnglishForAnEnglishVoice() {
        let now = Date()
        let english = JarvisChat.systemPrompt(now: now, language: .english)
        let turkish = JarvisChat.systemPrompt(now: now, language: .turkish)
        XCTAssertTrue(english.contains("Her zaman İngilizce cevap ver"))
        XCTAssertFalse(turkish.contains("Her zaman İngilizce cevap ver"))
        XCTAssertTrue(turkish.contains("hangi dilde konuştuysa"))
        // The fixed Turkish sentence stays in both, so the exact-match guard keeps working.
        XCTAssertTrue(english.contains(JarvisChat.unrecognizedCommandReply))
        XCTAssertTrue(turkish.contains(JarvisChat.unrecognizedCommandReply))
    }
}
