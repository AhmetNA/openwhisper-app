import Foundation

/// Send permission must be outside the literal message body. The model chooses intent;
/// this proof prevents quoted "gönder", "gönderme" and hallucinated flags pressing Return.
enum CloudDictationDelivery {
    static func hasExplicitSend(source: String, body: String) -> Bool {
        guard !body.isEmpty, let span = source.range(of: body, options: .backwards) else { return false }
        let before = String(source[..<span.lowerBound])
        var after = String(source[span.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        // A suffix is an instruction only if it is outside a quoted body. A closing quote
        // followed by an actual directive is fine; "merhaba gönder" inside quotes is not.
        after = after.replacingOccurrences(of: #"^[\s.,;:!?]*(?:(?:ve\s+)?(?:sonra|sonrasında|ardından)\s+|ve\s+)?"#,
                                           with: "", options: [.regularExpression, .caseInsensitive])
        if AgentCommandParser.isExistingMessageSend(after) { return true }
        // Explicit named prefix: "Codex'e gönder: merhaba". Do not use the legacy parser's
        // permissive trailing-send regex as authorization for a cloud-generated send flag.
        let prefix = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\b(?:gönder|gonder|yolla|ilet)(?:\s*[:;,]\s*|\s*)$"#
        guard prefix.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil,
              let parsed = AgentCommandParser.parse(source), parsed.target != nil,
              parsed.send, parsed.body == body else { return false }
        return true
    }
}
