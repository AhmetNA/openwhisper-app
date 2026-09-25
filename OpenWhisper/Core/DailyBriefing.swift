import EventKit
import Foundation
import UserNotifications

/// "Bugün ne var?": the day's calendar events, reminders due by the end of it (overdue
/// included) and unread mail, gathered locally. A one-line summary goes to the flow bar, the
/// full list to a notification that stays in Notification Center.
enum DailyBriefing {
    struct Summary: Equatable {
        var title: String
        var events: [String]
        var reminders: [String]
        var unreadMailCount: Int?
        var mail: [String]

        /// Flow bar line: counts plus the next thing on the calendar.
        var headline: String {
            var parts: [String] = []
            parts.append(events.isEmpty ? "etkinlik yok" : "\(events.count) etkinlik")
            if !reminders.isEmpty { parts.append("\(reminders.count) hatırlatıcı") }
            if let unreadMailCount, unreadMailCount > 0 { parts.append("\(unreadMailCount) okunmamış mail") }
            let first = events.first.map { " — ilk: \($0)" } ?? ""
            return "\(title): " + parts.joined(separator: " · ") + first
        }

        /// Notification body, one section per source.
        var body: String {
            var lines: [String] = []
            lines.append(events.isEmpty ? "📅 Etkinlik yok" : "📅 " + events.joined(separator: "\n📅 "))
            if !reminders.isEmpty { lines.append("☑️ " + reminders.joined(separator: "\n☑️ ")) }
            if let unreadMailCount {
                lines.append(unreadMailCount == 0 ? "✉️ Okunmamış mail yok"
                             : "✉️ \(unreadMailCount) okunmamış: " + mail.joined(separator: " · "))
            }
            return lines.joined(separator: "\n")
        }
    }

    private static let store = EKEventStore()

    /// `dayOffset` 0 = today, 1 = tomorrow.
    static func build(dayOffset: Int, now: Date = Date()) async -> Summary {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let dayEvents = await events(from: dayStart, to: dayEnd)
        let dueReminders = await reminders(dueBefore: dayEnd)
        // Mail only describes now, so tomorrow's briefing leaves it out.
        let unread = dayOffset == 0 ? await MailController.unreadCount() : nil
        let mail = dayOffset == 0 ? await MailController.unreadMessages(limit: 3) ?? [] : []
        return Summary(
            title: dayOffset == 0 ? "Bugün" : "Yarın",
            events: dayEvents,
            reminders: dueReminders,
            unreadMailCount: unread,
            mail: mail.map { "\($0.sender): \($0.subject)" }
        )
    }

    /// Posts the full briefing; asks for notification permission the first time.
    static func notify(_ summary: Summary) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = "Jarvis — \(summary.title)"
        content.body = summary.body
        let request = UNNotificationRequest(identifier: "daily-briefing", content: content, trigger: nil)
        do { try await center.add(request) } catch { owLog("[Briefing] Notification failed: \(error)") }
    }

    private static func events(from start: Date, to end: Date) async -> [String] {
        guard (try? await store.requestFullAccessToEvents()) == true else {
            owLog("[Briefing] Calendar access not granted")
            return []
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return store.events(matching: predicate)
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map { event in
                let title = event.title ?? "Etkinlik"
                return event.isAllDay ? "Tüm gün: \(title)" : "\(formatter.string(from: event.startDate)) \(title)"
            }
    }

    private static func reminders(dueBefore end: Date) async -> [String] {
        guard (try? await store.requestFullAccessToReminders()) == true else {
            owLog("[Briefing] Reminders access not granted")
            return []
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { continuation.resume(returning: $0 ?? []) }
        }
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        // Due components often carry no calendar, so `.date` alone would be nil.
        func due(_ reminder: EKReminder) -> Date? {
            reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
        }
        return reminders
            .sorted { (due($0) ?? .distantPast) < (due($1) ?? .distantPast) }
            .map { reminder in
                let title = reminder.title ?? "Hatırlatıcı"
                guard let due = due(reminder) else { return title }
                if due < Calendar.current.startOfDay(for: now) { return "\(title) (gecikmiş)" }
                let hasTime = reminder.dueDateComponents?.hour != nil
                return hasTime ? "\(formatter.string(from: due)) \(title)" : title
            }
    }
}
