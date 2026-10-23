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

    func testPromptLinesPutFrontAppDetailsFirst() {
        var context = JarvisContext()
        context.frontApp = "Safari"
        context.windowTitle = "Haberler"
        context.selectedText = "seçili"
        context.appDetails = ["Safari sekmesi: Haberler — https://ornek.com (2 sekme açık)"]
        context.nowPlaying = "Çalıyor: Tarkan — Kuzu Kuzu"
        context.upNext = ["Tarkan — Şımarık"]
        XCTAssertEqual(context.promptLines, [
            "Ön plandaki uygulama: Safari", "Pencere başlığı: Haberler", "Seçili metin: seçili",
            "Safari sekmesi: Haberler — https://ornek.com (2 sekme açık)",
            "Spotify: Çalıyor: Tarkan — Kuzu Kuzu", "Spotify'da sıradaki: Tarkan — Şımarık",
        ])
    }

    func testExcerptFlattensAndCuts() {
        XCTAssertNil(JarvisAppContext.excerpt(" \n\t "))
        XCTAssertEqual(JarvisAppContext.excerpt("a\n\n  b"), "a b")
        let long = JarvisAppContext.excerpt(String(repeating: "x", count: 700))
        XCTAssertEqual(long?.count, JarvisAppContext.excerptLimit + 1)
        XCTAssertEqual(long?.last, "…")
    }

    func testLastCodexAnswerTakesNewestFinishedTurn() {
        let rollout = """
            {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"ilk"}}
            {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"son"}}
            {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":null}}
            {"type":"event_msg","payload":{"type":"token_count"}}
            """
        XCTAssertEqual(JarvisAppContext.lastCodexAnswer(inRollout: rollout), "son")
        XCTAssertNil(JarvisAppContext.lastCodexAnswer(inRollout: "kesik satır"))
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

final class MorningBriefingLineTests: XCTestCase {
    func testMorningLine() {
        let now = Calendar.current.date(bySettingHour: 8, minute: 5, second: 0, of: Date())!
        let summary = DailyBriefing.Summary(title: "Bugün", events: ["10:00 Toplantı", "14:00 Spor"], reminders: ["Süt al"], unreadMailCount: 3, mail: [])
        XCTAssertEqual(summary.morningLine(now: now), "Saat 08:05. Bugün 2 etkinlik var, ilki 10:00 Toplantı. 1 hatırlatıcı ve 3 okunmamış mail bekliyor.")
        let empty = DailyBriefing.Summary(title: "Bugün", events: [], reminders: [], unreadMailCount: 0, mail: [])
        XCTAssertEqual(empty.morningLine(now: now), "Saat 08:05. Takvim bugün boş.")
    }
}
