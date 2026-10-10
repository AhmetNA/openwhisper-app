import AVFoundation
import CryptoKit
import Foundation

/// Speaks Jarvis's replies. The audio comes from the `SpeechSynthesisProvider` picked in
/// Settings (local Pocket TTS by default; Piper Jarvis, OmniVoice, EMA or the Gemini API as
/// options); this class owns everything else: playback, stop/interrupt, the timeout safety net,
/// the disk cache, the Turkish spoken form and, for an English voice, the English reply.
/// Repeated short phrases ("Tamamdır.") are cached on disk per provider/model/voice, and for the
/// local voice the acks are synthesized into that cache as soon as it is up.
/// Playback uses `AVAudioPlayer`, never an `AVAudioEngine`, so it can't disturb mic capture.
@MainActor
final class JarvisVoice: NSObject, AVAudioPlayerDelegate {
    static let shared = JarvisVoice()

    nonisolated static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWhisper")
    }

    private let settings: SpeechSettingsStore
    private let cacheDirectory: URL
    private var provider: SpeechSynthesisProvider
    private var player: AVAudioPlayer?
    /// Replies play 20% quieter than the system volume (80% → heard at 64%). This is the
    /// player's own gain; the system output volume itself is never changed.
    static let replyVolume: Float = 0.8
    private var finished: CheckedContinuation<Void, Never>?
    /// Bumped by `stop()` so a reply still being synthesized doesn't start playing afterwards.
    private var generation: UInt64 = 0
    private var synthesis: Task<Data?, Never>?
    private var sentenceProducer: Task<Void, Never>?
    /// Cache identities whose acks were already prefetched this run.
    private var prefetched: Set<String> = []
    /// The local model that translates replies for an English voice (Settings' Ollama model).
    var translationModel = LLMCleanup.defaultModel
    /// Turkish → English for an English voice; nil = Ollama with `translationModel`. Tests swap it.
    var translator: ((String) async -> String?)?
    /// Reads a reply in Turkish when an English voice can't get it translated (Ollama off).
    var turkishFallback: () -> SpeechSynthesisProvider = { LocalPocketTTSProvider.shared }

    init(settings: SpeechSettingsStore = .standard,
         provider: SpeechSynthesisProvider? = nil,
         cacheDirectory: URL = JarvisVoice.supportDirectory.appendingPathComponent("tts-cache")) {
        self.settings = settings
        self.cacheDirectory = cacheDirectory
        self.provider = provider ?? settings.makeProvider()
        super.init()
    }

    var isSpeaking: Bool { player?.isPlaying ?? false }
    /// The language replies are spoken in, i.e. what the chat should answer in.
    var replyLanguage: ReplyLanguage { provider.replyLanguage }

    // MARK: - Provider

    /// Picks up a provider/model change from Settings. A reply from the old provider that is
    /// still being synthesized is dropped rather than played.
    func reloadProvider() {
        let next = settings.makeProvider()
        guard next.cacheIdentity != provider.cacheIdentity else { return }
        stop()
        if next !== provider { provider.suspend() }
        provider = next
        owLog("[Voice] Speaking with \(next.displayName)")
    }

    static let testPhrase = "Merhaba, ben Jarvis. Sesim böyle duyulacak."
    static let englishTestPhrase = "Hello, I am Jarvis. This is how I will sound."

    /// Settings' "Anahtarı test et": one fresh request with the chosen model and voice, played
    /// at once and never cached. nil when it was heard; otherwise why not.
    func speakTest() async -> SpeechSynthesisError? {
        stop()
        let myGeneration = generation
        let provider = self.provider
        guard provider.isReady else { return .notReady(provider.notReadyReason) }
        let started = Date()
        let phrase = provider.replyLanguage == .english ? Self.englishTestPhrase : Self.spokenForm(Self.testPhrase)
        let task = Task { () -> Result<Data, SpeechSynthesisError> in
            do { return .success(try await provider.synthesize(phrase)) }
            catch let error as SpeechSynthesisError { return .failure(error) }
            catch { return .failure(.failed("unexpected error")) }
        }
        // Held as `synthesis` so `stop()` (a new recording) cancels the request too.
        let wrapped = Task { () -> Data? in
            await withTaskCancellationHandler { try? await task.value.get() } onCancel: { task.cancel() }
        }
        synthesis = wrapped
        let result = await task.value
        if synthesis == wrapped { synthesis = nil }
        guard myGeneration == generation else { return .cancelled }
        switch result {
        case .failure(let error):
            owLog("[Voice] \(provider.displayName) test failed: \(error)")
            return error
        case .success(let audio):
            owLog("[Voice] \(provider.displayName) test OK")
            _ = await play(audio, text: phrase, started: started, generation: myGeneration)
            return nil
        }
    }

    /// Settings' "Test cümlelerini oku": sentences that stress the weak spots of Turkish TTS
    /// (ğ/ı/ş, questions, a long sentence, numbers, an English name, short acks), so models can
    /// be compared by ear without saying anything. Keep in step with `scripts/tts-compare`.
    static let testSentences = [
        "Tamamdır, efendim.",
        "Saat 14:05, patron. Bugün üç toplantınız var.",
        "Yarın sabah dokuzda Ayşe Hanım'la görüşmeyi hatırlatayım mı?",
        "Spotify'da Tarkan çalıyorum, sesi biraz açtım.",
        "Ağaçların gölgesinde ılık bir rüzgâr eserken, şoför çocuğu güvenle okula bıraktı ve ışıklar yanınca geri döndü.",
        "Üzgünüm, bunu anlayamadım. Bir kez daha söyler misiniz?",
    ]

    /// `testSentences` for an English voice: digits, a name, a question, a long sentence.
    static let englishTestSentences = [
        "Right away, sir.",
        "It is 2:05 in the afternoon, sir. You have three meetings today.",
        "Shall I remind you about the meeting with Pepper tomorrow at nine?",
        "I'm playing Daft Punk on Spotify and turned the volume up a little.",
        "While the wind blew softly through the trees, the driver took the children safely to school and came back when the lights turned green.",
        "I'm sorry, I didn't catch that. Could you say it again?",
    ]

    /// Reads `testSentences` with the chosen provider: waits for a local server to load first,
    /// never touches the cache (so the timings are honest) and synthesizes the next sentence
    /// while the current one plays. `progress` gets the 1-based index of the sentence playing.
    /// nil when all were heard; otherwise why not.
    func speakTestSentences(progress: @escaping (Int) -> Void = { _ in }) async -> SpeechSynthesisError? {
        stop()
        let myGeneration = generation
        let provider = self.provider
        if !provider.isReady { await provider.prepare() }
        // "Durdur" or a new recording while the local server was loading.
        guard provider === self.provider, myGeneration == generation, !Task.isCancelled else { return .cancelled }
        guard provider.isReady else { return .notReady(provider.notReadyReason) }
        let english = provider.replyLanguage == .english
        let sentences = english ? Self.englishTestSentences : Self.testSentences
        owLog("[Voice] \(provider.displayName) test: \(sentences.count) sentences")

        func make(_ index: Int) -> Task<Result<Data, SpeechSynthesisError>, Never> {
            Task {
                let started = Date()
                do {
                    let data = try await provider.synthesize(english ? ReplyTranslator.spokenTimes(sentences[index]) : Self.spokenForm(sentences[index]))
                    owLog("[Voice] Test \(index + 1): synthesized in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                    return .success(data)
                } catch let error as SpeechSynthesisError { return .failure(error) }
                catch { return .failure(.failed("unexpected error")) }
            }
        }

        var next = make(0)
        for index in sentences.indices {
            let current = next
            // Held as `synthesis` so `stop()` (a new recording) cancels the request too.
            let wrapped = Task { () -> Data? in
                await withTaskCancellationHandler { try? await current.value.get() } onCancel: { current.cancel() }
            }
            synthesis = wrapped
            let result = await current.value
            if synthesis == wrapped { synthesis = nil }
            guard myGeneration == generation else { return .cancelled }
            switch result {
            case .failure(let error):
                owLog("[Voice] \(provider.displayName) test failed at \(index + 1): \(error)")
                return error
            case .success(let audio):
                if index + 1 < sentences.count { next = make(index + 1) }
                progress(index + 1)
                guard await play(audio, text: sentences[index], started: Date(), generation: myGeneration) else {
                    next.cancel()
                    return .cancelled
                }
            }
        }
        owLog("[Voice] \(provider.displayName) test OK")
        return nil
    }

    /// Gets the current provider ready (the local server takes ~15 s to load), then fills the
    /// cache with the acks where the provider allows it. Safe to call repeatedly.
    func prepare() async {
        let provider = self.provider
        await provider.prepare()
        guard provider === self.provider, provider.isReady else { return }
        let identity = provider.cacheIdentity
        guard provider.prefetchesAcks, !prefetched.contains(identity) else { return }
        prefetched.insert(identity)
        removeOldCache()
        await prefetchAcks(with: provider, identity: identity)
    }

    /// Every ack `JarvisReply` can produce, with and without an address, exactly as spoken.
    private func prefetchAcks(with provider: SpeechSynthesisProvider, identity: String) async {
        var phrases = JarvisReply.acks + JarvisReply.fixedPhrases
        for ack in JarvisReply.acks + JarvisReply.fixedPhrases {
            let body = ack.hasSuffix(".") ? String(ack.dropLast()) : ack
            phrases += JarvisReply.addresses.map { "\(body), \($0)." }
        }
        var made = 0
        for phrase in phrases where cachedAudio(for: phrase, identity: identity) == nil {
            guard provider === self.provider else { break }
            guard !isSpeaking, synthesis == nil else { continue }
            // An English voice gets the fixed English ack (never a translation from the model),
            // filed under the Turkish text that `audio(for:)` looks up.
            let spoken = provider.replyLanguage == .english ? ReplyTranslator.fixedEnglish(phrase) : Self.spokenForm(phrase)
            guard let spoken else { continue }
            if let data = try? await provider.synthesize(spoken) {
                store(data, for: phrase, identity: identity)
                made += 1
            }
        }
        if made > 0 { owLog("[Voice] Cached \(made) acks") }
    }

    // MARK: - Speaking

    /// Speaks `text` and returns when it finished (or failed / was stopped), so the caller can
    /// hold back resuming music until Jarvis is done talking. `onStart` runs once the audio is
    /// actually playing, after the (possibly slow) synthesis.
    @discardableResult
    func speak(_ text: String, onStart: () -> Void = {}) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        stop()
        let myGeneration = generation
        let started = Date()
        guard let audio = await audio(for: text) else { return false }
        return await play(audio, text: text, started: started, generation: myGeneration, onStart: onStart)
    }

    /// Speaks sentences as they arrive, e.g. a chat reply the model is still writing: each one
    /// is synthesized while the one before it plays. Returns when all are spoken or it was
    /// stopped. `onStart` runs when the first sentence starts playing. False when nothing
    /// was heard (voice not ready, stopped before the first sentence).
    @discardableResult
    func speak(sentences: AsyncStream<String>, onStart: () -> Void = {}) async -> Bool {
        stop()
        let myGeneration = generation
        let started = Date()
        let (clips, clipsContinuation) = AsyncStream<(String, Data)>.makeStream()
        let producer = Task { @MainActor [weak self] in
            for await sentence in sentences {
                guard let self, !Task.isCancelled, myGeneration == self.generation else { break }
                if let data = await self.audio(for: sentence) { clipsContinuation.yield((sentence, data)) }
            }
            clipsContinuation.finish()
        }
        sentenceProducer = producer
        var first = true
        for await (sentence, data) in clips {
            guard await play(data, text: sentence, started: started, generation: myGeneration, onStart: first ? onStart : {}) else { break }
            first = false
        }
        producer.cancel()
        return !first
    }

    /// Plays one clip and waits for it to end. False when it didn't play or was cut short.
    private func play(_ audio: Data, text: String, started: Date, generation myGeneration: UInt64, onStart: () -> Void = {}) async -> Bool {
        guard myGeneration == generation else {
            owLog("[Voice] Reply dropped, interrupted while synthesizing: '\(text)'")
            return false
        }
        do {
            // play() can return false while the output device is still switching (e.g. the
            // headset leaving call mode right after a recording), so retry briefly.
            var playing: AVAudioPlayer?
            for attempt in 1...4 {
                let candidate = try AVAudioPlayer(data: audio)
                candidate.delegate = self
                candidate.volume = Self.replyVolume
                self.player = candidate
                candidate.prepareToPlay()
                if candidate.play() {
                    playing = candidate
                    if attempt > 1 { owLog("[Voice] Playback started on attempt \(attempt)") }
                    break
                }
                self.player = nil
                try? await Task.sleep(for: .milliseconds(300))
                guard myGeneration == generation else { return false }
            }
            guard let player = playing else {
                owLog("[Voice] Playback did not start after 4 attempts")
                return false
            }
            owLog("[Voice] Speaking '\(text)' (\(Int(Date().timeIntervalSince(started) * 1000)) ms to start)")
            onStart()
            // Safety net: if the finish callback never comes (output device switched mid-reply),
            // don't keep the command — and the paused music — waiting forever.
            let limit = min(player.duration + 1, 20)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(limit))
                guard let self, myGeneration == self.generation, self.player === player else { return }
                owLog("[Voice] Playback did not report finishing, stopping")
                self.stop()
            }
            await withCheckedContinuation { finished = $0 }
            return myGeneration == generation
        } catch {
            owLog("[Voice] Playback failed: \(error)")
            return false
        }
    }

    /// Cuts the current reply short, e.g. when a new recording starts.
    func stop() {
        generation &+= 1
        synthesis?.cancel()
        synthesis = nil
        sentenceProducer?.cancel()
        sentenceProducer = nil
        player?.stop()
        player = nil
        finished?.resume()
        finished = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in self.playerFinished(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        let message = error.map { "\($0)" } ?? "unknown"
        Task { @MainActor in
            owLog("[Voice] Decode error: \(message)")
            self.playerFinished(id)
        }
    }

    private func playerFinished(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        self.player = nil
        finished?.resume()
        finished = nil
    }

    // MARK: - Audio

    private func audio(for text: String) async -> Data? {
        // Captured now, so a clip still in flight when the provider changes is filed under
        // the provider that made it.
        let provider = self.provider
        let identity = provider.cacheIdentity
        if let data = cachedAudio(for: text, identity: identity) {
            owLog("[Voice] From cache, no request: '\(text)'")
            return data
        }
        guard provider.isReady else {
            owLog("[Voice] \(provider.displayName): \(provider.notReadyReason), reply stays silent")
            Task { await prepare() }
            return nil
        }
        let task = Task { () -> (data: Data, cacheable: Bool)? in
            var voice = provider
            var spoken = Self.spokenForm(text)
            var cacheable = Self.isCacheable(text)
            if provider.replyLanguage == .english {
                switch await self.english(for: text) {
                case .some((let english, let fixed)):
                    // Digits stay digits: espeak reads them in English. Only fixed acks and
                    // sentences already in English are cached; a model's translation may vary.
                    spoken = ReplyTranslator.spokenTimes(english)
                    cacheable = cacheable && fixed
                case nil:
                    guard !Task.isCancelled else { return nil }
                    // Never cached: it would be filed under the English voice.
                    voice = self.turkishFallback()
                    cacheable = false
                    owLog("[Voice] No English translation, reading it in Turkish with \(voice.displayName)")
                }
            }
            do {
                return (try await voice.synthesize(spoken), cacheable)
            } catch SpeechSynthesisError.cancelled {
                return nil
            } catch {
                // Never the text or a key: the error is a status summary.
                owLog("[Voice] \(voice.displayName) synthesis failed: \(error)")
                return nil
            }
        }
        let wrapped = Task { () -> Data? in
            await withTaskCancellationHandler { await task.value?.data } onCancel: { task.cancel() }
        }
        synthesis = wrapped
        let result = await task.value
        if synthesis == wrapped { synthesis = nil }
        if let result, result.cacheable { store(result.data, for: text, identity: identity) }
        return result?.data
    }

    /// `text` in English and whether that is fixed (an ack from the table, or text that already
    /// was English); nil when the local model couldn't translate it.
    private func english(for text: String) async -> (String, fixed: Bool)? {
        if let fixed = ReplyTranslator.fixedEnglish(text) { return (fixed, true) }
        if ReplyTranslator.isClearlyEnglish(text) { return (text, true) }
        let started = Date()
        let translated: String?
        if let translator {
            translated = await translator(text)
        } else {
            translated = await ReplyTranslator.translate(text, model: translationModel)
        }
        guard let translated else { return nil }
        owLog("[Voice] Translated in \(Int(Date().timeIntervalSince(started) * 1000)) ms: '\(text)' → '\(translated)'")
        return (translated, false)
    }

    // MARK: - Cache

    private func cachedAudio(for text: String, identity: String) -> Data? {
        guard Self.isCacheable(text) else { return nil }
        return try? Data(contentsOf: cacheFile(for: text, identity: identity))
    }

    private func store(_ data: Data, for text: String, identity: String) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile(for: text, identity: identity), options: .atomic)
    }

    private func cacheFile(for text: String, identity: String) -> URL {
        cacheDirectory.appendingPathComponent(Self.cacheKey(text: text, identity: identity) + ".wav")
    }

    /// ElevenLabs replies were cached as .mp3; they are never read again.
    private func removeOldCache() {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "mp3" { try? FileManager.default.removeItem(at: file) }
    }

    /// Acks and fixed phrases repeat; answers with numbers ("Saat 14:05") don't.
    nonisolated static func isCacheable(_ text: String) -> Bool {
        text.count <= 60 && !text.contains(where: \.isNumber)
    }

    /// `identity` is the provider's `cacheIdentity` (provider, model, voice, style).
    nonisolated static func cacheKey(text: String, identity: String) -> String {
        let digest = SHA256.hash(data: Data("\(identity)|\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Text

    /// The model reads digits badly ("14:05" came out as "Urdeşi 5"), so numbers are spelled
    /// out in Turkish first: "Saat 14:05" → "Saat on dört sıfır beş", "09:30'da" → "dokuz
    /// otuzda", "3'ü" → "üçü", "3,5" → "üç virgül beş". A suffix apostrophe after a number goes,
    /// since the spelled word takes the suffix directly.
    nonisolated static func spokenForm(_ text: String) -> String {
        var out = text
        out = replacing(#"(\d{1,2}):(\d{2})['’]?"#, in: out) { groups in
            let hour = spell(groups[1])
            let minute = Int(groups[2]) ?? 0
            if minute == 0 { return hour }
            return minute < 10 ? "\(hour) sıfır \(spell(groups[2]))" : "\(hour) \(spell(groups[2]))"
        }
        out = replacing(#"(\d+),(\d+)['’]?"#, in: out) { groups in
            "\(spell(groups[1])) virgül \(spell(groups[2]))"
        }
        out = replacing(#"(\d+)['’]?"#, in: out) { groups in spell(groups[1]) }
        return out
    }

    nonisolated private static func spell(_ digits: String) -> String {
        guard let value = Int(digits) else { return digits }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "tr_TR")
        return formatter.string(from: NSNumber(value: value)) ?? digits
    }

    nonisolated private static func replacing(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }
}
