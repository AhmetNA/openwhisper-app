import Foundation

/// Claude Code's PermissionRequest hook asks Jarvis (`ClaudePermissionServer`): the question is
/// said out loud and the spoken answer becomes the hook's decision. No answer leaves Claude's
/// own prompt in charge. Pure, so it is unit-tested.
enum ClaudePermission {
    struct Request {
        let tool: String
        let input: [String: Any]
        let cwd: String?
        /// Claude's "don't ask again" rules for this call, echoed back for "her zaman".
        let suggestions: [Any]

        init?(json: Data) {
            guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let tool = object["tool_name"] as? String else { return nil }
            self.tool = tool
            input = object["tool_input"] as? [String: Any] ?? [:]
            cwd = object["cwd"] as? String
            suggestions = object["permission_suggestions"] as? [Any] ?? []
        }

        var project: String? {
            guard let cwd else { return nil }
            let name = URL(fileURLWithPath: cwd).lastPathComponent
            return name.isEmpty || name == "/" ? nil : name
        }
    }

    enum Answer: Equatable {
        case allow
        /// Allowed, with Claude's suggested rule saved so it isn't asked again.
        case always
        /// Denied; the rest of the sentence ("hayır, önce testleri çalıştır") goes to Claude.
        case deny(String?)
    }

    /// "Bitirme projesinde Claude bir komut çalıştırmak istiyor: Run the tests. İzin veriyor musun?"
    /// The command itself is not read out (`detail` shows it).
    static func question(for request: Request) -> String {
        let who = request.project.map { "\($0) projesinde Claude" } ?? "Claude"
        return "\(who) \(action(of: request)). İzin veriyor musun?"
    }

    private static func action(of request: Request) -> String {
        let input = request.input
        switch request.tool {
        case "Bash":
            let what = (input["description"] as? String).flatMap(nonEmpty)
                ?? (input["command"] as? String).map { String($0.prefix(60)) }
            return what.map { "bir komut çalıştırmak istiyor: \($0)" } ?? "bir komut çalıştırmak istiyor"
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = input["file_path"] as? String ?? input["notebook_path"] as? String
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "bir"
            return request.tool == "Write" ? "\(name) dosyasını yazmak istiyor" : "\(name) dosyasını düzenlemek istiyor"
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host }
            return host.map { "\($0) adresini açmak istiyor" } ?? "bir web sayfasını açmak istiyor"
        case "WebSearch":
            return "web'de arama yapmak istiyor"
        default:
            let parts = request.tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" {
                return "\(parts[1]) aracını kullanmak istiyor: \(parts[2...].joined(separator: " "))"
            }
            return "\(request.tool) aracını kullanmak istiyor"
        }
    }

    /// What is asked, in full, for the Flow bar: the command, the file, or the tool.
    static func detail(for request: Request) -> String {
        let input = request.input
        let what = (input["command"] as? String) ?? (input["file_path"] as? String)
            ?? (input["notebook_path"] as? String) ?? (input["url"] as? String) ?? (input["query"] as? String)
        return "Claude izin istiyor · \(request.tool)" + (what.map { ": \(String($0.prefix(200)))" } ?? "")
    }

    private static let denyWords: Set<String> = [
        "hayır", "reddet", "olmaz", "yok", "iptal", "vazgeç", "dur", "istemiyorum", "yapma", "çalıştırma", "durdur",
    ]
    private static let allowAnswers: Set<String> = [
        "evet", "tamam", "olur", "onayla", "onaylıyorum", "izin ver", "izin veriyorum", "evet izin ver", "ver",
        "devam", "devam et", "yap", "evet yap", "tabii", "tabii ki", "aynen", "çalıştır", "evet çalıştır", "evet tamam",
    ]
    private static let fillers: Set<String> = ["jarvis", "lütfen", "efendim"]

    /// Only a plain yes allows: a call that runs code is never approved on a guess. A "no" may
    /// carry what to do instead. Nil when the answer is neither.
    static func answer(_ text: String) -> Answer? {
        let words = words(text).filter { !fillers.contains($0) }
        guard let first = words.first else { return nil }
        let joined = words.joined(separator: " ")
        if denyWords.contains(first) || joined.hasPrefix("izin verme") {
            return .deny(instruction(in: text))
        }
        if joined.contains("her zaman") || joined.contains("bir daha sorma") { return .always }
        return allowAnswers.contains(joined) ? .allow : nil
    }

    /// "Hayır, önce testleri çalıştır." → "önce testleri çalıştır"; nil for a bare no.
    private static func instruction(in text: String) -> String? {
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        // The no itself ("hayır hayır", "Jarvis, izin verme") is not part of the message.
        while let first = tokens.first,
              words(first).allSatisfy({ fillers.contains($0) || denyWords.contains($0) || $0 == "izin" || $0 == "verme" }) {
            tokens.removeFirst()
        }
        guard tokens.count >= 2 else { return nil }
        return tokens.joined(separator: " ").trimmingCharacters(in: CharacterSet.letters.inverted)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
    }

    /// The hook's stdout for `answer`.
    static func hookOutput(_ answer: Answer, request: Request) -> Data {
        var decision: [String: Any]
        switch answer {
        case .allow:
            decision = ["behavior": "allow"]
        case .always:
            decision = ["behavior": "allow"]
            if !request.suggestions.isEmpty { decision["updatedPermissions"] = request.suggestions }
        case .deny(let message):
            decision = ["behavior": "deny", "message": message ?? "Kullanıcı sesle reddetti."]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
    }

    /// What Jarvis says once the answer is sent.
    static func reply(to answer: Answer, request: Request) -> String {
        switch answer {
        case .allow: "Tamam, izin verdim."
        case .always: request.suggestions.isEmpty ? "Tamam, izin verdim." : "Tamam, bir daha sormayacak."
        case .deny(nil): "Tamam, reddettim."
        case .deny: "Reddettim, Claude'a ilettim."
        }
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
