import AVFoundation
import CryptoKit
import XCTest
@testable import OpenWhisper

private final class MemorySecretStore: SecretStore {
    var values: [String: String] = [:]
    var failWrites = false
    func read(account: String) -> String? { values[account] }
    func write(_ value: String, account: String) -> Bool {
        guard !failWrites else { return false }
        values[account] = value
        return true
    }
    func delete(account: String) -> Bool { values[account] = nil; return true }
}

/// Synthesis hangs until the test releases it, like a slow API call.
@MainActor
private final class SlowProvider: SpeechSynthesisProvider {
    let displayName = "Slow"
    let cacheIdentity = "slow|test"
    let isReady = true
    let notReadyReason = ""
    let prefetchesAcks = false
    var requests = 0
    var suspended = 0
    var failure: SpeechSynthesisError?
    func suspend() { suspended += 1 }
    private var release: CheckedContinuation<Void, Never>?

    func prepare() async {}
    func synthesize(_ text: String) async throws -> Data {
        requests += 1
        if let failure { throw failure }
        await withCheckedContinuation { release = $0 }
        return SpeechSynthesisProviderTests.wav(seconds: 0.2)
    }
    func finish() { release?.resume(); release = nil }
    var waiting: Bool { release != nil }
}

final class SpeechSynthesisProviderTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var secrets: MemorySecretStore!
    private var store: SpeechSettingsStore!

    override func setUp() {
        suiteName = "SpeechSynthesisProviderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        secrets = MemorySecretStore()
        store = SpeechSettingsStore(defaults: defaults, secrets: secrets)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: Registry and settings

    func testDefaultsToLocalOmniVoice() {
        XCTAssertEqual(store.providerID, "local")
        XCTAssertEqual(store.modelID(for: "local"), LocalOmniVoiceProvider.voiceModel)
        XCTAssertEqual(store.modelID(for: "gemini"), "gemini-3.8-flash-lite-tts")
    }

    func testRegistryListsBothProvidersWithGeminiModels() {
        XCTAssertEqual(SpeechProviders.all.map(\.id), ["local", "gemini"])
        XCTAssertEqual(SpeechProviders.descriptor(for: "gemini").models.map(\.id),
                       ["gemini-3.8-flash-lite-tts", "gemini-3.8-flash-tts"])
        XCTAssertFalse(SpeechProviders.descriptor(for: "local").needsAPIKey)
        XCTAssertTrue(SpeechProviders.descriptor(for: "gemini").needsAPIKey)
    }

    func testProviderAndModelSurviveARestart() {
        store.providerID = "gemini"
        store.setModelID("gemini-3.8-flash-tts", for: "gemini")
        let reopened = SpeechSettingsStore(defaults: UserDefaults(suiteName: suiteName)!, secrets: secrets)
        XCTAssertEqual(reopened.providerID, "gemini")
        XCTAssertEqual(reopened.modelID(for: "gemini"), "gemini-3.8-flash-tts")
    }

    func testUnknownStoredValuesFallBackToDefaults() {
        defaults.set("elevenlabs", forKey: SpeechSettingsStore.providerKey)
        defaults.set("gemini-1-tts", forKey: SpeechSettingsStore.modelKey(for: "gemini"))
        XCTAssertEqual(store.providerID, "local")
        XCTAssertEqual(store.modelID(for: "gemini"), "gemini-3.8-flash-lite-tts")
    }

    func testAPIKeyGoesToTheSecretStoreOnly() {
        XCTAssertFalse(store.hasAPIKey(for: "gemini"))
        XCTAssertTrue(store.saveAPIKey("  test-key-123 \n", for: "gemini"))
        XCTAssertEqual(store.apiKey(for: "gemini"), "test-key-123")
        let persisted = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        XCTAssertFalse(persisted.contains { $0.contains("test-key-123") })
        XCTAssertTrue(store.deleteAPIKey(for: "gemini"))
        XCTAssertFalse(store.hasAPIKey(for: "gemini"))
    }

    func testFailedKeychainWriteIsReported() {
        secrets.failWrites = true
        XCTAssertFalse(store.saveAPIKey("k", for: "gemini"))
        XCTAssertFalse(store.saveAPIKey("   ", for: "gemini"))
    }

    func testKeychainRoundTrip() throws {
        let keychain = KeychainSecretStore(service: "com.openwhisper.app.tts.tests.\(UUID().uuidString)")
        guard keychain.write("secret-value", account: "gemini.api_key") else {
            throw XCTSkip("Keychain not writable in this environment")
        }
        defer { _ = keychain.delete(account: "gemini.api_key") }
        XCTAssertEqual(keychain.read(account: "gemini.api_key"), "secret-value")
        XCTAssertTrue(keychain.write("rotated", account: "gemini.api_key"))
        XCTAssertEqual(keychain.read(account: "gemini.api_key"), "rotated")
        XCTAssertTrue(keychain.delete(account: "gemini.api_key"))
        XCTAssertNil(keychain.read(account: "gemini.api_key"))
    }

    @MainActor
    func testGeminiIsNotReadyWithoutKey() async {
        store.providerID = "gemini"
        let provider = store.makeProvider()
        XCTAssertFalse(provider.isReady)
        do {
            _ = try await provider.synthesize("Tamam.")
            XCTFail("should not reach the network without a key")
        } catch {
            XCTAssertEqual(error as? SpeechSynthesisError, .notReady("Gemini API key missing"))
        }
        store.saveAPIKey("k", for: "gemini")
        XCTAssertTrue(provider.isReady)
    }

    // MARK: Cache isolation

    @MainActor
    func testCacheIdentityDiffersByProviderModelAndVoice() {
        let gemini = SpeechProviders.descriptor(for: "gemini")
        let lite = GeminiSpeechProvider(model: gemini.models[0], apiKey: { nil })
        let flash = GeminiSpeechProvider(model: gemini.models[1], apiKey: { nil })
        let local = LocalOmniVoiceProvider.shared
        let identities = [local.cacheIdentity, lite.cacheIdentity, flash.cacheIdentity]
        XCTAssertEqual(Set(identities).count, 3)
        XCTAssertTrue(lite.cacheIdentity.contains(GeminiSpeechProvider.defaultVoice))
        let keys = identities.map { JarvisVoice.cacheKey(text: "Tamamdır.", identity: $0) }
        XCTAssertEqual(Set(keys).count, 3)
    }

    /// Local clips cached before providers existed must keep their file names.
    @MainActor
    func testLocalCacheKeyMatchesTheOldFormula() {
        let identity = LocalOmniVoiceProvider.shared.cacheIdentity
        let refHash = String(identity.dropFirst(LocalOmniVoiceProvider.voiceModel.count + 1))
        let old = SHA256.hash(data: Data("\(LocalOmniVoiceProvider.voiceModel)|\(refHash)|Tamam.".utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(JarvisVoice.cacheKey(text: "Tamam.", identity: identity), old)
    }

    // MARK: Gemini wire format

    func testGeminiRequestUsesHeaderKeyAndUnchangedText() throws {
        let model = SpeechProviders.descriptor(for: "gemini").models[0]
        let text = JarvisVoice.spokenForm("Saat 14:05, patron.")
        let request = GeminiSpeechProvider.request(text: text, model: model, apiKey: "KEY-abc")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "KEY-abc")
        XCTAssertFalse(request.url!.absoluteString.contains("KEY-abc"))
        XCTAssertNil(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(request.url?.absoluteString, "https://generativelanguage.googleapis.com/v1beta/interactions")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gemini-3.8-flash-lite-tts")
        XCTAssertEqual(body["store"] as? Bool, false)
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let part = try XCTUnwrap((input.first?["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(part["text"] as? String, "Saat on dört sıfır beş, patron.")
        XCTAssertNil(part["annotations"], "lite model has no style instruction")
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["mime_type"] as? String, "audio/wav")
        let speech = try XCTUnwrap((body["generation_config"] as? [String: Any])?["speech_config"] as? [[String: Any]])
        XCTAssertEqual(speech.first?["voice"] as? String, GeminiSpeechProvider.defaultVoice)
    }

    func testStyleGoesInSpeechMetadataNotInText() throws {
        let model = SpeechProviders.descriptor(for: "gemini").models[1]
        let style = try XCTUnwrap(model.style)
        let request = GeminiSpeechProvider.request(text: "Tamamdır.", model: model, apiKey: "k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let part = try XCTUnwrap((((body["input"] as? [[String: Any]])?.first?["content"]) as? [[String: Any]])?.first)
        XCTAssertEqual(part["text"] as? String, "Tamamdır.")
        let annotations = try XCTUnwrap(part["annotations"] as? [[String: Any]])
        XCTAssertEqual(annotations.first?["type"] as? String, "speech_metadata")
        XCTAssertEqual(annotations.first?["style"] as? String, style)
    }

    func testParsesTheLastAudioBlockAsIs() throws {
        let wav = Self.wav(seconds: 0.5)
        let response: [String: Any] = [
            "id": "x", "status": "completed",
            "steps": [
                ["type": "user_input", "content": [["type": "text", "text": "Tamam."]]],
                ["type": "model_output", "content": [
                    ["type": "audio", "mime_type": "audio/wav", "data": Self.wav(seconds: 0.1).base64EncodedString()],
                    ["type": "audio", "mime_type": "audio/wav", "data": wav.base64EncodedString()],
                ]],
            ],
        ]
        let audio = try GeminiSpeechProvider.audio(from: JSONSerialization.data(withJSONObject: response))
        XCTAssertEqual(audio, wav, "returned bytes are used without re-wrapping")
    }

    func testRejectsHeaderlessPCM() throws {
        let pcm = Data(repeating: 0, count: 4800)
        let response: [String: Any] = ["steps": [["type": "model_output", "content": [
            ["type": "audio", "mime_type": "audio/l16", "data": pcm.base64EncodedString()],
        ]]]]
        XCTAssertThrowsError(try GeminiSpeechProvider.audio(from: JSONSerialization.data(withJSONObject: response)))
        let noAudio: [String: Any] = ["status": "failed", "steps": []]
        XCTAssertThrowsError(try GeminiSpeechProvider.audio(from: JSONSerialization.data(withJSONObject: noAudio))) {
            XCTAssertEqual($0 as? SpeechSynthesisError, .failed("Gemini response has no audio (status failed)"))
        }
    }

    func testErrorLogKeepsOnlyTheCode() {
        let google = Data(#"{"error":{"code":403,"message":"Text 'Saat 14' leaked, key AIza-secret","status":"PERMISSION_DENIED"}}"#.utf8)
        XCTAssertEqual(GeminiSpeechProvider.errorCode(in: google), "PERMISSION_DENIED")
        let interactions = Data(#"{"code":"type.googleapis.com/quota","message":"secret text"}"#.utf8)
        XCTAssertEqual(GeminiSpeechProvider.errorCode(in: interactions), "type.googleapis.com/quota")
        XCTAssertNil(GeminiSpeechProvider.errorCode(in: Data(#"{"code":"has spaces and text"}"#.utf8)))
    }

    /// The Gemini unary format (24 kHz mono 16-bit RIFF) plays in `AVAudioPlayer` as is.
    func testGeminiWAVFormatLoadsInAVAudioPlayer() throws {
        let player = try AVAudioPlayer(data: Self.wav(seconds: 0.5))
        XCTAssertEqual(player.duration, 0.5, accuracy: 0.01)
        XCTAssertEqual(player.format.sampleRate, 24_000)
        XCTAssertEqual(player.format.channelCount, 1)
    }

    // MARK: Interruption

    /// `stop()` (a new recording) while the API is still answering: the late clip never plays.
    @MainActor
    func testStopDuringSynthesisDropsTheLateClip() async throws {
        let provider = SlowProvider()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let voice = JarvisVoice(settings: store, provider: provider, cacheDirectory: cache)
        var started = false
        let speaking = Task { await voice.speak("Tamamdır, patron.") { started = true } }
        while !provider.waiting { await Task.yield() }
        voice.stop()
        provider.finish()
        let heard = await speaking.value
        XCTAssertFalse(heard)
        XCTAssertFalse(started)
        XCTAssertFalse(voice.isSpeaking)
        XCTAssertEqual(provider.requests, 1)
    }

    // MARK: Voices

    func testGeminiVoiceDefaultsToCharonAndPersists() {
        XCTAssertEqual(store.voiceID(for: "gemini"), "Charon")
        XCTAssertEqual(store.voiceID(for: "local"), "", "the local clone has no voice choice")
        XCTAssertEqual(SpeechProviders.descriptor(for: "gemini").voices.count, 30)
        store.setVoiceID("Kore", for: "gemini")
        let reopened = SpeechSettingsStore(defaults: UserDefaults(suiteName: suiteName)!, secrets: secrets)
        XCTAssertEqual(reopened.voiceID(for: "gemini"), "Kore")
        defaults.set("NoSuchVoice", forKey: SpeechSettingsStore.voiceKey(for: "gemini"))
        XCTAssertEqual(store.voiceID(for: "gemini"), "Charon")
    }

    @MainActor
    func testChosenVoiceReachesRequestAndCacheIdentity() throws {
        store.providerID = "gemini"
        store.setVoiceID("Kore", for: "gemini")
        let kore = try XCTUnwrap(store.makeProvider() as? GeminiSpeechProvider)
        XCTAssertEqual(kore.voice, "Kore")
        store.setVoiceID("Puck", for: "gemini")
        let puck = try XCTUnwrap(store.makeProvider() as? GeminiSpeechProvider)
        XCTAssertNotEqual(kore.cacheIdentity, puck.cacheIdentity)

        let request = GeminiSpeechProvider.request(text: "Tamam.", model: kore.model, voice: kore.voice, apiKey: "k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let speech = try XCTUnwrap((body["generation_config"] as? [String: Any])?["speech_config"] as? [[String: Any]])
        XCTAssertEqual(speech.first?["voice"] as? String, "Kore")
    }

    // MARK: Errors for Settings

    func testInvalidKeyIsToldApartFromOtherBadRequests() {
        let badKey = Data(#"{"error":{"code":400,"message":"API key not valid.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"}]}}"#.utf8)
        XCTAssertEqual(GeminiSpeechProvider.errorCode(in: badKey), "API_KEY_INVALID")
        XCTAssertTrue(SpeechSynthesisError.http(status: 400, code: "API_KEY_INVALID").userMessage.contains("Anahtar geçersiz"))
        XCTAssertTrue(SpeechSynthesisError.http(status: 403, code: "PERMISSION_DENIED").userMessage.contains("Anahtar geçersiz"))
        XCTAssertFalse(SpeechSynthesisError.http(status: 400, code: "INVALID_ARGUMENT").userMessage.contains("Anahtar"))
        XCTAssertTrue(SpeechSynthesisError.http(status: 429, code: nil).userMessage.contains("Kota"))
        XCTAssertTrue(SpeechSynthesisError.network("URLError -1009").userMessage.contains("Bağlantı"))
    }

    // MARK: Switching and testing

    /// Leaving a provider frees it (the local server's RAM); the new one is used from then on.
    @MainActor
    func testSwitchingProviderSuspendsTheOldOne() {
        let old = SlowProvider()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let voice = JarvisVoice(settings: store, provider: old, cacheDirectory: cache)
        voice.reloadProvider()   // store says local → a different identity
        XCTAssertEqual(old.suspended, 1)
        voice.reloadProvider()   // same provider again: nothing to do
        XCTAssertEqual(old.suspended, 1)
    }

    @MainActor
    func testKeyTestReportsTheProviderError() async {
        let provider = SlowProvider()
        provider.failure = .http(status: 403, code: "PERMISSION_DENIED")
        let voice = JarvisVoice(settings: store, provider: provider,
                                cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let error = await voice.speakTest()
        XCTAssertEqual(error, .http(status: 403, code: "PERMISSION_DENIED"))
    }

    @MainActor
    func testKeyTestWithoutKeyNeverCallsTheAPI() async {
        store.providerID = "gemini"
        let voice = JarvisVoice(settings: store,
                                cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let error = await voice.speakTest()
        XCTAssertEqual(error, .notReady("Gemini API key missing"))
    }

    @MainActor
    func testStopDuringKeyTestDropsTheClip() async {
        let provider = SlowProvider()
        let voice = JarvisVoice(settings: store, provider: provider,
                                cacheDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let testing = Task { await voice.speakTest() }
        while !provider.waiting { await Task.yield() }
        voice.stop()
        provider.finish()
        let error = await testing.value
        XCTAssertEqual(error, .cancelled)
        XCTAssertFalse(voice.isSpeaking)
    }

    static func wav(seconds: Double, sampleRate: Int = 24_000) -> Data {
        let samples = Int(Double(sampleRate) * seconds)
        let dataSize = samples * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(dataSize))
        data.append(Data(repeating: 0, count: dataSize))
        return data
    }
}
