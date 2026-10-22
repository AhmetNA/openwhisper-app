import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import OpenWhisper

final class JarvisHotkeyTests: XCTestCase {

    private func accepted(_ result: JarvisHotkey.CaptureResult) -> JarvisHotkey? {
        if case .accepted(let key) = result { return key }
        return nil
    }

    func testFunctionKeyAcceptedAndMatchesIgnoringFn() throws {
        let key = try XCTUnwrap(accepted(JarvisHotkey.capture(
            keyCode: UInt16(kVK_F5), flags: .maskSecondaryFn, characters: nil)))
        XCTAssertEqual(key.label, "F5")
        XCTAssertTrue(key.matchesKeyDown(keyCode: Int64(kVK_F5), flags: []))
        XCTAssertTrue(key.matchesKeyDown(keyCode: Int64(kVK_F5), flags: .maskSecondaryFn))
        XCTAssertFalse(key.matchesKeyDown(keyCode: Int64(kVK_F5), flags: .maskCommand))
        XCTAssertFalse(key.matchesKeyDown(keyCode: Int64(kVK_F6), flags: []))
    }

    func testComboRequiresSameModifiers() throws {
        let key = try XCTUnwrap(accepted(JarvisHotkey.capture(
            keyCode: UInt16(kVK_ANSI_J), flags: .maskAlternate, characters: "j")))
        XCTAssertEqual(key.label, "⌥J")
        XCTAssertTrue(key.matchesKeyDown(keyCode: Int64(kVK_ANSI_J), flags: .maskAlternate))
        XCTAssertFalse(key.matchesKeyDown(keyCode: Int64(kVK_ANSI_J), flags: []))
        XCTAssertFalse(key.matchesKeyDown(keyCode: Int64(kVK_ANSI_J), flags: [.maskAlternate, .maskShift]))
    }

    func testRejectsFnBareTypingKeysSpaceAndEnter() {
        XCTAssertNil(accepted(JarvisHotkey.capture(keyCode: JarvisHotkey.fnKeyCode, flags: [], characters: nil)))
        XCTAssertNil(accepted(JarvisHotkey.capture(keyCode: UInt16(kVK_ANSI_J), flags: [], characters: "j")))
        XCTAssertNil(accepted(JarvisHotkey.capture(keyCode: UInt16(kVK_Space), flags: [], characters: " ")))
        XCTAssertNil(accepted(JarvisHotkey.capture(keyCode: UInt16(kVK_Return), flags: [], characters: "\r")))
    }

    func testLoneModifierNeverMatchesKeyDown() throws {
        let key = try XCTUnwrap(accepted(JarvisHotkey.captureModifier(keyCode: UInt16(kVK_RightOption))))
        XCTAssertTrue(key.isModifierKey)
        XCTAssertEqual(JarvisHotkey.flag(forModifierKey: key.keyCode), .maskAlternate)
        XCTAssertFalse(key.matchesKeyDown(keyCode: Int64(kVK_RightOption), flags: .maskAlternate))
        XCTAssertNil(accepted(JarvisHotkey.captureModifier(keyCode: UInt16(kVK_CapsLock))))
    }

    func testAppleSpecialKeyCodeAcceptedBare() throws {
        let key = try XCTUnwrap(accepted(JarvisHotkey.capture(keyCode: 176, flags: [], characters: nil)))
        XCTAssertEqual(key.label, "Özel tuş 176")
    }

    func testSystemKeyMessageNamesTheKeyAndFix() {
        let message = JarvisHotkey.systemKeyMessage(nxKeyType: 22)
        XCTAssertTrue(message.contains("klavye ışığı"))
        XCTAssertTrue(message.contains("fn"))
    }

    func testCodableRoundTrip() throws {
        let key = JarvisHotkey(keyCode: UInt16(kVK_F13), modifiers: 0, isModifierKey: false, label: "F13")
        let decoded = try JSONDecoder().decode(JarvisHotkey.self, from: JSONEncoder().encode(key))
        XCTAssertEqual(decoded, key)
    }

    // MARK: Typed request shortcut

    private func scratchDefaults() -> UserDefaults {
        let name = "JarvisHotkeyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testTypedRequestShortcutDefaultsToControlM() {
        let key = JarvisHotkey.loadTypedRequest(from: scratchDefaults())
        XCTAssertEqual(key, JarvisHotkey.typedRequestDefault)
        XCTAssertEqual(key?.label, "⌃M")
        XCTAssertEqual(key?.matchesKeyDown(keyCode: Int64(kVK_ANSI_M), flags: .maskControl), true)
        // Fn is ignored; another modifier is a different shortcut.
        XCTAssertEqual(key?.matchesKeyDown(keyCode: Int64(kVK_ANSI_M), flags: [.maskControl, .maskSecondaryFn]), true)
        XCTAssertEqual(key?.matchesKeyDown(keyCode: Int64(kVK_ANSI_M), flags: [.maskControl, .maskShift]), false)
        XCTAssertEqual(key?.matchesKeyDown(keyCode: Int64(kVK_ANSI_M), flags: []), false)
    }

    func testRemovedTypedRequestShortcutStaysRemoved() {
        let defaults = scratchDefaults()
        JarvisHotkey.saveTypedRequest(nil, to: defaults)
        XCTAssertNil(JarvisHotkey.loadTypedRequest(from: defaults))
    }

    func testChosenTypedRequestShortcutIsLoaded() throws {
        let defaults = scratchDefaults()
        let key = try XCTUnwrap(accepted(JarvisHotkey.capture(
            keyCode: UInt16(kVK_ANSI_J), flags: [.maskAlternate, .maskShift], characters: "j"
        )))
        JarvisHotkey.saveTypedRequest(key, to: defaults)
        XCTAssertEqual(JarvisHotkey.loadTypedRequest(from: defaults), key)
    }

    func testSameKeyIgnoresTheLabel() {
        let a = JarvisHotkey(keyCode: UInt16(kVK_ANSI_M), modifiers: CGEventFlags.maskControl.rawValue,
                             isModifierKey: false, label: "⌃M")
        var b = a
        b.label = "⌃Ö"
        XCTAssertTrue(a.sameKey(as: b))
        b.modifiers = CGEventFlags.maskAlternate.rawValue
        XCTAssertFalse(a.sameKey(as: b))
    }
}
