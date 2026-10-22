import Foundation

extension AppState {
    enum CalendarRequest: Equatable {
        case event(CalendarEventParser.Event)
        /// Asked for an event but named no day and no time.
        case needsDate
    }

    /// SetFit's `calendar_intent` says whether the sentence asks for a new event; the parser
    /// only reads its date, time and title. Nil when SetFit is off, unsure, or says otherwise:
    /// the sentence is then dictated or chatted as before.
    func calendarEventRequest(_ text: String, now: Date = Date()) async -> CalendarRequest? {
        guard let decision = await SetFitDecider.decide(.calendarIntent, text: text),
              decision.confident, decision.label == "add_event" else { return nil }
        return Self.calendarRequest(text, now: now)
    }

    nonisolated static func calendarRequest(_ text: String, now: Date = Date()) -> CalendarRequest {
        CalendarEventParser.extract(text, now: now).map(CalendarRequest.event) ?? .needsDate
    }
}
