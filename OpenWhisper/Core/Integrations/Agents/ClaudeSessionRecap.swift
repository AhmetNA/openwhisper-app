import Foundation

/// "Claude'da son session'ı özetle": the Claude Code session the user worked in last, and two
/// short spoken sentences on what it did. The desktop app keeps each session's metadata (title,
/// last activity, its own turn recap) in `ClaudeProjectStore.sessionsDirectory`, and the
/// conversation itself under `~/.claude/projects`.
enum ClaudeSessionRecap {
    struct Session: Equatable, Sendable {
        /// The desktop app's id ("local_…"), for its `claude://code/continue` link.
        let id: String
        let title: String
        let lastActivity: Date
        /// The CLI transcript's file name, without ".jsonl".
        let transcriptID: String?
        /// The app's own recap of the last turn; nil when it is missing or from an earlier turn.
        let storedRecap: String?
    }

    // MARK: - Pure

    /// The session in one metadata file, nil for an archived or never-answered one.
    static func session(fromJSON data: Data) -> Session? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["sessionId"] as? String,
              (json["isArchived"] as? Bool) != true,
              (json["completedTurns"] as? Int ?? 0) > 0 else { return nil }
        let millis = (json["lastActivityAt"] as? Double) ?? (json["createdAt"] as? Double) ?? 0
        // The recap only belongs to the last answer when the app summarized that very answer.
        let summary = json["postTurnSummary"] as? [String: Any]
        let fresh = (summary?["summarizes_uuid"] as? String).map { $0 == json["lastAssistantUuid"] as? String } ?? false
        let recap = fresh
            ? [(json["turnWrapUp"] as? [String: Any])?["description"] as? String, summary?["status_detail"] as? String]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            : nil
        return Session(id: id, title: (json["title"] as? String) ?? "", lastActivity: Date(timeIntervalSince1970: millis / 1000),
                       transcriptID: json["cliSessionId"] as? String, storedRecap: recap)
    }

    /// Text of the last assistant message in a CLI transcript (one JSON object per line).
    static func lastAssistantText(inTranscript text: String) -> String? {
        var last: String?
        for line in text.split(separator: "\n") where line.contains("\"assistant\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "assistant", json["isSidechain"] as? Bool != true,
                  let content = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            let texts = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            if let text = texts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { last = text }
        }
        return last
    }

    static func prompt(title: String, storedRecap: String?, lastMessage: String?) -> String {
        var lines = ["Oturum başlığı: \(title)"]
        if let storedRecap { lines.append("Uygulamanın kısa özeti: \(storedRecap)") }
        if let lastMessage { lines.append("Asistanın son mesajı:\n\(String(lastMessage.prefix(3000)))") }
        return """
        Aşağıda bir Claude Code kodlama oturumunun son durumu var. Kullanıcıya sesli okunacak, en fazla iki kısa \
        Türkçe cümlelik bir özet yaz: ne yapıldı, ne kaldı ya da ne bekleniyor. Kod, dosya yolu, commit kodu, \
        markdown, madde işareti kullanma; teknik adları sade söyle. Yalnızca özeti yaz.

        \(lines.joined(separator: "\n"))
        """
    }

    /// Speakable text cut to its first two sentences; a sentence the model left unfinished
    /// (its token budget ran out) is dropped when a whole one comes before it.
    static func twoSentences(_ text: String) -> String? {
        var buffer = JarvisChat.speakable(text) + " "
        let sentences = JarvisChat.takeSentences(from: &buffer).prefix(2)
        let result = sentences.isEmpty ? buffer.trimmingCharacters(in: .whitespaces) : sentences.joined(separator: " ")
        return result.isEmpty ? nil : result
    }

    /// The whole answer after a recap is a "no" ("Boş ver.", "Vazgeçtim", "İptal et"): nothing
    /// is sent. Only the phrase alone, so "iptal butonunu düzelt" is still a message.
    static func isCancel(_ text: String) -> Bool {
        let lowered = text.lowercased(with: Locale(identifier: "tr_TR"))
        let pattern = #"^\s*(?:(?:tamam|yok|hayır)[\s,]+)?(?:boş\s*ver\p{L}*|vazgeç\p{L}*|iptal(?:\s+et\p{L}*)?|gerek\s+yok|göndermeyelim|gönderme|unut\s+gitsin)(?:[\s,]+(?:o\s+zaman|şimdilik|lütfen|teşekkürler|sağ\s+ol))*[\s.!,]*$"#
        return lowered.range(of: pattern, options: .regularExpression) != nil
    }

    /// Without a model: the app's recap, or the first two sentences of the last message.
    static func fallbackSummary(storedRecap: String?, lastMessage: String?) -> String? {
        if let storedRecap { return twoSentences(storedRecap) }
        guard let lastMessage else { return nil }
        return twoSentences(lastMessage.components(separatedBy: "\n\n").first ?? lastMessage)
    }

    // MARK: - Files and model

    /// The session with the newest activity in the Claude desktop app.
    static func latestSession() -> Session? {
        guard let enumerator = FileManager.default.enumerator(at: ClaudeProjectStore.sessionsDirectory,
                                                              includingPropertiesForKeys: nil) else { return nil }
        var newest: Session?
        for case let url as URL in enumerator {
            let file = url.lastPathComponent
            guard file.hasPrefix("local_"), file.hasSuffix(".json"),
                  let data = try? Data(contentsOf: url), let session = session(fromJSON: data),
                  session.lastActivity > newest?.lastActivity ?? .distantPast else { continue }
            newest = session
        }
        return newest
    }

    /// The transcript sits in a folder named after the session's working directory; that name
    /// is not rebuilt here (worktrees, "Kişisel" → "Ki-isel"), every project folder is checked.
    static func lastAssistantText(transcriptID: String) -> String? {
        let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let url = folder.appendingPathComponent("\(transcriptID).jsonl")
            if let text = try? String(contentsOf: url, encoding: .utf8) { return lastAssistantText(inTranscript: text) }
        }
        return nil
    }

    /// Two spoken sentences on `session`: the cloud model when it is chosen, else Ollama, else
    /// the stored text itself.
    static func summary(of session: Session, ollamaModel: String, ollamaAvailable: Bool) async -> String? {
        let lastMessage = session.transcriptID.flatMap(lastAssistantText(transcriptID:))
        let fallback = fallbackSummary(storedRecap: session.storedRecap, lastMessage: lastMessage)
        let messages = [["role": "user", "content": prompt(title: session.title, storedRecap: session.storedRecap, lastMessage: lastMessage)]]
        let client: (any ChatStreaming, String)?
        if ChatBackend.selected == .cloud, let (cloud, model) = CloudLLM.client() {
            client = (cloud, model)
        } else if ollamaAvailable {
            client = (OllamaClient(), ollamaModel)
        } else {
            client = nil
        }
        guard let (chat, model) = client, lastMessage != nil || session.storedRecap != nil else { return fallback }
        let start = Date()
        do {
            var text = ""
            for try await piece in chat.streamChat(LLMChatRequest(model: model, messages: messages, timeout: 15,
                                                                  temperature: 0.3, maxTokens: 160)) { text += piece }
            owLog("[Agent] Claude recap (\(model), \(Int(Date().timeIntervalSince(start) * 1000)) ms): \(text)")
            return twoSentences(text) ?? fallback
        } catch {
            owLog("[Agent] Claude recap model failed: \(ChatFallback.describe(error)); using the stored text")
            return fallback
        }
    }
}
