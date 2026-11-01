import XCTest
@testable import OpenWhisper

/// Coding agent commands while the dictation language is English.
final class EnglishAgentCommandTests: XCTestCase {
    private var savedLanguage: String?

    override func setUp() {
        savedLanguage = UserDefaults.standard.string(forKey: "language")
        UserDefaults.standard.set("en", forKey: "language")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLanguage, forKey: "language")
    }

    func testOpenNewSession() {
        let claude = AgentDictation(target: .claudeCode, body: "", send: false, session: .new)
        XCTAssertEqual(AgentCommandParser.parse("Open a new session."), claude)
        XCTAssertEqual(AgentCommandParser.parse("Start a new chat"), claude)
        XCTAssertEqual(AgentCommandParser.parse("Could you open a new session in Claude Code, please?"), claude)
        XCTAssertEqual(AgentCommandParser.parse("In Cloud Code, open a new session."), claude)
        XCTAssertEqual(AgentCommandParser.parse("Start a new chat in Codex")?.target, .codex)
        XCTAssertEqual(AgentCommandParser.parse("Open a new conversation in ChatGPT")?.target, .chatGPT)
    }

    func testSentencesStayDictation() {
        XCTAssertNil(AgentCommandParser.parse("I opened a new session yesterday"))
        XCTAssertNil(AgentCommandParser.parse("Open a new session and fix the login bug"))
        XCTAssertNil(AgentCommandParser.parse("Open the new session list"))
    }

    func testTurkishSettingIgnoresEnglishRules() {
        UserDefaults.standard.set("tr", forKey: "language")
        XCTAssertNil(AgentCommandParser.parse("Open a new session."))
        XCTAssertEqual(AgentCommandParser.parse("Claude Code'da yeni session aç")?.session, .new)
    }
}
