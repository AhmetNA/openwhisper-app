import AppKit
import EventKit
import Foundation

/// What Jarvis can see right now, handed to the chat model so "ne çalıyor?", "sıradaki
/// toplantım ne?" or "alarm kaç dakika sonra?" get a real answer instead of "erişimim yok".
/// Everything is read locally; a source that is slow or not allowed is simply left out.
struct JarvisContext: Equatable, Sendable {
    var frontApp: String?
    /// The front app's window title and selected text (`JarvisAppContext`).
    var windowTitle: String?
    var selectedText: String?
    /// The front app's own lines: Safari tab, selected mail, Claude/Codex chat.
    var appDetails: [String] = []
    /// "Çalıyor: Tarkan — Kuzu Kuzu, albüm Karma, 1:23 / 3:45, …" / "Duraklatıldı: …".
    var nowPlaying: String?
    /// Spotify's next tracks, "Tarkan — Şımarık"; only with the Web API connected.
    var upNext: [String] = []
    /// "14:05 alarm", "3 dakika sonra: çay".
    var timers: [String] = []
    /// Today's remaining events, "15:30 Toplantı"; nil when the calendar can't be read.
    var upcomingEvents: [String]?

    var isEmpty: Bool {
        frontApp == nil && windowTitle == nil && selectedText == nil && appDetails.isEmpty
            && nowPlaying == nil && upNext.isEmpty && timers.isEmpty && upcomingEvents == nil
    }

    /// Lines for the system prompt, one per source.
    var promptLines: [String] {
        var lines: [String] = []
        if let frontApp { lines.append("Ön plandaki uygulama: \(frontApp)") }
        if let windowTitle { lines.append("Pencere başlığı: \(windowTitle)") }
        if let selectedText { lines.append("Seçili metin: \(selectedText)") }
        lines += appDetails
        if let nowPlaying { lines.append("Spotify: \(nowPlaying)") }
        if !upNext.isEmpty { lines.append("Spotify'da sıradaki: \(upNext.joined(separator: "; "))") }
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
    /// The front app's reader may read a page, a mail or a transcript tail, so it gets longer.
    static let appTimeout: Duration = .milliseconds(600)

    @MainActor
    static func gather(now: Date = Date()) async -> JarvisContext {
        var context = JarvisContext()
        let front = NSWorkspace.shared.frontmostApplication.flatMap { app in
            app.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : app
        }
        context.frontApp = front?.localizedName
        if let front {
            (context.windowTitle, context.selectedText) = JarvisAppContext.windowAndSelection(front)
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
        let (pid, bundleID, windowTitle) = (front?.processIdentifier, front?.bundleIdentifier, context.windowTitle)
        async let details = withTimeout(appTimeout) { () async -> [String] in
            guard let pid else { return [] }
            return await JarvisAppContext.details(pid: pid, bundleID: bundleID, windowTitle: windowTitle)
        }
        async let track = withTimeout(timeout) { await spotifyTrack() }
        async let queue = withTimeout(timeout) { await spotifyQueue() }
        context.appDetails = await details ?? []
        context.nowPlaying = await track ?? nil
        context.upNext = context.nowPlaying == nil ? [] : (await queue ?? nil) ?? []
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

    private static var spotifyRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    /// nil when Spotify isn't running (asking would cold-launch it) or has no track.
    private static func spotifyTrack() async -> String? {
        guard spotifyRunning else { return nil }
        let script = """
            tell application "Spotify"
                set sep to character id 31
                set t to current track
                return (player state as text) & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & \
                    ((player position as integer) as text) & sep & (((duration of t) / 1000) as integer as text) & sep & \
                    (sound volume as text) & sep & (shuffling as text) & sep & (repeating as text)
            end tell
            """
        guard let reply = await osascript(script) else { return nil }
        let fields = reply.components(separatedBy: "\u{1F}")
        guard fields.count >= 9, !fields[1].isEmpty else { return nil }
        var label = fields[2].isEmpty ? fields[1] : "\(fields[2]) — \(fields[1])"
        if !fields[3].isEmpty { label += ", albüm \(fields[3])" }
        if let position = Int(fields[4]), let duration = Int(fields[5]), duration > 0 {
            label += ", \(VideoController.clock(position)) / \(VideoController.clock(duration))"
        }
        label += ", ses %\(fields[6]), karışık çalma \(fields[7] == "true" ? "açık" : "kapalı"), tekrar \(fields[8] == "true" ? "açık" : "kapalı")"
        return "\(fields[0] == "playing" ? "Çalıyor" : "Duraklatıldı"): \(label)"
    }

    /// The next three tracks; empty without a connected Web API.
    private static func spotifyQueue() async -> [String] {
        guard spotifyRunning, SpotifyCredentialsStore.hasRefreshToken(),
              let queue = try? await SpotifyWebAPI.shared.fetchQueue() else { return [] }
        return queue.prefix(3).map { $0.artist.isEmpty ? $0.name : "\($0.artist) — \($0.name)" }
    }

    /// Runs an AppleScript off the main thread; nil when it fails.
    static func osascript(_ script: String) async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
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
