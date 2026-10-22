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
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func resolve(_ priority: [String], trigger: RecordingTrigger?, devices: [AudioInputDevice],
                         chained: String? = nil) -> String? {
        AppState.inputDeviceUID(priority: priority, trigger: trigger, devices: devices, chainedUID: chained)
    }

    private func entry(_ device: AudioInputDevice, seen: Date) -> MicPriorityEntry {
        MicPriorityEntry(uid: device.uid, name: device.name, isBluetooth: device.isBluetooth, lastSeen: seen)
    }

    func testTopConnectedMicWinsForEveryTrigger() {
        for trigger in [RecordingTrigger.wakeWord, .fnHold, .jarvisKey, .followUp, .external, nil] {
            XCTAssertEqual(resolve(["usb", "mac", "buds"], trigger: trigger, devices: [mac, usb, buds]), "usb")
        }
    }

    /// The reported bug: the top mic unplugged sent key-started recordings to the buds.
    func testUnpluggedTopMicFallsToNextRankNotToHeadset() {
        for trigger in [RecordingTrigger.wakeWord, .fnHold, .keyboardShortcut] {
            XCTAssertEqual(resolve(["usb", "mac", "buds"], trigger: trigger, devices: [mac, buds]), "mac")
        }
    }

    func testHeadsetRankedFirstRecordsFromHeadset() {
        XCTAssertEqual(resolve(["buds", "mac"], trigger: .wakeWord, devices: [mac, buds]), "buds")
        XCTAssertEqual(resolve(["buds", "mac"], trigger: .fnHold, devices: [mac]), "mac")
    }

    func testFollowUpStaysOnTheSessionMic() {
        XCTAssertEqual(resolve(["usb", "mac"], trigger: .followUp, devices: [mac, usb], chained: "mac"), "mac")
        XCTAssertEqual(resolve(["usb", "mac"], trigger: .confirmation, devices: [mac, usb], chained: "gone"), "usb")
    }

    func testMacMicWhenNothingInTheListIsConnected() {
        XCTAssertEqual(resolve([], trigger: .fnHold, devices: [mac, buds]), "mac")
    }

    func testWakeListenerUsesTopNonBluetoothMicLikeTheVoiceSession() {
        let device = WakeWordListener.listeningDevice(priority: ["usb", "mac"], devices: [mac, usb, buds])
        XCTAssertEqual(device?.uid, "usb")
        // The handoff only works when the voice session resolves the same mic.
        XCTAssertEqual(device?.uid, resolve(["usb", "mac"], trigger: .wakeWord, devices: [mac, usb, buds]))
    }

    func testWakeListenerSkipsBluetooth() {
        XCTAssertEqual(WakeWordListener.listeningDevice(priority: ["buds", "usb", "mac"], devices: [mac, usb, buds])?.uid, "usb")
        XCTAssertEqual(WakeWordListener.listeningDevice(priority: ["usb"], devices: [mac, buds])?.uid, "mac")
        XCTAssertNil(WakeWordListener.listeningDevice(priority: ["buds"], devices: [buds]))
    }

    func testNewMicGoesOnTop() {
        let list = [entry(mac, seen: start)]
        let updated = MicPriority.updated(list, wasConnected: ["mac"], connected: [mac, usb], now: start + 60)
        XCTAssertEqual(updated.map(\.uid), ["usb", "mac"])
    }

    func testFirstRunKeepsOldPickOnTopAndOrdersTheRest() {
        let list = [MicPriorityEntry(uid: "usb", name: "AI Wireless Microphone", isBluetooth: false, lastSeen: start)]
        let seeded = MicPriority.updated(list, wasConnected: [], connected: [buds, mac], now: start, seeding: true)
        XCTAssertEqual(seeded.map(\.uid), ["usb", "mac", "buds"])
    }

    func testReturningWithinThreeDaysKeepsItsPlace() {
        let list = [entry(mac, seen: start), entry(buds, seen: start)]
        let updated = MicPriority.updated(list, wasConnected: ["mac"], connected: [mac, buds], now: start + 2 * day)
        XCTAssertEqual(updated.map(\.uid), ["mac", "buds"])
    }

    func testMicUnseenForThreeDaysIsForgottenAndReturnsOnTop() {
        let list = [entry(mac, seen: start), entry(buds, seen: start)]
        let later = start + 3 * day + 60
        let pruned = MicPriority.updated(list, wasConnected: ["mac"], connected: [mac], now: later)
        XCTAssertEqual(pruned.map(\.uid), ["mac"])
        let back = MicPriority.updated(list, wasConnected: ["mac"], connected: [mac, buds], now: later)
        XCTAssertEqual(back.map(\.uid), ["buds", "mac"])
    }

    func testUnpluggingAfterALongConnectionDoesNotForget() {
        let list = [entry(usb, seen: start), entry(mac, seen: start)]
        let updated = MicPriority.updated(list, wasConnected: ["usb", "mac"], connected: [mac], now: start + 5 * day)
        XCTAssertEqual(updated.map(\.uid), ["usb", "mac"])
    }

    func testExternalMicFollowsPriority() {
        let other = AudioInputDevice(id: 4, uid: "usb2", name: "Other USB", isBluetooth: false,
                                     hasOutputStream: false, isBuiltIn: false)
        XCTAssertEqual(AppState.connectedExternalInput(priority: ["usb2", "usb"], devices: [mac, usb, other])?.uid, "usb2")
        XCTAssertEqual(AppState.connectedExternalInput(priority: [], devices: [mac, usb, other])?.uid, "usb")
    }
}
