import XCTest
@testable import OpenWhisper

@MainActor
final class ReminderManagerSchemaTests: XCTestCase {
    func testOlderPersistedReminderDecodesWithoutAppleIdentifier() throws {
        let json = #"[{"id":"old","task":"Toplantı","fireDate":812181600,"createdAt":812141696}]"#
        let reminders = try JSONDecoder().decode([ReminderManager.Reminder].self, from: Data(json.utf8))
        XCTAssertEqual(reminders.first?.id, "old")
        XCTAssertNil(reminders.first?.appleReminderIdentifier)
    }

    func testParsesSpecificReminderDeletion() {
        XCTAssertEqual(
            ReminderManager.deletionRequest("Toplantı hatırlatıcısını sil."),
            .init(query: "Toplantı", deleteAll: false)
        )
        XCTAssertEqual(
            ReminderManager.deletionRequest("1.6 saniye yaklaşık 8 saniye düşün toplantıyı hatırlatıcıyı sil."),
            .init(query: "1.6 saniye yaklaşık 8 saniye düşün toplantıyı", deleteAll: false)
        )
    }

    func testParsesExplicitDeleteAllWithoutWipingOnBareDelete() {
        XCTAssertEqual(
            ReminderManager.deletionRequest("Tüm hatırlatıcıları sil"),
            .init(query: nil, deleteAll: true)
        )
        XCTAssertEqual(
            ReminderManager.deletionRequest("Hatırlatıcıların hepsini kaldır"),
            .init(query: nil, deleteAll: true)
        )
        XCTAssertEqual(
            ReminderManager.deletionRequest("Hatırlatıcıyı sil"),
            .init(query: nil, deleteAll: false)
        )
    }

    func testDeletionParserRejectsUnscopedOrNarrativeDeleteText() {
        XCTAssertNil(ReminderManager.deletionRequest("Toplantı dosyasını sil"))
        XCTAssertNil(ReminderManager.deletionRequest("Silinen hatırlatıcı neden geri geldi?"))
    }

    func testReminderTitleMatchingHandlesTurkishSuffixesAndRecordedPrefix() {
        XCTAssertTrue(ReminderManager.reminderTitle("Toplantı", matches: "toplantıyı"))
        XCTAssertTrue(ReminderManager.reminderTitle(
            "Jarvis 1.6 saniye yaklaşık 8 saniye düşün toplantıyı",
            matches: "1.6 saniye yaklaşık 8 saniye düşün toplantıyı"
        ))
        XCTAssertFalse(ReminderManager.reminderTitle("Faturayı öde", matches: "toplantı"))
    }

    func testDeletionMatchesSpokenCommandsFromLogs() throws {
        let title = "Jarvis 1.6 saniye yaklaşık 8 saniye düşün toplantıyı"
        let cal = Calendar.current
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 9, minute: 55)))
        let due = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 9)))
        let tomorrow = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: due))

        for spoken in [
            "bir çarvis 1.6 saniye yaklaşık 8 saniye diye bir hatırlatıcı var onu sil",
            "1.6 saniye yaklaşık 8 saniye hatırlatıcısı var onu siler misin?",
            "Bugün saat 9'da olan hatırlatıcıyı sil.",
            "Bugün saat 9'daki hatırlatıcıyı sil.",
        ] {
            let request = try XCTUnwrap(ReminderManager.deletionRequest(spoken), spoken)
            XCTAssertTrue(ReminderManager.request(request, matchesTitle: title, due: due, now: now), spoken)
            XCTAssertFalse(ReminderManager.request(request, matchesTitle: "Orkideyi sula", due: tomorrow, now: now), spoken)
        }

        let timeOnly = try XCTUnwrap(ReminderManager.deletionRequest("Bugün saat 9'daki hatırlatıcıyı sil."))
        XCTAssertNil(timeOnly.query)
        XCTAssertEqual(timeOnly.time, .init(dayOffset: 0, hour: 9, minute: 0))
        XCTAssertFalse(ReminderManager.request(timeOnly, matchesTitle: title, due: tomorrow, now: now))
    }

    func testRepeatedDeleteCommandIsNotAnAnswer() {
        // A repeat of the command must reach the new-request path, not count as "no".
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Var annemlere babamlara hatırlatıcısını siler misin?"), .unclear)
        XCTAssertNotNil(ReminderManager.deletionRequest("Var annemlere babamlara hatırlatıcısını siler misin?"))
        XCTAssertNil(ReminderManager.deletionRequest("Evet onaylıyorum"))
    }

    func testDeletionConfirmationRequiresExplicitShortApproval() {
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Onaylıyorum"), .approve)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Jarvis, evet onaylıyorum."), .approve)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Tamam sil"), .approve)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Evet, silebilirsin."), .approve)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Evet sil lütfen"), .approve)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Hayır silme lütfen"), .reject)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Hayır, silme"), .reject)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Onaylamıyorum"), .reject)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Toplantı güzel geçti"), .unclear)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Evet ama önce bir düşün"), .unclear)
    }

    func testSetFitConfirmationNeverApprovesAlone() {
        // A confident SetFit "approve" deletes only when the exact word list agrees.
        XCTAssertEqual(ReminderManager.setFitConfirmation(label: "approve", confident: true, text: "Evet, silebilirsin."), .approve)
        XCTAssertNil(ReminderManager.setFitConfirmation(label: "approve", confident: true, text: "Olaylı."))
        XCTAssertNil(ReminderManager.setFitConfirmation(label: "approve", confident: false, text: "Evet"))
        // Rejecting is safe: nothing is deleted.
        XCTAssertEqual(ReminderManager.setFitConfirmation(label: "reject", confident: true, text: "Kalsın."), .reject)
        XCTAssertNil(ReminderManager.setFitConfirmation(label: "reject", confident: false, text: "Kalsın."))
        // "unclear" goes to Ollama, which also sees the other decodes.
        XCTAssertNil(ReminderManager.setFitConfirmation(label: "unclear", confident: true, text: "Hangisi?"))
    }

    func testOllamaResponseSchemaRequiresTaskAndDatetimeStrings() throws {
        let schema = ReminderManager.ollamaResponseSchema
        XCTAssertTrue(JSONSerialization.isValidJSONObject(schema))
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(["task", "datetime"]))
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)

        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["task"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((properties["datetime"] as? [String: Any])?["type"] as? String, "string")
    }
}
