import XCTest
@testable import OpenWhisper

final class JarvisContextTests: XCTestCase {
    func testPromptLinesListOnlyKnownSources() {
        var context = JarvisContext()
        XCTAssertTrue(context.isEmpty)
        XCTAssertEqual(context.promptLines, [])
        context.nowPlaying = "Çalıyor: Tarkan — Kuzu Kuzu"
        context.upcomingEvents = []
        XCTAssertEqual(context.promptLines, ["Spotify: Çalıyor: Tarkan — Kuzu Kuzu", "Bugün kalan takvim etkinliği yok"])
    }

    func testSystemPromptUsesContextOnlyWhenGiven() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let plain = JarvisChat.systemPrompt(now: now)
        XCTAssertTrue(plain.contains("takvime erişimin yok"))
        XCTAssertFalse(plain.contains("Durum:"))
        let withContext = JarvisChat.systemPrompt(now: now, context: ["Bugün kalan takvim etkinlikleri: 15:30 Toplantı"])
        XCTAssertFalse(withContext.contains("takvime erişimin yok"))
        XCTAssertTrue(withContext.contains("Durum:\n- Bugün kalan takvim etkinlikleri: 15:30 Toplantı"))
        XCTAssertTrue(withContext.contains(JarvisChat.unrecognizedCommandReply))
    }

    func testTimeoutReturnsNilForSlowWork() async {
        let slow = await JarvisContext.withTimeout(.milliseconds(50)) { () async -> Int in
            try? await Task.sleep(for: .seconds(2)); return 1
        }
        XCTAssertNil(slow)
        let fast = await JarvisContext.withTimeout(.seconds(1)) { 7 }
        XCTAssertEqual(fast, 7)
    }
}
