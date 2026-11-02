import Foundation

/// One mic in the user's priority list. `lastSeen` is the last moment it was known connected.
struct MicPriorityEntry: Codable, Equatable, Sendable {
    let uid: String
    var name: String
    var isBluetooth: Bool
    var lastSeen: Date
}

/// The user's permanent mic order. Disconnected devices retain their saved position;
/// newly discovered devices are appended so they cannot override the user's preference.
enum MicPriority {
    static let defaultsKey = "inputPriority"

    /// Refresh device metadata without removing or reordering saved entries.
    /// The first run orders newly discovered devices after the old single pick.
    static func updated(
        _ list: [MicPriorityEntry], wasConnected: Set<String>, connected: [AudioInputDevice],
        now: Date, seeding: Bool = false
    ) -> [MicPriorityEntry] {
        let connectedUIDs = Set(connected.map(\.uid))
        var result = list.map { entry -> MicPriorityEntry in
            var entry = entry
            if wasConnected.contains(entry.uid) || connectedUIDs.contains(entry.uid) { entry.lastSeen = now }
            return entry
        }
        for device in connected {
            guard let index = result.firstIndex(where: { $0.uid == device.uid }) else { continue }
            result[index].name = device.name
            result[index].isBluetooth = device.isBluetooth
            result[index].lastSeen = now
        }
        var newDevices = connected.filter { device in !result.contains { $0.uid == device.uid } }
        if seeding { newDevices.sort { seedRank($0) < seedRank($1) } }
        let added = newDevices.map {
            MicPriorityEntry(uid: $0.uid, name: $0.name, isBluetooth: $0.isBluetooth, lastSeen: now)
        }
        return result + added
    }

    /// First-run order after the old single pick: Mac mic, other wired/USB mics, then headsets.
    private static func seedRank(_ device: AudioInputDevice) -> Int {
        device.isBuiltIn ? 0 : device.isBluetooth ? 2 : 1
    }

    /// The highest-ranked connected mic that passes `allowed`.
    static func top(
        _ priority: [String], devices: [AudioInputDevice],
        where allowed: (AudioInputDevice) -> Bool = { _ in true }
    ) -> AudioInputDevice? {
        for uid in priority {
            if let device = devices.first(where: { $0.uid == uid }), allowed(device) { return device }
        }
        return nil
    }
}
