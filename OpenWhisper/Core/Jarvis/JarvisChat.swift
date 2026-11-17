import Foundation
import AppKit

/// Free conversation with Jarvis ("Selam diyebilir misin?", "Kara deliği kısaca anlat") through
/// a cloud model (chosen in Settings) with the local Ollama model as its fallback. Used only for "Jarvis" sessions that are neither a command nor
/// meant for Claude Code / Codex. The reply streams out sentence by sentence so the voice can
/// start on the first sentence while the model is still writing the rest. The last few turns
/// are remembered for half an hour, so follow-up questions work.
@MainActor
final class JarvisChat {
    static let shared = JarvisChat()

    private static let memory: TimeInterval = 30 * 60
    private static let maxHistoryMessages = 16
    private var history: [[String: String]] = []
    /// The last finished reply, for showing it when it couldn't be spoken.
    private(set) var lastReply: String?
    /// The "komut olarak anlayamadım" held back by `reply(…, deferUnrecognized: true)`.
    var deferredUnrecognizedReply: String?
    private var lastTurn = Date.distantPast

    /// The last reply while the conversation is still remembered, so a short follow-up
    /// ("peki neden?") can be recognised as talk to Jarvis.
    var recentReply: String? {
        Date().timeIntervalSince(lastTurn) <= Self.memory ? history.last(where: { $0["role"] == "assistant" })?["content"] : nil
    }

