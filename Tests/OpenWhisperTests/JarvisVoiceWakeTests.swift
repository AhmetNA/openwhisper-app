import XCTest
@testable import OpenWhisper

@MainActor
private final class SilentWakeTestProvider: SpeechSynthesisProvider {
    let displayName = "Silent wake test"
    let cacheIdentity = "silent-wake-test"
    let replyLanguage = ReplyLanguage.turkish
    let isReady = true
    let notReadyReason = ""
    let prefetchesAcks = false
    func prepare() async {}
    func synthesize(_ text: String) async throws -> Data {
        SpeechSynthesisProviderTests.wav(seconds: 0.1)
    }
}

@MainActor
final class JarvisVoiceWakeTests: XCTestCase {
    func testLongReplyTimeoutExceedsItsAudioDuration() {
        XCTAssertEqual(JarvisVoice.playbackTimeout(duration: 35), 36)
        XCTAssertEqual(JarvisVoice.playbackTimeout(duration: 2), 3)
    }

    func testActualPlaybackBlocksOwnWakeAndGuardsItsEchoTail() async {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let voice = JarvisVoice(provider: SilentWakeTestProvider(), cacheDirectory: cache)
        var started = false
        let heard = await voice.speak("Jarvis projesinde çalışıyorduk.") {
            started = true
            XCTAssertTrue(voice.isSpeaking)
            XCTAssertFalse(voice.acceptsWakeWord())
        }
        XCTAssertTrue(started)
        XCTAssertTrue(heard)
        XCTAssertFalse(voice.acceptsWakeWord())
        XCTAssertTrue(voice.acceptsWakeWord(at: ProcessInfo.processInfo.systemUptime + 1))
    }

    func testWakeIsBlockedBetweenStreamedSentencesAndOldCandidatesExpire() async {
        let voice = JarvisVoice()
        let oldGeneration = voice.wakeGeneration
        XCTAssertTrue(voice.acceptsWakeWord())
        let (sentences, continuation) = AsyncStream<String>.makeStream()
        let reply = Task { await voice.speak(sentences: sentences) }
        await Task.yield()
        XCTAssertFalse(voice.acceptsWakeWord())
        XCTAssertFalse(voice.acceptsWakeWord(generation: oldGeneration))
        continuation.finish()
        _ = await reply.value
        XCTAssertTrue(voice.acceptsWakeWord())
        XCTAssertFalse(voice.acceptsWakeWord(generation: oldGeneration))
    }
}
