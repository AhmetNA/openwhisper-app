import XCTest
@testable import OpenWhisper

@MainActor
final class VoiceTestModeTests: XCTestCase {
    private let todo = """
    # TODO

    ## Proje bakımı (2026-10-15) — sırayla

    - [ ] **7. Test modu** — plan maddesi

    ## Video komutları (2026-10-15)

    Log: `[Video]`

    - [x] Eski bitmiş madde
    - [ ] YouTube açıkken "videoyu durdur" → durmalı (`5d1702b`). Log: `[Route] video`
    - [ ] **Bağlam** (`5d1702b`): "ne çalıyor?" → gerçek cevap
      - [ ] alt madde
    - [ ] Bilinen eksik: geri sayım üst çubukta görünmüyor
    - [ ] 🟠 3. "Kaç mail var" yanlış sayıyor — ❌ sesli test 2026-10-15: kaldı
    - [ ] "Videoyu başa sar" → başa dönmeli
    """

    func testParsesCommandsOnlyWhileActive() {
        XCTAssertEqual(VoiceTestCommand.parse("Hey Jarvis, test modunu başlat.", active: false), .start)
        XCTAssertNil(VoiceTestCommand.parse("Geçti", active: false))
        XCTAssertNil(VoiceTestCommand.parse("Atla", active: false))
        XCTAssertNil(VoiceTestCommand.parse("Test modunu kapat", active: false))
        XCTAssertEqual(VoiceTestCommand.parse("Geçti.", active: true), .passed)
        XCTAssertEqual(VoiceTestCommand.parse("Jarvis kaldı", active: true), .failed(note: nil))
        XCTAssertEqual(VoiceTestCommand.parse("Kaldı, çünkü müzik geri gelmedi", active: true), .failed(note: "müzik geri gelmedi"))
        XCTAssertEqual(VoiceTestCommand.parse("Atla", active: true), .skip)
        XCTAssertEqual(VoiceTestCommand.parse("Tekrar oku", active: true), .repeatItem)
        XCTAssertEqual(VoiceTestCommand.parse("Test modunu kapat", active: true), .stop)
        // Real commands said while testing still go to their own routes.
        XCTAssertNil(VoiceTestCommand.parse("Safari'ye geç", active: true))
        XCTAssertNil(VoiceTestCommand.parse("Videoyu durdur", active: true))
        XCTAssertNil(VoiceTestCommand.parse("Kaldırım taşı", active: true))
    }

    func testListsTopLevelOpenItemsWithFailuresLast() {
        let items = VoiceTestTodo.items(in: todo)
        XCTAssertEqual(items.map(\.spoken), [
            "YouTube açıkken \"videoyu durdur\", sonra durmalı.",
            "Bağlam: \"ne çalıyor?\", sonra gerçek cevap",
            "\"Videoyu başa sar\", sonra başa dönmeli",
            "3. \"Kaç mail var\" yanlış sayıyor"
        ])
        XCTAssertEqual(items.first?.section, "Video komutları")
    }

    func testPassRemovesFailMarksAndSkipMovesOn() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicetest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let todoURL = dir.appendingPathComponent("TODO.md")
        let logURL = dir.appendingPathComponent("results.log")
        try todo.write(to: todoURL, atomically: true, encoding: .utf8)
        let session = VoiceTestSession(todoURL: todoURL, logURL: logURL)

        guard case .next(let first, let remaining) = session.start() else { return XCTFail() }
        XCTAssertEqual(remaining, 4)
        XCTAssertTrue(first.spoken.hasPrefix("YouTube"))

        guard case .next(let second, _) = session.pass() else { return XCTFail() }
        var markdown = try String(contentsOf: todoURL, encoding: .utf8)
        XCTAssertFalse(markdown.contains("YouTube"))
        XCTAssertTrue(second.spoken.hasPrefix("Bağlam"))

        let day = Date(timeIntervalSince1970: 1_792_000_000)
        guard case .next(let third, _) = session.fail(note: "cevap yok", now: day) else { return XCTFail() }
        markdown = try String(contentsOf: todoURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("gerçek cevap — ❌ sesli test \(VoiceTestTodo.dayString(day)): kaldı (cevap yok)"))
        XCTAssertTrue(third.spoken.hasPrefix("\"Videoyu"))

        guard case .next(let fourth, _) = session.skip() else { return XCTFail() }
        XCTAssertTrue(fourth.spoken.hasPrefix("3."))
        XCTAssertEqual(session.skip(), .finished)
        XCTAssertFalse(session.isActive)

        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 4)
    }

    func testItemEditedElsewhereIsNotWritten() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voicetest-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try todo.write(to: url, atomically: true, encoding: .utf8)
        let session = VoiceTestSession(todoURL: url, logURL: nil)
        _ = session.start()
        try todo.replacingOccurrences(of: "YouTube açıkken", with: "YouTube'da").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(session.pass(), .itemChanged)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("YouTube'da"))
    }
}
