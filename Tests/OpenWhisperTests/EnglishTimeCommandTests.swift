import XCTest
@testable import OpenWhisper

/// Timers, reminders and calendar events while the dictation language is English.
@MainActor
final class EnglishTimeCommandTests: XCTestCase {
    private var savedLanguage: String?
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }()
    /// Sunday 1 November 2026, 15:00.
    private var now: Date { date(day: 1, hour: 15) }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    override func setUp() {
        savedLanguage = UserDefaults.standard.string(forKey: "language")
        UserDefaults.standard.set("en", forKey: "language")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedLanguage, forKey: "language")
    }

    private func timer(_ text: String, ringing: Bool = false, active: Bool = false) -> TimerCommandParser.Command? {
        TimerCommandParser.parse(text, ringing: ringing, active: active, now: now, calendar: calendar)
    }

    func testCountdowns() {
        XCTAssertEqual(timer("Set a timer for 10 minutes"), .start(seconds: 600, label: nil))
        XCTAssertEqual(timer("Set a timer for five minutes for tea"), .start(seconds: 300, label: "tea"))
        XCTAssertEqual(timer("Start a 20-minute timer"), .start(seconds: 1200, label: nil))
        XCTAssertEqual(timer("Timer for an hour and a half"), .start(seconds: 5400, label: nil))
        XCTAssertEqual(timer("10 minute pasta timer"), .start(seconds: 600, label: "pasta"))
        XCTAssertEqual(timer("Remind me in half an hour"), .start(seconds: 1800, label: nil))
        XCTAssertEqual(timer("Wake me up in 20 minutes"), .start(seconds: 1200, label: nil))
    }

    func testAlarmsAndControls() {
        XCTAssertEqual(timer("Set an alarm for 7 am"), .alarm(at: date(day: 2, hour: 7), label: nil))
        XCTAssertEqual(timer("Wake me up tomorrow at 6:30"), .alarm(at: date(day: 2, hour: 6, minute: 30), label: nil))
        XCTAssertEqual(timer("Set an alarm for 7"), .alarm(at: date(day: 1, hour: 19), label: nil))
        XCTAssertEqual(timer("How much time is left on the timer?"), .remaining)
        XCTAssertEqual(timer("How long is left", active: true), .remaining)
        XCTAssertEqual(timer("Cancel the timer"), .cancel(all: false))
        XCTAssertEqual(timer("Cancel all alarms"), .cancel(all: true))
        XCTAssertEqual(timer("Okay thanks", ringing: true), .stop)
        XCTAssertEqual(timer("Snooze for 10 minutes", ringing: true), .snooze(seconds: 600))
        XCTAssertNil(timer("Remind me to call mom in 10 minutes"))
        XCTAssertNil(timer("Cancel the sleep timer"))
    }

    func testReminders() {
        func reminder(_ text: String) -> TurkishDateParser.ParsedResult? {
            EnglishTimeCommands.reminder(text, now: now, calendar: calendar)
        }
        XCTAssertEqual(reminder("Remind me to call mom tomorrow at 3"),
                       .init(task: "Call mom", fireDate: date(day: 2, hour: 15)))
        XCTAssertEqual(reminder("Remind me in 20 minutes to check the oven"),
                       .init(task: "Check the oven", fireDate: now.addingTimeInterval(1200)))
        XCTAssertEqual(reminder("Remind me to send the report on Monday"),
                       .init(task: "Send the report", fireDate: date(day: 2, hour: 9)))
        XCTAssertEqual(reminder("Set a reminder to buy milk tonight at 8"),
                       .init(task: "Buy milk", fireDate: date(day: 1, hour: 20)))
        XCTAssertNil(reminder("Remind me to call mom"))
    }

    func testCalendar() {
        func event(_ text: String) -> CalendarEventParser.Event? {
            guard case .event(let event)? = EnglishTimeCommands.calendarRequest(text, now: now, calendar: calendar) else { return nil }
            return event
        }
        XCTAssertEqual(event("Schedule a meeting with Ali tomorrow at 3"),
                       .init(title: "Meeting with Ali", start: date(day: 2, hour: 15), allDay: false, minutes: 60))
        XCTAssertEqual(event("Add a dentist appointment on Friday at 10 am to my calendar for 30 minutes"),
                       .init(title: "Dentist appointment", start: date(day: 6, hour: 10), allDay: false, minutes: 30))
        XCTAssertEqual(event("Add an event called launch day next Monday"),
                       .init(title: "Launch day", start: date(day: 2, hour: 0), allDay: true, minutes: 60))
        XCTAssertEqual(EnglishTimeCommands.calendarRequest("Schedule a call with the team", now: now, calendar: calendar), .needsDate)
        XCTAssertNil(EnglishTimeCommands.calendarRequest("Add this song to my playlist", now: now, calendar: calendar))
        XCTAssertNil(EnglishTimeCommands.calendarRequest("I have a meeting tomorrow at 3", now: now, calendar: calendar))
    }

    func testTurkishSettingKeepsTurkishTimers() {
        UserDefaults.standard.set("tr", forKey: "language")
        XCTAssertNil(timer("Set a timer for 10 minutes"))
        XCTAssertEqual(timer("10 dakikalık alarm kur"), .start(seconds: 600, label: nil))
    }
}
