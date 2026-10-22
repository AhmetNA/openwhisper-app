import Foundation

/// Puts a wall-clock alarm ("saat 7'de alarm kur", "yarın sabah 7'de beni uyandır") in the
/// macOS Clock app, which rings it even when Jarvis isn't running. Clock's "Add Alarm" action
/// has no public API, so this runs the "Jarvis Alarm" shortcut built by
/// `scripts/clock-alarm/make_shortcut.py` (imported once; "Always Allow" on its first run).
/// When the shortcut is missing or fails, the caller falls back to Jarvis's own alarm.
enum ClockAlarm {
    static let shortcutName = "Jarvis Alarm"
    /// A run normally takes 3–7 s; longer means it waits on a prompt nobody answers.
    private static let timeout: TimeInterval = 20

    /// Clock alarms are a time of day that rings at its next occurrence, so only an alarm
    /// within the next 24 hours lands on the right day.
    static func canSet(_ date: Date, now: Date = Date()) -> Bool {
        date > now && date.timeIntervalSince(now) < 24 * 3600
    }

    /// "2026-10-16 07:00|Jarvis": what the shortcut splits into the time and the alarm's name.
    static func input(for date: Date, label: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let name = (label?.isEmpty == false ? label! : "Jarvis").replacingOccurrences(of: "|", with: " ")
        return "\(formatter.string(from: date))|\(name)"
    }

    /// True when the shortcut ran to the end; false when it is missing, failed or hung.
    static func set(_ date: Date, label: String?) async -> Bool {
        let text = input(for: date, label: label)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-alarm-\(UUID().uuidString).txt")
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            owLog("[ClockAlarm] Could not write the input: \(error)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: file) }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", shortcutName, "-i", file.path]
            process.standardOutput = Pipe()
            let errors = Pipe()
            process.standardError = errors
            let started = Date()
            let finished = OnceFlag()
            process.terminationHandler = { process in
                guard finished.claim() else { return }
                let detail = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = process.terminationStatus == 0
                owLog("[ClockAlarm] '\(text)' → status \(process.terminationStatus) in \(Int(Date().timeIntervalSince(started) * 1000)) ms\(detail.isEmpty ? "" : ": \(detail)")")
                continuation.resume(returning: ok)
            }
            do {
                try process.run()
            } catch {
                owLog("[ClockAlarm] shortcuts could not start: \(error)")
                if finished.claim() { continuation.resume(returning: false) }
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard finished.claim() else { return }
                owLog("[ClockAlarm] '\(shortcutName)' did not finish in \(Int(timeout)) s (a permission prompt?); stopping it")
                process.terminate()
                continuation.resume(returning: false)
            }
        }
    }
}

/// Resumes the continuation exactly once, whichever of exit and timeout comes first.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
