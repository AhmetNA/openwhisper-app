import XCTest
@testable import OpenWhisper

/// Deterministic generator so replies and the "patron" address are predictable.
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class JarvisReplyTests: XCTestCase {
    private func quietReply() -> JarvisReply {
        var reply = JarvisReply(rng: SeededRNG(state: 1))
        reply.addressChance = 0
        return reply
    }

    func testAnswersQuestionsWithContent() {
        var reply = quietReply()
        XCTAssertEqual(reply.system(.time, status: "Saat 14:05"), "Saat 14:05.")
        XCTAssertEqual(reply.system(.battery, status: "Pil %80, şarj oluyor"), "Pil yüzde 80, şarj oluyor.")
        XCTAssertEqual(reply.system(.mailLatest, status: "Son mail: Ali — Toplantı"), "Son mail: Ali, Toplantı.")
    }

    func testUnreadMailIsShortened() {
        var reply = quietReply()
        XCTAssertEqual(reply.system(.mailReadUnread, status: "Ali: Merhaba · Ayşe: Fatura · Can: Not"),
                       "3 okunmamış mail, ilki Ali: Merhaba.")
    }

    func testActionsGetAShortAck() throws {
        var reply = quietReply()
        let spoken = try XCTUnwrap(reply.system(.wifi(on: false), status: "Wi-Fi kapatıldı"))
        XCTAssertTrue(JarvisReply.acks.contains(spoken), spoken)
    }

    func testFailuresSayWhy() {
        var reply = quietReply()
        XCTAssertEqual(reply.system(.brightness(up: true, level: nil), status: "Parlaklık değiştirilemedi"),
                       "Maalesef, parlaklık değiştirilemedi.")
        XCTAssertEqual(reply.system(.wifi(on: true), status: "Wi-Fi değiştirilemedi"),
                       "Maalesef, Wi-Fi değiştirilemedi.")
        XCTAssertEqual(reply.system(.headset(connect: false), status: "Bağlı kulaklık yok"),
                       "Maalesef, bağlı kulaklık yok.")
        XCTAssertEqual(reply.system(.quitApp("Safari"), status: "Safari zaten kapalı"), "Safari zaten kapalı.")
    }

    func testSilentWhenItCannotBeHeard() {
        var reply = quietReply()
        XCTAssertNil(reply.system(.mute(true), status: "Ses kapatıldı"))
        XCTAssertNil(reply.system(.sleep, status: "Uyku moduna geçiliyor"))
    }

    func testSpotifyOnlyAcks() {
        var reply = quietReply()
        XCTAssertTrue(JarvisReply.acks.contains(reply.spotify(handled: true) ?? ""))
        XCTAssertNil(reply.spotify(handled: false))
    }

    func testAgentSaysWhetherItSent() {
        var reply = quietReply()
        XCTAssertEqual(reply.agent(sent: true), "Gönderdim.")
        XCTAssertEqual(reply.agent(sent: false), "Yazdım.")
    }

    func testAddressIsOccasionalAndNeverTwiceInARow() {
        var reply = JarvisReply(rng: SeededRNG(state: 42))
        var addressed: [Bool] = []
        for _ in 0..<200 {
            let spoken = reply.ack()
            addressed.append(JarvisReply.addresses.contains { spoken.hasSuffix(", \($0).") })
        }
        XCTAssertFalse(zip(addressed, addressed.dropFirst()).contains { $0 && $1 })
        let share = Double(addressed.filter { $0 }.count) / Double(addressed.count)
        XCTAssertGreaterThan(share, 0.1)
        XCTAssertLessThan(share, 0.4)
    }

    func testAddressReplacesFinalPeriod() {
        var reply = JarvisReply(rng: SeededRNG(state: 7))
        reply.addressChance = 1
        let spoken = reply.answer("Saat 14:05")
        XCTAssertTrue(spoken == "Saat 14:05, patron." || spoken == "Saat 14:05, efendim.", spoken)
    }
}

final class JarvisVoiceTests: XCTestCase {
    func testOnlyFixedPhrasesAreCached() {
        XCTAssertTrue(JarvisVoice.isCacheable("Tamamdır, patron."))
        XCTAssertFalse(JarvisVoice.isCacheable("Saat 14:05."))
    }

    func testCacheKeyDependsOnVoice() {
        XCTAssertNotEqual(JarvisVoice.cacheKey(text: "Tamam.", voice: "a"), JarvisVoice.cacheKey(text: "Tamam.", voice: "b"))
    }

    func testSpellsOutTimes() {
        XCTAssertEqual(JarvisVoice.spokenForm("Saat 14:05, patron."), "Saat on dört sıfır beş, patron.")
        XCTAssertEqual(JarvisVoice.spokenForm("Saat 14:00"), "Saat on dört")
        XCTAssertEqual(JarvisVoice.spokenForm("ilki 09:30'da"), "ilki dokuz otuzda")
    }

    func testSpellsOutNumbersAndDropsSuffixApostrophe() {
        XCTAssertEqual(JarvisVoice.spokenForm("Şarj yüzde 80."), "Şarj yüzde seksen.")
        XCTAssertEqual(JarvisVoice.spokenForm("3'ü okunmamış"), "üçü okunmamış")
        XCTAssertEqual(JarvisVoice.spokenForm("3,5 derece"), "üç virgül beş derece")
    }

    func testLeavesWordsAlone() {
        XCTAssertEqual(JarvisVoice.spokenForm("Wi-Fi'yi kapattım, efendim."), "Wi-Fi'yi kapattım, efendim.")
    }
}

final class JarvisChatTests: XCTestCase {
    func testTakesOnlyFinishedSentences() {
        var buffer = "Elbette efendim. Saat 14.05 oldu! Bir de şu"
        XCTAssertEqual(JarvisChat.takeSentences(from: &buffer), ["Elbette efendim.", "Saat 14.05 oldu!"])
        XCTAssertEqual(buffer, " Bir de şu")
    }

    func testSentenceNeedsTrailingSpace() {
        var buffer = "Bitti."
        XCTAssertEqual(JarvisChat.takeSentences(from: &buffer), [])
        XCTAssertEqual(buffer, "Bitti.")
    }

    func testSpeakableDropsMarkdownAndEmoji() {
        XCTAssertEqual(JarvisChat.speakable("**Elbette**, patron 😊"), "Elbette, patron")
        XCTAssertEqual(JarvisChat.speakable("- Madde bir"), "Madde bir")
        XCTAssertEqual(JarvisChat.speakable("Saat 3 oldu."), "Saat 3 oldu.")
    }

    func testClaudeCodeAndTerminalsMeanTalkingToAgents() {
        XCTAssertTrue(AgentApp.isAgentFront("com.anthropic.claudefordesktop"))
        XCTAssertTrue(AgentApp.isAgentFront("com.openai.codex"))
        XCTAssertTrue(AgentApp.isAgentFront("com.googlecode.iterm2"))
        XCTAssertFalse(AgentApp.isAgentFront("net.whatsapp.WhatsApp"))
        XCTAssertFalse(AgentApp.isAgentFront(nil))
    }
}
