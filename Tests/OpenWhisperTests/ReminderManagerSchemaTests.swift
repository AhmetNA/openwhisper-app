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

    func testDeletionConfirmationRequiresExplicitShortApproval() {
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Onaylıyorum"), .approve)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Jarvis, evet onaylıyorum."), .approve)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Tamam sil"), .approve)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Hayır, silme"), .reject)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Onaylamıyorum"), .reject)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Toplantı güzel geçti"), .unclear)
        XCTAssertEqual(ReminderManager.deletionConfirmationDecision("Evet ama önce bir düşün"), .unclear)
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
