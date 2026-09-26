import Foundation

/// Free conversation with Jarvis ("Selam diyebilir misin?", "Kara deliği kısaca anlat") through
/// the local Ollama model. Used only for "Jarvis" sessions that are neither a command nor
/// meant for Claude Code / Codex. The reply streams out sentence by sentence so the voice can
/// start on the first sentence while the model is still writing the rest. The last few turns
/// are remembered for ten minutes, so follow-up questions work.
@MainActor
final class JarvisChat {
    static let shared = JarvisChat()

    private static let memory: TimeInterval = 10 * 60
    private static let maxHistoryMessages = 8
    private var history: [[String: String]] = []
    /// The last finished reply, for showing it when it couldn't be spoken.
    private(set) var lastReply: String?
    private var lastTurn = Date.distantPast

    /// Sentences of the reply as they are written. Ends early (possibly empty) when Ollama is
    /// unreachable or slow; the finished reply is added to the conversation history.
    func reply(to text: String, model: String) -> AsyncStream<String> {
        if Date().timeIntervalSince(lastTurn) > Self.memory { history.removeAll() }
        let messages = [["role": "system", "content": Self.systemPrompt(now: Date())]]
            + history
            + [["role": "user", "content": text]]

        lastReply = nil
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                let started = Date()
                var full = ""
                var buffer = ""
                var firstSentenceMs: Int?
                func emit(_ sentences: [String]) {
                    for sentence in sentences.map(Self.speakable) where !sentence.isEmpty {
                        if firstSentenceMs == nil { firstSentenceMs = Int(Date().timeIntervalSince(started) * 1000) }
                        full += (full.isEmpty ? "" : " ") + sentence
                        continuation.yield(sentence)
                    }
                }
                do {
                    for try await piece in Self.stream(messages: messages, model: model) {
                        buffer += piece
                        emit(Self.takeSentences(from: &buffer))
                    }
                    emit([buffer])
                } catch is CancellationError {
                } catch {
                    owLog("[Chat] Ollama request failed: \(error.localizedDescription)")
                }
                let total = Int(Date().timeIntervalSince(started) * 1000)
                owLog("[Chat] '\(text)' → '\(full)' (first sentence \(firstSentenceMs ?? -1) ms, all \(total) ms)")
                self.lastReply = full
                if !full.isEmpty {
                    self.history += [["role": "user", "content": text], ["role": "assistant", "content": full]]
                    self.history = Array(self.history.suffix(Self.maxHistoryMessages))
                    self.lastTurn = Date()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Ollama

    private static func stream(messages: [[String: String]], model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "http://localhost:11434/api/chat")!, timeoutInterval: 10)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: [
                        "model": model,
                        "messages": messages,
                        "stream": true,
                        // Gemma 4 / Qwen 3.5 think first by default, which costs seconds here.
                        "think": false,
                        "keep_alive": LLMCleanup.keepAlive,
                        "options": ["temperature": 0.6, "num_predict": 110],
                    ] as [String: Any])
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    for try await line in bytes.lines {
                        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                        if let piece = (json["message"] as? [String: Any])?["content"] as? String, !piece.isEmpty {
                            continuation.yield(piece)
                        }
                        if json["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Text

    nonisolated static func systemPrompt(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy EEEE, HH:mm"
        return """
        Sen Jarvis'sin: Iron Man'deki J.A.R.V.I.S. gibi sakin, zeki, hafif esprili, sadık bir kişisel asistan. \
        Kullanıcıyla sesli konuşuyorsun; cevapların sesli okunacak.
        Kurallar:
        - Çok kısa ol: genelde tek cümle, en fazla iki kısa cümle. Kullanıcı açıkça detay isterse en fazla dört cümle.
        - Madde işareti, başlık, markdown, emoji, kod kullanma. Düz konuşma dili.
        - Kullanıcı hangi dilde konuştuysa o dilde cevap ver; genelde Türkçe.
        - Kullanıcıya bazen "patron" ya da "efendim" de; bir cevapta en fazla bir kez, her cevapta değil.
        - Bu sohbette internete, hava durumuna, haberlere, e-postaya ve takvime erişimin yok. Güncel bilgi uydurma; bilmiyorsan kısaca söyle.
        - Bilgisayarda bir işlem istenirse ve bu sohbetten yapamıyorsan bunu tek cümleyle söyle, yapmış gibi davranma.
        - Kendi adını ("Jarvis") söyleme.
        Şu an: \(formatter.string(from: now)).
        """
    }

    /// Complete sentences at the start of `buffer`, removed from it. A sentence ends at . ! ?
    /// or … followed by whitespace, so "14.05" or "3.5" never splits.
    nonisolated static func takeSentences(from buffer: inout String) -> [String] {
        var sentences: [String] = []
        var start = buffer.startIndex
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let next = buffer.index(after: index)
            if ".!?…".contains(buffer[index]), next < buffer.endIndex, buffer[next].isWhitespace {
                sentences.append(String(buffer[start..<next]).trimmingCharacters(in: .whitespacesAndNewlines))
                start = next
            }
            index = next
        }
        buffer = String(buffer[start...])
        return sentences.filter { !$0.isEmpty }
    }

    /// Strips what the model sometimes adds anyway and what can't be spoken: markdown marks,
    /// list bullets, emoji.
    nonisolated static func speakable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !"*#`_~".unicodeScalars.contains(scalar) {
            // Digits and # count as emoji too; real emoji all sit above U+2000.
            if scalar.properties.isEmojiPresentation || (scalar.properties.isEmoji && scalar.value > 0x2000) { continue }
            scalars.append(scalar)
        }
        var out = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = out.first, "-•".contains(first) { out = String(out.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return out
    }
}
