import AppKit

/// Brings a coding agent's app to the front so a dictation addressed to it by name can be
/// pasted there. Jarvis is a menu-bar (accessory) app: on macOS 14 cooperative activation
/// may ignore `NSRunningApplication.activate`, so this goes through `openApplication`,
/// which also launches the app when it is not running.
@MainActor
enum AgentAppActivator {
    /// The frontmost agent app, or nil when it is not installed or never came to the front.
    static func activate(_ agent: AgentApp) async -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           let bundleID = front.bundleIdentifier,
           agent.bundleIdentifiers.contains(bundleID) {
            return front
        }

        for bundleID in agent.bundleIdentifiers {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                continue
            }
            let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true

            let pid: pid_t
            do {
                pid = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier
            } catch {
                owLog("[Agent] Could not open \(agent.displayName) (\(bundleID)): \(error.localizedDescription)")
                continue
            }

            // A cold launch needs a few seconds before its window and composer exist.
            let deadline = Date().addingTimeInterval(wasRunning ? 2 : 10)
            while Date() < deadline {
                if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == pid {
                    // Give the window a moment to restore keyboard focus to its text field.
                    try? await Task.sleep(nanoseconds: wasRunning ? 250_000_000 : 2_000_000_000)
                    owLog("[Agent] \(agent.displayName) is frontmost (pid \(pid), launched: \(!wasRunning))")
                    return front
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            owLog("[Agent] \(agent.displayName) did not come to the front in time")
            return nil
        }
        owLog("[Agent] \(agent.displayName) is not installed")
        return nil
    }
}