    /// Sentences of the reply as they are written. Ends early (possibly empty) when no model is
    /// reachable; the finished reply is added to the conversation history.
    /// `language` is the reply voice's: an English voice gets English answers.
    /// `context` is what Jarvis can see right now (`JarvisContext.promptLines`).
    /// `userFacts` is what the user asked Jarvis to remember (`UserMemory`).
    /// `recalled` is the journal of the past time the user asks about (`JarvisJournal`); empty
    /// for every other question, so the prompt stays short.
    /// `model` is the Ollama model, used alone or when the cloud model fails.
    /// `deferUnrecognized`: a "komut olarak anlayamadım" is not said but kept in
    /// `deferredUnrecognizedReply`, so the cloud can first look for another way (`CommandRescue`).
    func reply(to text: String, model: String, language: ReplyLanguage = .turkish, context: [String] = [], userFacts: [String] = [], recalled: [String] = [],
               deferUnrecognized: Bool = false) -> AsyncStream<String> {
        if Date().timeIntervalSince(lastTurn) > Self.memory { history.removeAll() }
        deferredUnrecognizedReply = nil
        // Both backends can use Exa; local orchestration also supports models without tools.
        let conversation = { (canSearch: Bool) in
            [["role": "system", "content": Self.systemPrompt(now: Date(), language: language, context: context, userFacts: userFacts, recalled: recalled,
                                                             canSearch: canSearch)]]
                + (canSearch ? self.history : self.history.map { $0.filter { $0.key != CloudChatClient.searchedKey } })
                + [["role": "user", "content": text]]
        }
        let screenQuestion = ScreenQuestion.matches(text)
        let screenApp = screenQuestion ? NSWorkspace.shared.frontmostApplication : nil
        let initialMessages = conversation(!screenQuestion && APIKeys.exa.hasKey)

        lastReply = nil
        return AsyncStream { continuation in
            let task = Task { @MainActor in
                let started = Date()
                var messages = initialMessages
                var directAnswer: String?
                if screenQuestion {
                    let prepared = await ScreenQuestion.prepare(for: text, lines: context, model: model, app: screenApp)
                    directAnswer = prepared.answer
                    let evidence = prepared.prompt
                    messages = [["role": "system", "content": "Sen Jarvis’sin. Sesli yanıt veriyorsun; markdown kullanma. " + Self.languageRule(language) + "\n" + evidence],
                                ["role": "user", "content": text]]
                    guard !Task.isCancelled else { continuation.finish(); return }
                }
                let localMessages = messages
                var full = ""
                var buffer = ""
                var firstSentenceMs: Int?
                // After "anlayamadım…" the model only restates it ("Daha açık bir ifade
                // kullanabilir misiniz?"); the rest of the reply is dropped.
                var saidNotUnderstood = false
                @MainActor func emit(_ sentences: [String]) {
                    for original in sentences.map(Self.speakable) where !original.isEmpty && !saidNotUnderstood {
                        var sentence = Self.preventUnsupportedActionClaim(original, for: text)
                        if sentence != original {
                            owLog("[Chat] Blocked unsupported action claim: '\(original)'")
                        } else if Self.isCapabilityRefusal(original) {
                            // The model's own wording varies ("bu sohbet üzerinden … yeteneğim yok");
                            // one fixed sentence keeps it short and says what actually happened.
                            sentence = Self.unrecognizedCommandReply
                        } else if Self.saysNotUnderstood(original) {
                            // A short sentence of ours that already asks the user to say it again.
                            sentence = self.askAgain(from: Self.notUnderstoodReplies)
                        }
                        if sentence == Self.unrecognizedCommandReply {
                            owLog("[Chat] Command not recognized by any router: '\(text)'")
                            sentence = self.askAgain(from: Self.unrecognizedCommandReplies)
                        }
                        if Self.unrecognizedCommandReplies.contains(sentence) || Self.notUnderstoodReplies.contains(sentence) {
                            // Said once is enough; drop the model's follow-up sentences.
                            saidNotUnderstood = true
                        }
                        if deferUnrecognized, Self.unrecognizedCommandReplies.contains(sentence) {
                            self.deferredUnrecognizedReply = sentence
                            continue
                        }
                        if firstSentenceMs == nil { firstSentenceMs = Int(Date().timeIntervalSince(started) * 1000) }
                        full += (full.isEmpty ? "" : " ") + sentence
                        continuation.yield(sentence)
                    }
                }
                let backend = Backend()
                do {
                    if let directAnswer {
                        backend.set("verified price offers")
                        emit([directAnswer])
                    } else {
                    for try await piece in Self.stream(messages: messages, localMessages: localMessages, ollamaModel: model, backend: backend, allowSearch: !screenQuestion) {
                        buffer += piece
                        emit(Self.takeSentences(from: &buffer))
                    }
                    emit([buffer])
                    }
                } catch is CancellationError {
                } catch {
                    owLog("[Chat] \(backend.value) request failed: \(error.localizedDescription)")
                }
                let total = Int(Date().timeIntervalSince(started) * 1000)
                owLog("[Chat] '\(text)' → '\(full)' (\(backend.value), first sentence \(firstSentenceMs ?? -1) ms, all \(total) ms)")
                self.lastReply = full
                if !full.isEmpty {
                    var answer = ["role": "assistant", "content": full]
                    if let query = backend.searched { answer[CloudChatClient.searchedKey] = query }
                    self.history += [["role": "user", "content": text], answer]
                    self.history = Array(self.history.suffix(Self.maxHistoryMessages))
                    self.lastTurn = Date()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Models

    /// The cloud model when it is chosen and set up, with Ollama taking over when it is slow or
    /// failing (`ChatFallback`); otherwise the local model with search. `backend` names who answered, for the log.
    /// Local search is also used when the cloud falls back to Ollama.
    private static func stream(messages: [[String: String]], localMessages: [[String: String]], ollamaModel: String,
                               backend: Backend, allowSearch: Bool = true) -> AsyncThrowingStream<String, Error> {
        let localClient = LocalSearchChatClient(client: LLM.default, key: allowSearch ? APIKeys.exa.key() : nil,
                                                onSearch: { backend.searched = $0 })
        let local = { @Sendable in
            localClient.streamChat(LLMChatRequest(model: ollamaModel, messages: localMessages, timeout: 10,
                                                  temperature: 0.6, maxTokens: allowSearch ? 110 : 300))
        }
        guard ChatBackend.selected == .cloud, let (cloud, model) = CloudLLM.client() else {
            backend.set("ollama \(ollamaModel)")
            return local()
        }
        var searching = cloud
        searching.webSearchKey = allowSearch ? APIKeys.exa.key() : nil
        searching.onSearch = { backend.searched = $0 }
        let client = searching
        backend.set("cloud \(model)")
        return ChatFallback.stream(
            primary: {
                client.streamChat(LLMChatRequest(model: model, messages: messages, timeout: 10,
                                                 temperature: 0.6, maxTokens: allowSearch ? 110 : 300))
            },
            fallback: local,
            // Deciding to search takes the cloud model 0.7–2 s, sometimes more; local search starts only if the cloud falls back.
            deadline: client.webSearchKey == nil ? ChatFallback.deadline : ChatFallback.searchDeadline,
            onFallback: { reason in
                owLog("[Chat] Cloud \(model): \(reason), falling back to Ollama")
                backend.set("ollama \(ollamaModel) after cloud \(reason)")
            })
    }

    /// Who is answering and what it searched; written from the fallback's task, read when the
    /// reply is logged and kept.
    final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var name = ""
        private var query: String?
        func set(_ value: String) { lock.withLock { name = value } }
        var value: String { lock.withLock { name } }
        var searched: String? {
            get { lock.withLock { query } }
            set { lock.withLock { query = newValue } }
        }
    }

    /// The cloud model can answer on its own, without Ollama running.
    static var cloudReady: Bool { ChatBackend.selected == .cloud && CloudLLM.client() != nil }

    // MARK: - Text

    /// `canSearch`: search is available through a cloud tool or local orchestration.
    nonisolated static func systemPrompt(now: Date, language: ReplyLanguage = .turkish, context: [String] = [], userFacts: [String] = [], recalled: [String] = [],
                                         canSearch: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy EEEE, HH:mm"
        return """
        Sen Jarvis'sin: Iron Man'deki J.A.R.V.I.S. gibi sakin, zeki, hafif esprili, sadık bir kişisel asistan. \
        Kullanıcıyla sesli konuşuyorsun; cevapların sesli okunacak.
        Kurallar:
        - Çok kısa ol: genelde tek cümle, en fazla iki kısa cümle. Kullanıcı açıkça detay isterse en fazla dört cümle.
        - Madde işareti, başlık, markdown, emoji, kod kullanma. Düz konuşma dili.
        \(languageRule(language))
        \(accessRule(context, canSearch: canSearch))
        - Buraya yalnızca komut olarak tanınmayan sözler gelir; sen hiçbir bilgisayar işlemi yapamazsın. Bir işlem istenirse (müzik, hatırlatıcı, ayar, uygulama, e-posta…) yalnızca "\(unrecognizedCommandReply)" de. "Sildim", "silindi", "gönderdim", "oluşturdum", "açtım" gibi başarı iddialarında bulunma; "bu sohbetten yapamam" deme.
        - Kullanıcının sözü sesten yazıya çevrildi; yanlış duyulmuş bir kelimeyi ("Kenarbahçe" → Fenerbahçe) en yakın anlamlı haliyle yorumla.
        - Soru anlaşılıyorsa ama cevabını bilmiyorsan "anlayamadım" deme; neden bilemediğini kısaca söyle (ör. "Canlı skorlara erişimim yok patron.").
        - Kendi adını ("Jarvis") söyleme.
        Şu an: \(formatter.string(from: now)).\(contextBlock(context))\(factsBlock(userFacts))\(recallBlock(recalled))
        """
    }

    /// With live context the calendar, timers, the playing song and what the front app shows
    /// (page, selected mail, chat) are known; internet, weather and news only through the search.
    nonisolated private static func accessRule(_ context: [String], canSearch: Bool) -> String {
        if canSearch {
            let search = "- Güncel bilgi (haber, skor, hava durumu, fiyat, yakın tarihli olay) gerekirse web_search aracıyla ara ve yalnızca sonuçlara dayanarak kısaca cevap ver; adres ya da kaynak adı okuma. Skor, maç ya da olay sorulduğunda sonucun tarihine bak: kullanıcı bir gün söylediyse yalnızca o günün sonucunu, söylemediyse en yenisini söyle; önceki konuşmadaki cevabı tekrar etme. Sonuçta yoksa bulamadığını söyle, uydurma."
            return context.isEmpty
                ? search + "\n- E-postaya ve takvime erişimin yok."
                : search + "\n- Aşağıdaki \"Durum\" bilgileri gerçek ve şu anki; soru onlarla ilgiliyse (çalan şarkı, alarm, takvim, açık uygulama, ekrandaki sayfa, mail, sohbet ya da seçili metin) onlarla kısaca cevap ver, ilgisizse hiç bahsetme. Durumda olmayan bir şeyi biliyormuş gibi yapma."
        }
        return context.isEmpty
            ? "- Bu sohbette internete, hava durumuna, haberlere, e-postaya ve takvime erişimin yok. Güncel bilgi uydurma; bilmiyorsan kısaca söyle."
            : "- İnternete, hava durumuna ve haberlere erişimin yok; güncel bilgi uydurma. Aşağıdaki \"Durum\" bilgileri gerçek ve şu anki; soru onlarla ilgiliyse (çalan şarkı, alarm, takvim, açık uygulama, ekrandaki sayfa, mail, sohbet ya da seçili metin) onlarla kısaca cevap ver, ilgisizse hiç bahsetme. Durumda olmayan bir şeyi biliyormuş gibi yapma."
    }

    /// The user said these themself; the model may use them but must not recite them unasked.
    nonisolated private static func factsBlock(_ facts: [String]) -> String {
        facts.isEmpty ? "" : "\nKullanıcının sana söyleyip hatırlamanı istediği bilgiler, söylediği tarihle (gerektiğinde kullan, sorulmadan sayma; adını biliyorsan arada adıyla hitap edebilirsin):\n"
            + facts.map { "- \($0)" }.joined(separator: "\n")
    }

    /// Only for "geçen hafta ne demiştim?"-style questions.
    nonisolated private static func recallBlock(_ lines: [String]) -> String {
        lines.isEmpty ? "" : "\nSorulan zamandaki konuşma kayıtların (tarihli). Soruyu yalnızca bunlara bakarak kısaca cevapla, özetle; kayıtta olmayanı uydurma:\n"
            + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    nonisolated private static func contextBlock(_ context: [String]) -> String {
        context.isEmpty ? "" : "\nDurum:\n" + context.map { "- \($0)" }.joined(separator: "\n")
    }

    /// The unrecognized-command sentence stays Turkish in both: the exact-match guard in
    /// `reply` needs it, and `JarvisVoice` translates it for an English voice.
    nonisolated private static func languageRule(_ language: ReplyLanguage) -> String {
        switch language {
        case .turkish:
            return """
            - Kullanıcı hangi dilde konuştuysa o dilde cevap ver; genelde Türkçe.
            - Kullanıcıya bazen "patron" ya da "efendim" de; bir cevapta en fazla bir kez, her cevapta değil.
            """
        case .english:
            return """
            - Her zaman İngilizce cevap ver, kullanıcı Türkçe konuşsa bile. Tek istisna aşağıdaki sabit cümle: onu aynen yazıldığı gibi söyle.
            - Kullanıcıya bazen "sir" de; bir cevapta en fazla bir kez, her cevapta değil.
            """
        }
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

    /// What an action request that no command router recognised gets back: honest (nothing ran)
    /// and actionable (say it again), instead of a "can't do that from this chat" refusal.
    /// The model is told to say exactly this; what is spoken is one of `unrecognizedCommandReplies`.
    nonisolated static let unrecognizedCommandReply = "Bunu komut olarak anlayamadım patron, biraz daha açık söyler misin?"

    /// Spoken in turn so the same sentence isn't heard again and again. Each ends in "?", so
    /// Jarvis then listens for the answer (`awaitsAnswer`).
    nonisolated static var unrecognizedCommandReplies: [String] {
        CommandLanguage.isEnglish ? englishUnrecognizedCommandReplies : turkishUnrecognizedCommandReplies
    }

    private nonisolated static let englishUnrecognizedCommandReplies = [
        "I couldn't take that as a command, sir, could you say it more clearly?",
        "I couldn't match that to a command, could you put it another way?",
        "I couldn't tell which task you meant, could you say it again?",
    ]

    private nonisolated static let turkishUnrecognizedCommandReplies = [
        unrecognizedCommandReply,
        "Bunu bir komuta bağlayamadım, başka türlü söyler misin?",
        "Hangi işi istediğini çıkaramadım efendim, bir daha söyler misin?",
        "Bu isteği tanıyamadım, biraz daha açık anlatır mısın?",
    ]

    /// The model didn't understand the user; its sentence is replaced by one of these.
    nonisolated static var notUnderstoodReplies: [String] {
        CommandLanguage.isEnglish ? englishNotUnderstoodReplies : turkishNotUnderstoodReplies
    }

    private nonisolated static let englishNotUnderstoodReplies = [
        "I didn't catch that, sir, could you say it more clearly?",
        "I missed that, could you say it again?",
        "Sorry, I didn't hear that clearly. Could you say it once more?",
    ]

    private nonisolated static let turkishNotUnderstoodReplies = [
        "Anlayamadım patron, biraz daha açık söyler misin?",
        "Tam seçemedim, bir daha söyler misin?",
        "Kaçırdım galiba, tekrar eder misin?",
        "Pardon, net duyamadım. Bir kez daha söyler misin?",
        "Ne demek istediğini tam çıkaramadım efendim, başka türlü söyler misin?",
    ]

    /// The previous ask-again sentence, so the next one is a different one.
    private var lastAskAgain: String?

    private func askAgain(from replies: [String]) -> String {
        let pick = replies.filter { $0 != lastAskAgain }.randomElement() ?? replies[0]
        lastAskAgain = pick
        return pick
    }

    nonisolated static func saysNotUnderstood(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased(with: Locale(identifier: "tr_TR"))
        return ["anlayamadım", "anlamadım", "didn't catch", "did not catch"].contains(where: lowered.contains)
    }

    /// The answer asks the user something back ("…biraz daha açık söyler misin?", "anlayamadım"),
    /// so Jarvis briefly listens for the answer without "Hey Jarvis".
    nonisolated static func awaitsAnswer(_ reply: String) -> Bool {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)"))
        guard !text.isEmpty else { return false }
        return text.hasSuffix("?") || saysNotUnderstood(text)
    }

    /// "Bu sohbetten o işlemi gerçekleştiremedim", "bu sohbet üzerinden … yeteneğim bulunmuyor".
    nonisolated static func isCapabilityRefusal(_ reply: String) -> Bool {
        let text = reply.lowercased(with: Locale(identifier: "tr_TR"))
        let aboutChat = ["bu sohbet", "sohbet üzerinden", "sohbetten"].contains(where: text.contains)
        let cannot = ["gerçekleştiremi", "gerçekleştireme", "yapamı", "yapama", "yeteneğim", "imkanım", "erişimim yok"]
            .contains(where: text.contains)
        return aboutChat && cannot
    }

    /// Last line of defence for an action-like utterance that escaped the deterministic
    /// command routers. Chat has no tools, so it must never speak a fabricated success claim.
    nonisolated static func preventUnsupportedActionClaim(_ reply: String, for userText: String) -> String {
        let locale = Locale(identifier: "tr_TR")
        func folded(_ value: String) -> String {
            value
                .lowercased(with: locale)
                .folding(options: [.diacriticInsensitive], locale: locale)
                .replacingOccurrences(of: "ı", with: "i")
        }

        let user = folded(userText).trimmingCharacters(in: .whitespacesAndNewlines)
        let requestPattern = #"\b(?:sil|kaldir|iptal\s+et|gonder|yolla|ac|kapat|kur|olustur|ayarla|degistir)(?:er\s+misin|abilir\s+misin|sana|in)?(?:\s+lutfen)?[.!?]*$"#
        guard user.range(of: requestPattern, options: .regularExpression) != nil else {
            return reply
        }

        let answer = folded(reply)
        let unsupportedClaims = [
            "sildim", "silindi", "kaldirdim", "kaldirildi", "iptal ettim", "iptal edildi",
            "gonderdim", "gonderildi", "yolladim", "actim", "acildi", "kapattim", "kapandi",
            "kurdum", "kuruldu", "olusturdum", "olusturuldu", "ayarladim", "ayarlandi",
            "degistirdim", "degistirildi", "hallettim", "tamamlandi"
        ]
        guard unsupportedClaims.contains(where: answer.contains) else { return reply }
        return unrecognizedCommandReply
    }
}
