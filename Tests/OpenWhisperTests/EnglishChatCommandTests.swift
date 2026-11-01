import XCTest
@testable import OpenWhisper

/// Greetings, questions about Jarvis, memory and past conversations while the dictation language is English.
@MainActor
final class EnglishChatCommandTests: XCTestCase {
    private var savedLanguage: String?

    override func setUp() {
        savedLanguage = UserDefaults.standard.string(forKey: "language")
        UserDefaults.standard.set("en", forKey: "language")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLanguage, forKey: "language")
    }

    func testGreetingsAndMeta() {
        XCTAssertEqual(EnglishChatCommands.greeting(in: "Good morning, Jarvis!"), .goodMorning)
        XCTAssertEqual(EnglishChatCommands.greeting(in: "Hey Jarvis, how are you?"), .howAreYou)
        XCTAssertEqual(EnglishChatCommands.greeting(in: "Hello"), .hello)
        XCTAssertEqual(EnglishChatCommands.greeting(in: "Good night"), .goodNight)
        XCTAssertNil(EnglishChatCommands.greeting(in: "Hey Jarvis"))
        XCTAssertNil(EnglishChatCommands.greeting(in: "Good morning, play some music"))
        XCTAssertEqual(EnglishChatCommands.meta(in: "Sorry, what did you say?"), .repeatLast)
        XCTAssertEqual(EnglishChatCommands.meta(in: "Could you repeat that?"), .repeatLast)
        XCTAssertEqual(EnglishChatCommands.meta(in: "What can you do?"), .help)
        XCTAssertEqual(EnglishChatCommands.meta(in: "What can I say here?"), .whatCanISay)
        XCTAssertEqual(EnglishChatCommands.meta(in: "What did you hear?"), .whatDidYouHear)
        XCTAssertEqual(EnglishChatCommands.meta(in: "Undo the last command"), .undoLastCommand)
    }

    func testRouterUsesEnglishGreetings() {
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true, focus: .notEditable, hasTargetApp: false, targetBundleID: nil)
        guard case .greeting(.goodMorning) = VoiceRouter.route("Good morning", facts: facts) else { return XCTFail() }
        guard case .meta(.help) = VoiceRouter.route("What can you do?", facts: facts) else { return XCTFail() }
        guard case .memory(.recall) = VoiceRouter.route("What do you know about me?", facts: facts) else { return XCTFail() }
        guard case .pastConversation = VoiceRouter.route("What did we talk about yesterday?", facts: facts) else { return XCTFail() }
    }

    func testMemory() {
        XCTAssertEqual(UserMemoryCommand.parse("Remember that my sister's name is Dilay"), .remember("my sister's name is Dilay"))
        XCTAssertEqual(UserMemoryCommand.parse("Jarvis, keep in mind I'm allergic to nuts"), .remember("I'm allergic to nuts"))
        XCTAssertEqual(UserMemoryCommand.parse("My name is ahmet"), .remember(UserMemory.namePrefix + "Ahmet"))
        XCTAssertEqual(UserMemoryCommand.parse("What do you know about me?"), .recall)
        XCTAssertEqual(UserMemoryCommand.parse("Forget that"), .forgetLast)
        XCTAssertEqual(UserMemoryCommand.parse("Forget about my old phone number"), .forget("my old phone number"))
        XCTAssertEqual(UserMemoryCommand.parse("Clear your memory"), .forgetAll)
        XCTAssertNil(UserMemoryCommand.parse("Remember to buy milk"))
        XCTAssertNil(UserMemoryCommand.parse("Don't forget to call mom"))
    }

    func testPastConversation() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 15))!
        let today = calendar.startOfDay(for: now)
        let yesterday = TimeQuery.parse("What did we talk about yesterday?", now: now)
        XCTAssertEqual(yesterday?.label, "yesterday")
        XCTAssertEqual(yesterday?.interval.start, calendar.date(byAdding: .day, value: -1, to: today))
        XCTAssertEqual(TimeQuery.parse("What did I ask you last week?", now: now)?.label, "last week")
        XCTAssertEqual(TimeQuery.parse("Do you remember what I said 3 days ago?", now: now)?.label, "3 days ago")
        XCTAssertEqual(TimeQuery.parse("What did I tell you on Monday?", now: now)?.label, "on Monday")
        XCTAssertNil(TimeQuery.parse("What did I say?", now: now))
        XCTAssertNil(TimeQuery.parse("Delete yesterday's meeting", now: now))
    }

    func testAddressing() {
        XCTAssertEqual(JarvisAddressee.explicitChatCommand("Answer me: what is the capital of France"), "what is the capital of France")
        XCTAssertEqual(JarvisAddressee.explicitChatCommand("I'm talking to you, how tall is Everest"), "how tall is Everest")
        XCTAssertTrue(JarvisAddressee.looksLikeQuestion("How tall is Everest"))
        XCTAssertTrue(JarvisAddressee.looksLikeQuestion("Is it raining?"))
        XCTAssertFalse(JarvisAddressee.looksLikeQuestion("The meeting is at three"))
    }

    func testTurkishSettingKeepsTurkish() {
        UserDefaults.standard.set("tr", forKey: "language")
        let facts = VoiceRouter.Facts(isVoiceCommand: true, acceptsCommands: true, focus: .notEditable, hasTargetApp: false, targetBundleID: nil)
        guard case .greeting(.goodMorning) = VoiceRouter.route("Günaydın", facts: facts) else { return XCTFail() }
        XCTAssertNil(UserMemoryCommand.parse("Remember that my sister's name is Dilay"))
        XCTAssertTrue(JarvisAddressee.looksLikeQuestion("Yarın hava nasıl"))
    }
}
