import XCTest
@testable import OpenWhisper

/// Statuses and replies written in English when commands are spoken in English.
@MainActor
final class EnglishStatusTests: XCTestCase {
    private var savedLanguage: String?

    override func setUp() {
        savedLanguage = UserDefaults.standard.string(forKey: "language")
        UserDefaults.standard.set("en", forKey: "language")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLanguage, forKey: "language")
    }

    func testFailureDetection() {
        XCTAssertTrue(JarvisReply.isFailure("Couldn't change the brightness"))
        XCTAssertTrue(JarvisReply.isFailure("Safari not found"))
        XCTAssertTrue(JarvisReply.isFailure("No headset connected"))
        XCTAssertFalse(JarvisReply.isFailure("Wi-Fi off"))
        XCTAssertFalse(JarvisReply.isFailure("Battery 80%, charging"))
    }

    func testReplies() {
        var reply = JarvisReply()
        reply.addressChance = 0
        XCTAssertEqual(reply.system(.brightness(up: true, level: nil), status: "Couldn't change the brightness"),
                       "Sorry, couldn't change the brightness.")
        XCTAssertEqual(reply.system(.quitApp("Safari"), status: "Safari is already closed"), "Safari is already closed.")
        XCTAssertEqual(reply.system(.battery, status: "Battery 80%"), "Battery 80 percent.")
        XCTAssertEqual(reply.failure("I couldn't set the reminder"), "Sorry, I couldn't set the reminder.")
        XCTAssertEqual(reply.timerFired(label: nil, seconds: 600), "Sir, 10 minutes are up.")
    }

    func testDurations() {
        XCTAssertEqual(SpokenDuration.spoken(45), "45 seconds")
        XCTAssertEqual(SpokenDuration.spoken(60), "1 minute")
        XCTAssertEqual(SpokenDuration.spoken(1800), "half an hour")
        XCTAssertEqual(SpokenDuration.spoken(5400), "1 and a half hours")
        XCTAssertEqual(VideoController.duration(90), "1 minute 30 seconds")
    }

    func testFlowBarTexts() {
        XCTAssertEqual(SystemController.frontStatus("Safari"), "Safari in front")
        XCTAssertEqual(FileFinder.openingPrefix + "report.pdf", "Opening: report.pdf")
        XCTAssertTrue(BrowserController.failures.contains("Couldn't reach Safari"))
        XCTAssertEqual(L("Tamam", "Okay"), "Okay")
    }
}
