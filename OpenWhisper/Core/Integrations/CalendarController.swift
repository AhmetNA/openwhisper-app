import EventKit
import Foundation

/// Saves a `CalendarEventParser.Event` to the default calendar (or the first writable one).
enum CalendarController {
    private static let store = EKEventStore()

    static func add(_ event: CalendarEventParser.Event, now: Date = Date()) async -> String {
        guard (try? await store.requestFullAccessToEvents()) == true else {
            owLog("[Calendar] Access not granted (status \(EKEventStore.authorizationStatus(for: .event).rawValue))")
            return "Takvim izni yok"
        }
        let calendar = store.defaultCalendarForNewEvents.flatMap { $0.allowsContentModifications ? $0 : nil }
            ?? store.calendars(for: .event).first { $0.allowsContentModifications }
        guard let calendar else {
            owLog("[Calendar] No writable calendar")
            return "Yazılabilir takvim yok"
        }
        let item = EKEvent(eventStore: store)
        item.calendar = calendar
        item.title = event.title
        item.isAllDay = event.allDay
        item.startDate = event.start
        // An all-day event ending on its own day; start + 1 day shows up as two days.
        item.endDate = event.allDay ? event.start : event.start.addingTimeInterval(TimeInterval(event.minutes * 60))
        do {
            try store.save(item, span: .thisEvent, commit: true)
            owLog("[Calendar] Added '\(event.title)' at \(event.start) (all day: \(event.allDay), \(event.minutes) min) to \(calendar.title)")
            return "Takvime eklendi: \(event.title), \(when(event, now: now))"
        } catch {
            owLog("[Calendar] Save failed: \(error)")
            return "Takvime eklenemedi"
        }
    }

    /// "bugün 15:00", "yarın tüm gün", "3 Ekim Cuma 19:30".
    static func when(_ event: CalendarEventParser.Event, now: Date = Date(), calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: event.start)).day ?? 0
        let day: String
        switch days {
        case 0: day = "bugün"
        case 1: day = "yarın"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "tr_TR")
            formatter.dateFormat = "d MMMM EEEE"
            day = formatter.string(from: event.start)
        }
        if event.allDay { return "\(day) tüm gün" }
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        return "\(day) \(time.string(from: event.start))"
    }
}
