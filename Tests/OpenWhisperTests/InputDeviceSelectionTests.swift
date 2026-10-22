import XCTest
import CoreAudio
@testable import OpenWhisper

@MainActor
final class InputDeviceSelectionTests: XCTestCase {
    private let mac = AudioInputDevice(id: 1, uid: "mac", name: "MacBook Air Microphone",
                                       isBluetooth: false, hasOutputStream: false, isBuiltIn: true)
    private let usb = AudioInputDevice(id: 2, uid: "usb", name: "AI Wireless Microphone",
                                       isBluetooth: false, hasOutputStream: false, isBuiltIn: false)
    private let buds = AudioInputDevice(id: 3, uid: "buds", name: "Redmi Buds 5 Pro",
                                        isBluetooth: true, hasOutputStream: true, isBuiltIn: false)

    private func resolve(picked: String?, trigger: RecordingTrigger?, devices: [AudioInputDevice],
                         defaultID: AudioDeviceID? = 1) -> String? {
        AppState.inputDeviceUID(picked: picked, trigger: trigger, devices: devices,
                                defaultInputID: defaultID, chainedBluetoothUID: nil)
    }

    func testConnectedPickedMicWinsForEveryTrigger() {
        for trigger in [RecordingTrigger.wakeWord, .fnHold, .followUp, .external] {
            XCTAssertEqual(resolve(picked: "usb", trigger: trigger, devices: [mac, usb, buds], defaultID: 3), "usb")
        }
    }

    func testUnpluggedPickedMicFallsBackToMacMic() {
        XCTAssertEqual(resolve(picked: "usb", trigger: .wakeWord, devices: [mac]), "mac")
        XCTAssertEqual(resolve(picked: "usb", trigger: .fnHold, devices: [mac]), "mac")
    }

    func testUnpluggedPickedMicFallsBackToHeadsetForKeyStartedRecording() {
        XCTAssertEqual(resolve(picked: "usb", trigger: .fnHold, devices: [mac, buds]), "buds")
        // A voice session keeps the Mac mic, like automatic mode, so buds don't enter call mode.
        XCTAssertEqual(resolve(picked: "usb", trigger: .wakeWord, devices: [mac, buds]), "mac")
    }

    func testReplugRestoresPickedMic() {
        XCTAssertEqual(resolve(picked: "usb", trigger: .fnHold, devices: [mac]), "mac")
        XCTAssertEqual(resolve(picked: "usb", trigger: .fnHold, devices: [mac, usb]), "usb")
    }

    func testAutomaticModeLeavesVoiceSessionsOnSystemDefault() {
        XCTAssertNil(resolve(picked: nil, trigger: .wakeWord, devices: [mac, usb], defaultID: 2))
        XCTAssertEqual(resolve(picked: nil, trigger: .wakeWord, devices: [mac, buds], defaultID: 3), "buds")
    }

    func testWakeListenerUsesConnectedPickedMicLikeTheVoiceSession() {
        let device = WakeWordListener.listeningDevice(pickedUID: "usb", devices: [mac, usb, buds])
        XCTAssertEqual(device?.uid, "usb")
        // The handoff only works when the voice session resolves the same mic.
        XCTAssertEqual(device?.uid, resolve(picked: "usb", trigger: .wakeWord, devices: [mac, usb, buds], defaultID: 3))
    }

    func testWakeListenerFallsBackToMacMic() {
        XCTAssertEqual(WakeWordListener.listeningDevice(pickedUID: "usb", devices: [mac, buds])?.uid, "mac")
        XCTAssertEqual(WakeWordListener.listeningDevice(pickedUID: nil, devices: [mac, usb])?.uid, "mac")
        // Picked buds would enter call mode while the listener holds their mic.
        XCTAssertEqual(WakeWordListener.listeningDevice(pickedUID: "buds", devices: [mac, buds])?.uid, "mac")
        XCTAssertNil(WakeWordListener.listeningDevice(pickedUID: "buds", devices: [buds]))
    }
}
