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
}
