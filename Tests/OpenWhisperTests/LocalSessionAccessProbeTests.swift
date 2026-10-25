import XCTest
@testable import OpenWhisper

final class LocalSessionAccessProbeTests: XCTestCase {
    func testLocalSourcesReadOnly() throws {
        guard ProcessInfo.processInfo.environment["JARVIS_LOCAL_SESSION_PROBE"] == "1" else {
            throw XCTSkip("Opt-in read-only check of the user's local sessions")
        }
        for agent in [AgentApp.codex, .claudeCode] {
            let recent = try UnreadSessionRecap.load(agent, unreadOnly: false)
            let unread = try UnreadSessionRecap.load(agent)
            print("LocalSessionProbe \(agent.rawValue): completed=\(recent.count) unread=\(unread.count)")
            XCTAssertFalse(recent.isEmpty, "Local completed sessions must be readable for \(agent)")
            if let item = recent.last {
                let selected = try UnreadSessionRecap.load(agent, unreadOnly: false, sessionID: item.id)
                XCTAssertEqual(selected.count, 1)
                XCTAssertEqual(selected.first?.exchange, item.exchange)
            }
        }
    }
}
