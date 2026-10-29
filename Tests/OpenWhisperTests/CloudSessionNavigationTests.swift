import XCTest
@testable import OpenWhisper

final class CloudSessionNavigationTests: XCTestCase {
    private let candidates = [CloudSessionNavigation.Candidate(id: "a", title: "Ses modeli", activity: 1, excerpt: ""),
                              CloudSessionNavigation.Candidate(id: "b", title: "Arayüz", activity: 2, excerpt: "")]
    func testExcerptsExcludeToolAndSystemContent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Ses modeli hakkında konuşalım"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","text":"SECRET_TOOL"},{"type":"text","text":"Turbo seçildi"}]}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"system","content":[{"type":"input_text","text":"SYSTEM_SECRET"}]}}"#
        ].joined(separator: "\n")
        try lines.write(to: file, atomically: true, encoding: .utf8)
        let excerpt = CloudSessionNavigation.transcriptExcerpt(path: file.path)
        XCTAssertTrue(excerpt.contains("Ses modeli"))
        XCTAssertTrue(excerpt.contains("Turbo seçildi"))
        XCTAssertFalse(excerpt.contains("SECRET"))
    }
    func testNaturalRequests() {
        for text in ["Bir önceki chat'e geç", "yeni chat aç", "Claude Code'da ses modeliyle ilgili konuştuğumuz sohbeti aç"] {
            XCTAssertTrue(CloudSessionNavigation.isRequest(text))
        }
        XCTAssertFalse(CloudSessionNavigation.isRequest("Sesi kıs"))
    }
    func testOnlyEnumeratedDestinationsAccepted() {
        XCTAssertEqual(CloudSessionNavigation.decision(#"{"action":"open","id":"a"}"#, candidates: candidates, currentID: "b")?.id, "a")
        for output in [#"{"action":"open","id":"invented"}"#, #"{"action":"delete","id":"a"}"#,
                       #"{"action":"new","id":"a"}"#, "Sohbeti açtım"] {
            XCTAssertNil(CloudSessionNavigation.decision(output, candidates: candidates, currentID: "b"))
        }
        XCTAssertNil(CloudSessionNavigation.decision(#"{"action":"open","id":"b"}"#, candidates: candidates, currentID: "b"))
    }
    func testAmbiguousTitlesRejected() {
        let duplicate = candidates + [.init(id: "c", title: "Ses modeli", activity: 3, excerpt: "")]
        XCTAssertNil(CloudSessionNavigation.decision(#"{"action":"open","id":"a"}"#, candidates: duplicate, currentID: nil))
    }
    func testNoActionAndNewDoNotRequireHistory() {
        for action in ["new", "none", "ambiguous"] {
            XCTAssertNotNil(CloudSessionNavigation.decision("{\"action\":\"\(action)\",\"id\":null}", candidates: [], currentID: nil))
        }
    }

    func testTitleMatchOpensTheBestScoringChat() {
        let chats = ["En uzun süren komutlar analizi", "Model kurulumu ve test", "Yeni 2B model araştırması",
                     "Spotify zaman aşımı", "Developer modu hata mesajı"].enumerated().map {
            CloudSessionNavigation.Candidate(id: "\($0.offset)", title: $0.element, activity: 0, excerpt: "")
        }
        func match(_ text: String, current: String? = nil) -> String? {
            CloudSessionNavigation.titleMatch(text, candidates: chats, currentID: current)?.0.title
        }
        // 29 Oct 2026: the spoken topic was the title word for word, yet it waited 1.8 s for the cloud.
        XCTAssertEqual(match("En uzun süren komutlar analizi sohbetine geç."), "En uzun süren komutlar analizi")
        XCTAssertEqual(match("Claude'da spotify zaman aşımı sohbetini aç"), "Spotify zaman aşımı")
        XCTAssertEqual(match("Developer modu hata mesajı oturumuna geç"), "Developer modu hata mesajı")
        XCTAssertEqual(match("Model kurulumu ve test sohbetine geç."), "Model kurulumu ve test")
        // Left to the cloud: no topic, a relative chat, a weak or tied match, the current chat.
        XCTAssertNil(match("Yeni sohbet aç"))
        XCTAssertNil(match("Önceki sohbete geç"))
        XCTAssertNil(match("Yeni 2B model araştırması sohbetine geç"))
        XCTAssertNil(match("Ses sorunları sohbetine geç"))
        XCTAssertNil(match("Model sohbetine geç"))
        XCTAssertNil(match("Spotify zaman aşımı sohbetine geç", current: "3"))
    }
}
