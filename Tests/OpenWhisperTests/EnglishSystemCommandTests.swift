import XCTest
@testable import OpenWhisper

/// Mac and app commands while the dictation language is English.
@MainActor
final class EnglishSystemCommandTests: XCTestCase {
    private var savedLanguage: String?
    private let apps = ["Safari", "Google Chrome", "Mail", "Xcode", "Music", "Spotify", "Slack"]

    override func setUp() {
        savedLanguage = UserDefaults.standard.string(forKey: "language")
        UserDefaults.standard.set("en", forKey: "language")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLanguage, forKey: "language")
    }

    private func parse(_ text: String) -> SystemCommand? {
        SystemCommandParser.parse(text, installedApps: apps)
    }

    func testMacControls() {
        let cases: [(String, SystemCommand)] = [
            ("Turn off Wi-Fi", .wifi(on: false)), ("Turn on Bluetooth", .bluetooth(on: true)),
            ("Bluetooth off", .bluetooth(on: false)), ("Enable the wifi", .wifi(on: true)),
            ("Connect my AirPods", .headset(connect: true)), ("Disconnect the headphones", .headset(connect: false)),
            ("Mute", .mute(true)), ("Unmute the sound", .mute(false)),
            ("Turn the brightness up", .brightness(up: true, level: nil)),
            ("Make the screen dimmer", .brightness(up: false, level: nil)),
            ("Set the brightness to 50 percent", .brightness(up: true, level: 50)),
            ("Max brightness", .brightness(up: true, level: 100)),
            ("Turn on dark mode", .darkMode(on: true)), ("Switch to light mode", .darkMode(on: false)),
            ("Scroll down", .scroll(up: false, large: false)), ("Scroll up a lot", .scroll(up: true, large: true)),
            ("Lock the screen", .lockScreen), ("Turn off the display", .displaySleep),
            ("Put the computer to sleep", .sleep), ("Take a screenshot", .screenshot),
            ("What time is it?", .time), ("How much battery do I have?", .battery),
            ("Stop listening", .disableWakeWord), ("Unlock the computer", .unlockRequest),
        ]
        for (text, command) in cases { XCTAssertEqual(parse(text), command, text) }
    }

    func testAppsAndTabs() {
        let cases: [(String, SystemCommand)] = [
            ("Open Safari", .openApp("Safari")), ("Launch Chrome", .openApp("Google Chrome")),
            ("Quit Xcode", .quitApp("Xcode")), ("Close the Mail app", .quitApp("Mail")),
            ("Force quit Slack", .forceQuitApp("Slack")), ("Switch to Safari", .switchToApp("Safari")),
            ("Open a new tab", .browser(.newTab)), ("Close this tab", .browser(.closeTab)),
            ("Reload the page", .browser(.reload)), ("Go back", .browser(.back)),
            ("Search YouTube for lofi music", .browser(.search(.youtube, "lofi music"))),
            ("Google weather in Istanbul", .browser(.search(.google, "weather in istanbul"))),
        ]
        for (text, command) in cases { XCTAssertEqual(parse(text), command, text) }
    }

    func testProseAndSpotifyStayOut() {
        for text in ["I turned off the wifi yesterday", "The brightness is fine", "Open Spotify",
                     "Open Taylor Swift from Spotify", "Search for Daft Punk on Spotify", "Lock the door when you leave"] {
            XCTAssertNil(parse(text), text)
        }
    }

    func testSeveralCommandsJoinedByAnd() {
        let context = CommandRegistry.Context(installedApps: apps)
        let steps = CommandRegistry.plan("Turn off Wi-Fi and then open Safari", context: context)
        XCTAssertEqual(steps?.map(\.command), [.system(.wifi(on: false)), .system(.openApp("Safari"))])
        XCTAssertEqual(CommandRegistry.plan("Mute and take a screenshot", context: context)?.count, 2)
    }

    func testTurkishSettingIgnoresEnglishRules() {
        UserDefaults.standard.set("tr", forKey: "language")
        XCTAssertNil(parse("Turn the brightness up"))
        XCTAssertEqual(parse("Safari'yi aç"), .openApp("Safari"))
    }
}
