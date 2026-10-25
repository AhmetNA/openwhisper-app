import Foundation

/// Correlates streaming ASR and routing even before a saved-recording trace exists.
/// Text stays in existing local logs; no new audio capture or remote upload.
enum SpeechDiagnostics {
    @TaskLocal static var outcome: SpeechOutcome?
    @TaskLocal static var session: String?
    @TaskLocal static var batch: Int?
    @TaskLocal static var decodeID: String?

    static var context: String {
        guard session != nil || decodeID != nil else { return "" }
        return "[speech=\(session ?? "unbound")\(batch.map { " batch=\($0)" } ?? "")\(decodeID.map { " decode=\($0)" } ?? "")] "
    }

    /// Completion callbacks do not inherit task locals; bind both IDs explicitly.
    static func withTrace<T>(_ id: String, recording: UUID?, outcome: SpeechOutcome? = nil, operation: () throws -> T) rethrows -> T {
        try $session.withValue(id) {
            try $outcome.withValue(outcome ?? Self.outcome) {
                try VoiceTrace.$current.withValue(recording, operation: operation)
            }
        }
    }

    static func json(_ fields: [String: String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let result = String(data: data, encoding: .utf8) else { return "{}" }
        return result
    }

    static func event(_ stage: String, _ fields: [String: String] = [:]) {
        outcome?.record(stage, fields)
        var fields = fields
        fields["stage"] = stage
        fields["schema"] = "1"
        fields["speech"] = session ?? "unbound"
        if let decodeID { fields["decode"] = decodeID }
        if let batch { fields["batch"] = String(batch) }
        owLog("[SpeechDiag] " + json(fields))
    }

    static func text(_ stage: String, _ value: String, previous: String? = nil) {
        var fields = ["text": value, "characters": String(value.count),
                      "words": String(value.split(whereSeparator: \.isWhitespace).count)]
        if let previous {
            fields["changed"] = String(previous != value)
            fields["characterDelta"] = String(value.count - previous.count)
        }
        event(stage, fields)
    }
}

/// One routing pass, including callbacks that finish before delivery returns. Values are
/// reported outcomes, never inferred success from a selected route or a requested action.
final class SpeechOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: [String]] = [:]

    func record(_ stage: String, _ fields: [String: String]) {
        let category: String
        switch stage {
        case "route.selected": category = "routes"
        case "action.begin": category = "attempts"
        case "ui.message": category = "screenMessages"
        case "action.result": category = "actions"
        case "reply.result": category = "replies"
        case "delivery.result": category = "deliveries"
        case "output.skipped", "asr.discard", "capture.discard": category = "reasons"
        default: return
        }
        lock.lock()
        defer { lock.unlock() }
        entries[category, default: []].append(SpeechDiagnostics.json(fields))
    }

    var summary: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: String] = [:]
        for key in ["routes", "attempts", "actions", "replies", "deliveries", "screenMessages", "reasons"] {
            result[key] = entries[key]?.joined(separator: " | ") ?? "none_reported"
        }
        result["assessment"] = entries["actions"] == nil && entries["replies"] == nil && entries["deliveries"] == nil && entries["screenMessages"] == nil
            ? "no_action_result_reported" : "see_reported_results"
        if entries["reasons"] == nil && result["assessment"] == "no_action_result_reported" {
            result["reasons"] = "routing_finished_without_output; inspect route and batch events"
        }
        return result
    }
}
