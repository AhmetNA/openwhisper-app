import Foundation

/// Whether a macOS Focus (Do Not Disturb, Work, ...) is on. macOS has no public way to ask without
/// a provisioned entitlement, so this reads its own record of active Focus modes, which takes the
/// Full Disk Access WhatsApp reading already needs. Unreadable means off.
enum FocusStatus {
    private static let assertionsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    static var isOn: Bool {
        guard let data = try? Data(contentsOf: assertionsFile) else { return false }
        return isOn(assertions: data)
    }

    static func isOn(assertions data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stores = root["data"] as? [[String: Any]] else { return false }
        return stores.contains { ($0["storeAssertionRecords"] as? [Any])?.isEmpty == false }
    }
}
