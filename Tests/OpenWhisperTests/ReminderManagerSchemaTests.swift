import XCTest
@testable import OpenWhisper

@MainActor
final class ReminderManagerSchemaTests: XCTestCase {
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
