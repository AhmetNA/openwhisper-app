import AppKit
import Foundation
import Observation
import UserNotifications

/// Jarvis's own timers and alarms ("20 dakikalık alarm kur", "yarın sabah 7'de beni uyandır").
/// Unlike reminders they stay out of Apple Reminders: they ring here, out loud, until stopped.
///
/// A one-second wall-clock tick fires them, so a Mac that slept through the time rings as
/// soon as it wakes. Each one also has a system notification as a backup for when Jarvis
/// isn't running; its "Kapat" / "5 dk ertele" buttons come back through `handleAction`.
/// Saved to `timers.json`, so a restart keeps them.
@Observable
@MainActor
final class TimerManager {
    static let shared = TimerManager()

    struct JarvisTimer: Codable, Identifiable, Equatable {
        let id: UUID
        let fireDate: Date
        let label: String?
        /// The countdown length; nil for a wall-clock alarm.
        let seconds: Int?
    }

    nonisolated static let notificationCategory = "JARVIS_TIMER"
    nonisolated static let stopAction = "JARVIS_TIMER_STOP"
    nonisolated static let snoozeAction = "JARVIS_TIMER_SNOOZE"
    private static let notificationPrefix = "jarvis-timer-"

    /// Rounds of three chimes, `ringPause` apart, before a ringing alarm gives up on its own.
    private static let ringRounds = 5
    private static let ringPause: TimeInterval = 15
    /// A timer missed by more than this while Jarvis wasn't running is dropped, not rung.
    private static let missedGrace: TimeInterval = 120

    /// Pending, soonest first.
    private(set) var timers: [JarvisTimer] = []
    /// The one sounding now.
    private(set) var ringing: JarvisTimer?

    /// Called on the main actor when a timer goes off (after the first chimes have started).
    var onFire: ((JarvisTimer) -> Void)?
    /// Called when one of `ReminderManager`'s reminders comes due while Jarvis runs.
    var onReminderDue: ((ReminderManager.Reminder) -> Void)?

    private var tick: Timer?
    private var ringTask: Task<Void, Never>?
    private var lastTick = Date()
    /// Notifications, the tick and `timers.json` only inside Jarvis.app: unit tests run
    /// AppState without a bundle, where `UNUserNotificationCenter.current()` traps.
    private static let insideApp = Bundle.main.bundleURL.pathExtension == "app"
    private let notificationCenter: UNUserNotificationCenter? = insideApp ? .current() : nil
    private let storageURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("OpenWhisper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("timers.json")
    }()

    private init() {
        guard let notificationCenter else { return }
        let stop = UNNotificationAction(identifier: Self.stopAction, title: "Kapat")
        let snooze = UNNotificationAction(identifier: Self.snoozeAction, title: "5 dk ertele")
        let category = UNNotificationCategory(identifier: Self.notificationCategory, actions: [stop, snooze], intentIdentifiers: [])
        Task { @MainActor [notificationCenter] in
            let others = await notificationCenter.notificationCategories().filter { $0.identifier != Self.notificationCategory }
            notificationCenter.setNotificationCategories(others.union([category]))
        }
        load()
        startTicking()
    }

    // MARK: - Commands

    /// Carries out a parsed command and returns what Jarvis says back.
    func perform(_ command: TimerCommandParser.Command, now: Date = Date()) -> String {
        switch command {
        case .start(let seconds, let label):
            let timer = add(JarvisTimer(id: UUID(), fireDate: now.addingTimeInterval(TimeInterval(seconds)), label: label, seconds: seconds))
            let what = label.map { "\($0) için " } ?? ""
            return "\(SpokenDuration.spoken(seconds)) sonra \(what)haber veririm, saat \(Self.clock(timer.fireDate, now: now))"
        case .alarm(let date, let label):
            let timer = add(JarvisTimer(id: UUID(), fireDate: date, label: label, seconds: nil))
            return "Alarm kuruldu: \(Self.clock(timer.fireDate, now: now, sayDay: true))"
        case .remaining:
            guard let next = timers.first else { return "Kurulu bir alarm yok" }
            let left = Self.spokenLeft(next.fireDate.timeIntervalSince(now))
            let others = timers.count > 1 ? ". Toplam \(timers.count) alarm var" : ""
            return "\(next.label.map { "\($0) için " } ?? "")\(left) kaldı\(others)"
        case .cancel(let all):
            if ringing != nil, !all {
                stopRinging()
                return "Alarmı kapattım"
            }
            guard !timers.isEmpty || ringing != nil else { return "Kurulu bir alarm yok" }
            let removed = all ? timers : Array(timers.prefix(1))
            remove(removed)
            if all { stopRinging() }
            return removed.count > 1 ? "\(removed.count) alarmı iptal ettim" : "Alarmı iptal ettim"
        case .stop:
            guard ringing != nil else { return "Çalan bir alarm yok" }
            stopRinging()
            return "Tamam"
        case .snooze(let seconds):
            guard let current = ringing else { return "Çalan bir alarm yok" }
            stopRinging()
            _ = add(JarvisTimer(id: UUID(), fireDate: now.addingTimeInterval(TimeInterval(seconds)), label: current.label, seconds: current.seconds))
            return "\(SpokenDuration.spoken(seconds)) sonra tekrar haber veririm"
        }
    }

