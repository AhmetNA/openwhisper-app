import XCTest
@testable import OpenWhisper

/// Dictation edits, typing, yes/no answers and screen presses while the dictation language is English.
@MainActor
final class EnglishDictationCommandTests: XCTestCase {
    private var savedLanguage: String?

    override func setUp() {
        savedLanguage = UserDefaults.standard.string(forKey: "language")
        UserDefaults.standard.set("en", forKey: "language")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLanguage, forKey: "language")
    }

    func testDictationEdits() {
        let dictation = "See you on Monday. I'll bring Imagine Dragons tickets"
        let cases: [(String, DictationEdit)] = [
            ("Undo", .deleteAll), ("Scratch that", .deleteAll), ("Delete what I said", .deleteAll),
            ("Delete the last word", .deleteLastWord), ("Delete the last sentence.", .deleteLastSentence),
            ("Delete everything", .clearField), ("Clear the field", .clearField), ("Press enter", .pressReturn),
            ("Replace Monday with Tuesday", .replace(old: "Monday", new: "Tuesday")),
            ("Change imagine to Believer", .replace(old: "Imagine", new: "Believer")),
        ]
        for (text, edit) in cases { XCTAssertEqual(DictationEdit.parse(text, dictation: dictation), edit, text) }
        XCTAssertNil(DictationEdit.parse("Replace the tires with new ones", dictation: dictation))
        XCTAssertNil(DictationEdit.parse("Send it", dictation: dictation))
        XCTAssertTrue(DictationEdit.isReturn("Hit enter"))
        XCTAssertTrue(DictationEdit.isClearField("Clear"))
    }

    func testTyping() {
        XCTAssertEqual(JarvisAddressee.leadingTypeCommand("Type here: see you tomorrow"), "see you tomorrow")
        XCTAssertEqual(JarvisAddressee.leadingTypeCommand("Write this down, call the bank"), "call the bank")
        XCTAssertEqual(JarvisAddressee.leadingTypeCommand("Type hello world"), "hello world")
        XCTAssertNil(JarvisAddressee.leadingTypeCommand("Write me a poem about autumn"))
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("See you at eight, type that"), "See you at eight")
        XCTAssertEqual(JarvisAddressee.trailingTypeCommand("Meeting moved to Friday and write it down"), "Meeting moved to Friday")
        XCTAssertNil(JarvisAddressee.trailingTypeCommand("I don't know how to type"))
    }

    func testAnswers() {
        for text in ["Yes", "Yeah, go ahead", "Yes send it", "Okay", "Sure, thanks"] {
            XCTAssertEqual(EnglishAnswers.decision(text), true, text)
        }
        for text in ["No", "No thanks", "Cancel", "Don't send it", "Never mind"] {
            XCTAssertEqual(EnglishAnswers.decision(text), false, text)
        }
        XCTAssertNil(EnglishAnswers.decision("Yes but change the second line first"))
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Yes, delete it"), .approve)
        XCTAssertEqual(WhatsAppSender.decision("No, don't send it"), .reject)
        XCTAssertEqual(WhatsAppSender.decision("Don't send it"), .reject)
        XCTAssertEqual(ScreenActions.confirmation("Yes press it"), true)
        XCTAssertEqual(ClaudePermission.answer("Yes"), .allow)
        XCTAssertEqual(ClaudePermission.answer("Always allow"), .always)
        XCTAssertEqual(ClaudePermission.answer("No, run the tests first"), .deny("run the tests first"))
        XCTAssertEqual(ClaudePermission.answer("No"), .deny(nil))
    }

    func testScreenPress() {
        XCTAssertTrue(ScreenActions.saysClick("Press the Send button"))
        XCTAssertTrue(ScreenActions.saysClick("Click Submit"))
        XCTAssertFalse(ScreenActions.saysClick("Send the report"))
        XCTAssertEqual(ScreenActions.spokenName("Press the Send button"), "send")
        XCTAssertEqual(ScreenActions.spokenName("Can you click on Submit"), "submit")
    }

    func testTurkishSettingKeepsTurkishEdits() {
        UserDefaults.standard.set("tr", forKey: "language")
        XCTAssertNil(DictationEdit.parse("Undo", dictation: "merhaba"))
        XCTAssertEqual(DictationEdit.parse("geri al", dictation: "merhaba"), .deleteAll)
        XCTAssertEqual(ScreenActions.confirmation("evet"), true)
    }
}
