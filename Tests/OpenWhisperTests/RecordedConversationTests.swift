import XCTest
@testable import OpenWhisper

final class RecordedConversationTests: XCTestCase {
    func testRecognizesOnlyExplicitDraftTitles() {
        for title in ["ChatGPT", "Codex", "New chat", "Yeni sohbet"] {
            XCTAssertTrue(RecordedConversation.isDraftTitle(title, agent: .codex))
        }
        XCTAssertTrue(RecordedConversation.isDraftTitle("New session", agent: .claudeCode))
        for title in ["", "My project", "Chat…", "New chat about Swift"] {
            XCTAssertFalse(RecordedConversation.isDraftTitle(title, agent: .codex))
        }
    }

    func testSelectsOriginalConversationRatherThanNewestChat() {
        let sessions = [(id: "newer", title: "Other chat"), (id: "original", title: "Recorded here")]
        XCTAssertEqual(RecordedConversation.uniqueSessionID(title: "Recorded here", sessions: sessions), "original")
    }

    func testGeneratedAndOriginalTitlesResolveToSameIdentity() {
        let sessions = [(id: "a", title: "First user message"), (id: "a", title: "Generated name")]
        XCTAssertEqual(RecordedConversation.uniqueSessionID(title: "First user message", sessions: sessions), "a")
        XCTAssertEqual(RecordedConversation.uniqueSessionID(title: "Generated name", sessions: sessions), "a")
    }

    func testDuplicateTitlesAreNotGuessed() {
        XCTAssertNil(RecordedConversation.uniqueSessionID(title: "Same title", sessions: [
            (id: "a", title: "Same title"), (id: "b", title: "Same title")
        ]))
    }

    func testDuplicateFilesForSameSessionAreNotAmbiguous() {
        XCTAssertEqual(RecordedConversation.uniqueSessionID(title: "Chat", sessions: [
            (id: "a", title: "Chat"), (id: "a", title: "Chat")
        ]), "a")
    }

    func testMissingOrTruncatedTitleDoesNotMatchAnotherConversation() {
        XCTAssertNil(RecordedConversation.uniqueSessionID(title: "Chat…", sessions: [(id: "a", title: "Chat full title")]))
        XCTAssertNil(RecordedConversation.uniqueSessionID(title: "Deleted chat", sessions: []))
    }

    func testUnresolvedAgentCaptureCannotPasteIntoCurrentChat() {
        for bundle in ["com.openai.codex", "com.anthropic.claudefordesktop"] {
            let context = PasteContext(targetPID: nil, bundleIdentifier: bundle, applicationName: nil,
                                       focusedElement: nil, focusStatus: .unknown, valueAtCapture: nil,
                                       selectedRangeAtCapture: nil, selectedTextAtCapture: nil)
            XCTAssertFalse(context.conversationIsCurrent)
        }
    }

    func testOtherApplicationsDoNotRequireAgentConversation() {
        XCTAssertFalse(RecordedConversation.requiresBinding("com.apple.TextEdit"))
        XCTAssertFalse(RecordedConversation.requiresBinding(nil))
    }
}
