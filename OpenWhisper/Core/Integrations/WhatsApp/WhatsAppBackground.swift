import AppKit

/// Keeps Desktop syncing without taking focus or opening a chat.
@MainActor
enum WhatsAppBackground {
    private static let bundleID = "net.whatsapp.WhatsApp"
    private static var launchTask: Task<Void, Error>?

    enum Failure: Error { case notInstalled }

    static func ensureRunning() async throws {
        // A voice request and the watcher may arrive during the same cold start.
        if let launchTask { return try await launchTask.value }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw Failure.notInstalled
        }
        let task = Task { @MainActor in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            // Launch completion is not a sync acknowledgement. Give Desktop a short head
            // start; the watcher continues checking for later arrivals every five seconds.
            try await Task.sleep(for: .seconds(3))
        }
        launchTask = task
        defer { launchTask = nil }
        try await task.value
    }
}
