import XCTest
@testable import OpenWhisper

/// WhatsApp sending, briefing, chat switching, Claude permission and greeting replies in
/// English, while the dictation language is English.
@MainActor
final class EnglishVoiceFlowTests: XCTestCase {
    private var savedLanguage: String?

    override func setUp() {
        savedLanguage = UserDefaults.standard.string(forKey: "language")
        UserDefaults.standard.set("en", forKey: "language")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLanguage, forKey: "language")
    }

    func testWhatsAppSend() {
        XCTAssertEqual(WhatsAppSendParser.parse("Send Ali a WhatsApp message saying I'm on my way"),
                       WhatsAppOutgoing(recipient: "Ali", body: "I'm on my way"))
        XCTAssertEqual(WhatsAppSendParser.parse("Jarvis, send a WhatsApp message to Ayşe Yılmaz: running late"),
                       WhatsAppOutgoing(recipient: "Ayşe Yılmaz", body: "Running late"))
        XCTAssertEqual(WhatsAppSendParser.parse("tell Mehmet on WhatsApp that I'll call tonight"),
                       WhatsAppOutgoing(recipient: "Mehmet", body: "I'll call tonight"))
        XCTAssertEqual(WhatsAppSendParser.parse("WhatsApp Ali"), WhatsAppOutgoing(recipient: "Ali", body: ""))
        XCTAssertEqual(WhatsAppSendParser.parse("send a WhatsApp to mom"), WhatsAppOutgoing(recipient: "Mom", body: ""))
        XCTAssertNil(WhatsAppSendParser.parse("message Ali saying hi"))
        XCTAssertNil(WhatsAppSendParser.parse("I sent him a WhatsApp message yesterday"))
    }

    func testBriefing() {
        XCTAssertEqual(EnglishSystemCommands.parse("brief me", installedApps: []), .briefing(dayOffset: 0))
        XCTAssertEqual(EnglishSystemCommands.parse("What's on today?", installedApps: []), .briefing(dayOffset: 0))
        XCTAssertEqual(EnglishSystemCommands.parse("what does tomorrow look like", installedApps: []), .briefing(dayOffset: 1))
    }

    func testChatSwitching() {
        XCTAssertTrue(CloudSessionNavigation.isRequest("open the chat about taxes in Claude"))
        XCTAssertTrue(CloudSessionNavigation.isRequest("switch to the session on the settings page"))
        XCTAssertFalse(CloudSessionNavigation.isRequest("I had a good chat with Ali"))
        XCTAssertEqual(CloudSessionNavigation.newChatOpened, "New chat opened.")
    }

    func testClaudePermissionQuestion() throws {
        let json = #"{"tool_name":"Bash","tool_input":{"description":"Run the tests"},"cwd":"/x/Bitirme"}"#
        let request = try XCTUnwrap(ClaudePermission.Request(json: Data(json.utf8)))
        XCTAssertEqual(ClaudePermission.question(for: request), "Claude in Bitirme wants to run a command: Run the tests. Do you allow it?")
        XCTAssertEqual(ClaudePermission.reply(to: .allow, request: request), "Okay, allowed.")
    }

    func testGreetingReplies() {
        var reply = JarvisReply()
        reply.addressChance = 0
        XCTAssertTrue(reply.greet(.goodMorning, hour: 9).hasPrefix("Good morning, sir."))
        XCTAssertEqual(reply.greet(.goodNight, hour: 22), "Good night, rest well.")
        XCTAssertTrue(JarvisReply.helpText.hasPrefix("I play music"))
        XCTAssertTrue(JarvisReply.whatCanISay(frontBundleID: "com.apple.Safari", inTextField: false).hasPrefix("Here you can say"))
    }

    func testBriefingWording() {
        let summary = DailyBriefing.Summary(title: "Today", events: ["09:00 Standup"], reminders: [], unreadMailCount: 2,
                                            mail: [], missingAccess: [])
        XCTAssertEqual(summary.headline, "Today: 1 event · 2 unread mails — first: 09:00 Standup")
    }
}