    /// "Kapat" / "5 dk ertele" on the notification.
    func handleAction(_ identifier: String, notificationID: String) {
        guard notificationID.hasPrefix(Self.notificationPrefix) else { return }
        owLog("[Timer] Notification action \(identifier)")
        let id = UUID(uuidString: String(notificationID.dropFirst(Self.notificationPrefix.count)))
        // The notification can arrive before the tick: make that timer the ringing one first.
        if ringing?.id != id, let timer = timers.first(where: { $0.id == id }) {
            remove([timer])
            ringing = timer
        }
        switch identifier {
        case Self.snoozeAction: _ = perform(.snooze(seconds: TimerCommandParser.defaultSnooze))
        default: stopRinging()
        }
    }

    func stopRinging() {
        guard let current = ringing else { return }
        owLog("[Timer] Stopped ringing \(current.id)")
        ringing = nil
        ringTask?.cancel()
        ringTask = nil
        notificationCenter?.removeDeliveredNotifications(withIdentifiers: [Self.notificationPrefix + current.id.uuidString])
    }

    func cancel(_ timer: JarvisTimer) { remove([timer]) }

    // MARK: - Ringing

    private func startTicking() {
        tick?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in TimerManager.shared.onTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func onTick(now: Date = Date()) {
        defer { lastTick = now }
        if let due = timers.first, due.fireDate <= now {
            remove([due], keepNotification: true)
            fire(due)
        }
        // Reminders come due through the same clock, so Jarvis can say them.
        for reminder in ReminderManager.shared.reminders where reminder.fireDate > lastTick && reminder.fireDate <= now {
            owLog("[Timer] Reminder due: \(reminder.task)")
            onReminderDue?(reminder)
        }
    }

    private func fire(_ timer: JarvisTimer) {
        stopRinging()
        owLog("[Timer] Firing \(timer.id) (\(timer.label ?? "no label"))")
        ringing = timer
        ringTask = Task { @MainActor [weak self] in
            for round in 0..<Self.ringRounds {
                for _ in 0..<3 {
                    guard !Task.isCancelled, self?.ringing?.id == timer.id else { return }
                    NSSound(named: "Glass")?.play()
                    try? await Task.sleep(for: .milliseconds(900))
                }
                if round == 0 { self?.onFire?(timer) }
                try? await Task.sleep(for: .seconds(Self.ringPause))
            }
            guard let self, self.ringing?.id == timer.id else { return }
            owLog("[Timer] Nobody stopped \(timer.id); giving up")
            self.ringing = nil
        }
    }

    // MARK: - Storage and notifications

    private func add(_ timer: JarvisTimer) -> JarvisTimer {
        timers.append(timer)
        timers.sort { $0.fireDate < $1.fireDate }
        save()
        scheduleNotification(for: timer)
        owLog("[Timer] Set \(timer.id) for \(timer.fireDate) (\(timer.seconds.map { "\($0) s" } ?? "alarm"), label: \(timer.label ?? "-"))")
        return timer
    }

    private func remove(_ removed: [JarvisTimer], keepNotification: Bool = false) {
        let ids = Set(removed.map(\.id))
        timers.removeAll { ids.contains($0.id) }
        save()
        if !keepNotification {
            notificationCenter?.removePendingNotificationRequests(withIdentifiers: removed.map { Self.notificationPrefix + $0.id.uuidString })
        }
    }

    private func scheduleNotification(for timer: JarvisTimer) {
        let content = UNMutableNotificationContent()
        content.title = timer.seconds == nil ? "Jarvis Alarm" : "Jarvis Zamanlayıcı"
        content.body = timer.label.map { "\($0) — süre doldu" } ?? (timer.seconds.map { "\(SpokenDuration.spoken($0)) doldu" } ?? "Alarm çalıyor")
        content.sound = .default
        content.categoryIdentifier = Self.notificationCategory
        let interval = max(1, timer.fireDate.timeIntervalSinceNow)
        let request = UNNotificationRequest(
            identifier: Self.notificationPrefix + timer.id.uuidString,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        notificationCenter?.add(request) { error in
            if let error { owLog("[Timer] Notification schedule failed: \(error)") }
        }
    }

    private func save() {
        guard Self.insideApp else { return }
        do {
            try JSONEncoder().encode(timers).write(to: storageURL, options: .atomic)
        } catch {
            owLog("[Timer] Save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let saved = try? JSONDecoder().decode([JarvisTimer].self, from: data) else { return }
        let now = Date()
        // Missed while Jarvis was off: the system notification already told the user.
        timers = saved.filter { $0.fireDate > now.addingTimeInterval(-Self.missedGrace) }.sorted { $0.fireDate < $1.fireDate }
        if timers.count != saved.count { save() }
        owLog("[Timer] Loaded \(timers.count) timer(s)")
    }

    // MARK: - Wording

    /// "15:51", or "yarın 07:00" / "17 Ekim Cumartesi 07:00" when it isn't today.
    nonisolated static func clock(_ date: Date, now: Date = Date(), sayDay: Bool = false, calendar: Calendar = .current) -> String {
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        let hm = time.string(from: date)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return sayDay ? "bugün \(hm)" : hm
        case 1: return "yarın \(hm)"
        default:
            let day = DateFormatter()
            day.locale = Locale(identifier: "tr_TR")
            day.dateFormat = "d MMMM EEEE"
            return "\(day.string(from: date)) \(hm)"
        }
    }

    /// Time left, rounded up to the minute above one minute ("12 dakika", "45 saniye").
    nonisolated static func spokenLeft(_ interval: TimeInterval) -> String {
        let seconds = max(1, Int(interval.rounded(.up)))
        return seconds < 60 ? "\(seconds) saniye" : SpokenDuration.spoken(Int((Double(seconds) / 60).rounded(.up)) * 60)
    }
}
