import Foundation

/// One mic in the user's priority list. `lastSeen` is the last moment it was known connected.
struct MicPriorityEntry: Codable, Equatable, Sendable {
    let uid: String
    var name: String
    var isBluetooth: Bool
    var lastSeen: Date
}

/// The user's ordered mic list: every recording uses the highest-ranked connected mic. A mic
/// that was not connected for three days drops off the list; when it (or any mic the list has
/// not seen) connects, it goes on top. Known mics always retain their saved position.
enum MicPriority {
    static let defaultsKey = "inputPriority"
    static let forgetAfter: TimeInterval = 3 * 24 * 60 * 60

    /// The list after a device change. `wasConnected` are the mics connected up to now (including
    /// the ones that just went away): they are stamped first, so a mic that stayed connected for
    /// days without a device event is not forgotten the moment it is unplugged. Then mics unseen
    /// for three days and still absent are forgotten. Currently connected known mics are refreshed
    /// before pruning, including after an app restart. Connected mics the list doesn't hold are added: on top,
    /// or at the end in `seedRank` order when the list is first built.
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
        result.removeAll { now.timeIntervalSince($0.lastSeen) >= forgetAfter }
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
        return seeding ? result + added : added + result
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
