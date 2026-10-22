import AppKit
import EventKit
import Foundation

/// What Jarvis can see right now, handed to the chat model so "ne çalıyor?", "sıradaki
/// toplantım ne?" or "alarm kaç dakika sonra?" get a real answer instead of "erişimim yok".
/// Everything is read locally; a source that is slow or not allowed is simply left out.
struct JarvisContext: Equatable, Sendable {
    var frontApp: String?
    /// "Çalıyor: ♪ Tarkan — Kuzu Kuzu" / "Duraklatıldı: …".
    var nowPlaying: String?
    /// "14:05 alarm", "3 dakika sonra: çay".
    var timers: [String] = []
    /// Today's remaining events, "15:30 Toplantı"; nil when the calendar can't be read.
    var upcomingEvents: [String]?

    var isEmpty: Bool { frontApp == nil && nowPlaying == nil && timers.isEmpty && upcomingEvents == nil }

    /// Lines for the system prompt, one per source.
    var promptLines: [String] {
        var lines: [String] = []
        if let frontApp { lines.append("Ön plandaki uygulama: \(frontApp)") }
        if let nowPlaying { lines.append("Spotify: \(nowPlaying)") }
        if !timers.isEmpty { lines.append("Kurulu alarm / zamanlayıcı: \(timers.joined(separator: "; "))") }
        if let upcomingEvents {
            lines.append(upcomingEvents.isEmpty ? "Bugün kalan takvim etkinliği yok"
                         : "Bugün kalan takvim etkinlikleri: \(upcomingEvents.joined(separator: "; "))")
        }
        return lines
    }

    /// Longest the chat waits for the slow sources (Spotify's AppleScript), so the first
    /// spoken sentence isn't held back.
    static let timeout: Duration = .milliseconds(350)

    @MainActor
    static func gather(now: Date = Date()) async -> JarvisContext {
        var context = JarvisContext()
        context.frontApp = NSWorkspace.shared.frontmostApplication.flatMap { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app.localizedName
        }
        context.timers = TimerManager.shared.timers.prefix(3).map { timer in
            let clock = Self.clock(timer.fireDate)
            if timer.seconds != nil {
                let left = max(0, Int(timer.fireDate.timeIntervalSince(now)))
                let what = timer.label.map { ": \($0)" } ?? ""
                return "\(SpokenDuration.spoken(max(left, 1))) sonra (\(clock))\(what)"
            }
            return "\(clock) alarm" + (timer.label.map { ": \($0)" } ?? "")
        }
        context.upcomingEvents = remainingEvents(now: now)
        context.nowPlaying = await withTimeout(timeout) { await spotifyTrack() } ?? nil
        return context
    }

    // MARK: - Sources

    /// Read only when access was already granted; never prompts from inside a chat.
    private static func remainingEvents(now: Date) -> [String]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
            .map { "\(clock($0.startDate)) \($0.title ?? "Etkinlik")" }
    }

    /// nil when Spotify isn't running (asking would cold-launch it) or has no track.
    private static func spotifyTrack() async -> String? {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) else { return nil }
        let script = """
            tell application "Spotify" to return (player state as text) & linefeed & \
            (name of current track) & linefeed & (artist of current track)
            """
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let lines = output.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            guard lines.count >= 3, !lines[1].isEmpty else { return nil }
            let label = lines[2].isEmpty ? lines[1] : "\(lines[2]) — \(lines[1])"
            return "\(lines[0] == "playing" ? "Çalıyor" : "Duraklatıldı"): \(label)"
        }.value
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// The body's result, or nil when it takes longer than `limit`. The body keeps running in
    /// the background after a timeout; nobody waits for it.
    static func withTimeout<T: Sendable>(_ limit: Duration, _ body: @escaping @Sendable () async -> T) async -> T? {
        let once = TimeoutOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task.detached {
                let value = await body()
                if once.claim() { continuation.resume(returning: value) }
            }
            Task.detached {
                try? await Task.sleep(for: limit)
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

/// Lets exactly one of the racing tasks in `JarvisContext.withTimeout` resume the caller.
private final class TimeoutOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
