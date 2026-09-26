import AVFoundation
import CryptoKit
import Foundation

/// Speaks Jarvis's replies with a local text-to-speech model: OmniVoice on MLX, served by
/// `tts_server/server.py` on 127.0.0.1. `tts_server/setup.sh` installs it once into
/// `~/Library/Application Support/OpenWhisper/tts`; the app starts the server itself and the
/// server quits when the app does. Until it is installed and warm Jarvis stays silent.
/// Repeated short phrases ("Tamamdır.") are cached on disk, and the acks are synthesized into
/// that cache as soon as the server is up, so they play without delay.
/// Playback uses `AVAudioPlayer`, never an `AVAudioEngine`, so it can't disturb mic capture.
@MainActor
final class JarvisVoice: NSObject, AVAudioPlayerDelegate {
    static let shared = JarvisVoice()

    nonisolated static let port = 8767
    /// Part of the cache key: changing the model or its settings in server.py must bump this.
    nonisolated static let voiceModel = "omnivoice-bf16-steps32"

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWhisper")
    }
    static var serverDirectory: URL { supportDirectory.appendingPathComponent("tts") }
    private static var python: URL { serverDirectory.appendingPathComponent(".venv/bin/python") }
    private static var serverScript: URL { serverDirectory.appendingPathComponent("server.py") }
    private static var referenceClip: URL { serverDirectory.appendingPathComponent("jarvis_ref.wav") }
    private static var cacheDirectory: URL { supportDirectory.appendingPathComponent("tts-cache") }
    private static let baseURL = URL(string: "http://127.0.0.1:\(port)")!

    private var player: AVAudioPlayer?
    private var finished: CheckedContinuation<Void, Never>?
    /// Bumped by `stop()` so a reply still being synthesized doesn't start playing afterwards.
    private var generation: UInt64 = 0
    private var synthesis: Task<Data?, Never>?
    private var sentenceProducer: Task<Void, Never>?
    private var serverProcess: Process?
    private var serverReady = false
    private var preparing = false
    /// Hash of the reference clip, so a new voice doesn't replay the old one from the cache.
    private var voiceID: String?

    var isSpeaking: Bool { player?.isPlaying ?? false }

    // MARK: - Server

    /// Starts the voice server if needed, waits until the model is loaded (~15 s from the
    /// cache), then fills the cache with the acks. Safe to call repeatedly.
    func prepare() async {
        guard !serverReady, !preparing else { return }
        preparing = true
        defer { preparing = false }

        if await health() == nil {
            guard FileManager.default.isExecutableFile(atPath: Self.python.path),
                  FileManager.default.fileExists(atPath: Self.serverScript.path)
            else {
                owLog("[Voice] Local voice not installed — run app/tts_server/setup.sh. Replies stay silent")
                return
            }
            guard startServer() else { return }
        }

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            switch await health() {
            case .ready:
                serverReady = true
                owLog("[Voice] Local voice ready")
                removeOldCache()
                await prefetchAcks()
                return
            case .failed(let error):
                owLog("[Voice] Local voice failed to load: \(error). Log: \(Self.serverDirectory.path)/server.log")
                return
            case .loading, nil:
                if let serverProcess, !serverProcess.isRunning {
                    owLog("[Voice] Voice server exited (\(serverProcess.terminationStatus)). Log: \(Self.serverDirectory.path)/server.log")
                    self.serverProcess = nil
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        owLog("[Voice] Local voice did not become ready within 180 s")
    }

    private func startServer() -> Bool {
        let logURL = Self.serverDirectory.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let process = Process()
        process.executableURL = Self.python
        process.arguments = [Self.serverScript.path, "--port", "\(Self.port)",
                             "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)"]
        process.currentDirectoryURL = Self.serverDirectory
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        // setup.sh downloaded the model; don't ask the Hub for updates on every launch.
        environment["HF_HUB_OFFLINE"] = "1"
        process.environment = environment
        if let log = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        do {
            try process.run()
        } catch {
            owLog("[Voice] Could not start voice server: \(error)")
            return false
        }
        serverProcess = process
        owLog("[Voice] Started local voice server (pid \(process.processIdentifier))")
        return true
    }

    private enum Health { case loading, ready, failed(String) }

    private func health() async -> Health? {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("health"), timeoutInterval: 1)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if json["ready"] as? Bool == true { return .ready }
        if let error = json["error"] as? String { return .failed(error) }
        return .loading
    }

    /// Every ack `JarvisReply` can produce, with and without an address, exactly as spoken.
    private func prefetchAcks() async {
        var phrases = JarvisReply.acks + JarvisReply.fixedPhrases
        for ack in JarvisReply.acks + JarvisReply.fixedPhrases {
            let body = ack.hasSuffix(".") ? String(ack.dropLast()) : ack
            phrases += JarvisReply.addresses.map { "\(body), \($0)." }
        }
        var made = 0
        for phrase in phrases where cachedAudio(for: phrase) == nil {
            guard !isSpeaking, synthesis == nil else { continue }
            if let data = await requestSpeech(Self.spokenForm(phrase)) {
                store(data, for: phrase)
                made += 1
            }
        }
        if made > 0 { owLog("[Voice] Cached \(made) acks") }
    }

    // MARK: - Speaking

    /// Speaks `text` and returns when it finished (or failed / was stopped), so the caller can
    /// hold back resuming music until Jarvis is done talking. `onStart` runs once the audio is
    /// actually playing, after the (possibly slow) synthesis.
    func speak(_ text: String, onStart: () -> Void = {}) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        stop()
        let myGeneration = generation
        let started = Date()
        guard let audio = await audio(for: text) else { return }
        _ = await play(audio, text: text, started: started, generation: myGeneration, onStart: onStart)
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
            let player = try AVAudioPlayer(data: audio)
            player.delegate = self
            self.player = player
            guard player.play() else {
                owLog("[Voice] Playback did not start")
                self.player = nil
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
        if let data = cachedAudio(for: text) { return data }
        guard serverReady else {
            owLog("[Voice] Local voice not ready, reply stays silent: '\(text)'")
            Task { await prepare() }
            return nil
        }
        let task = Task { await requestSpeech(Self.spokenForm(text)) }
        synthesis = task
        let data = await task.value
        if synthesis == task { synthesis = nil }
        if let data, Self.isCacheable(text) { store(data, for: text) }
        return data
    }

    /// Synthesizing takes ~1–3 s; the music stays paused meanwhile, so the wait is bounded.
    private func requestSpeech(_ text: String) async -> Data? {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("speak"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "language": "tr"])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                owLog("[Voice] Voice server HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
                if status == 503 { serverReady = false }
                return nil
            }
            return data
        } catch is CancellationError {
            return nil
        } catch let error as URLError where error.code == .cancelled {
            return nil
        } catch {
            owLog("[Voice] Voice server request failed: \(error.localizedDescription)")
            // The server may have died; the next reply restarts it.
            if (error as? URLError)?.code == .cannotConnectToHost { serverReady = false }
            return nil
        }
    }

    // MARK: - Cache

    private func cachedAudio(for text: String) -> Data? {
        guard Self.isCacheable(text) else { return nil }
        return try? Data(contentsOf: cacheFile(for: text))
    }

    private func store(_ data: Data, for text: String) {
        try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheFile(for: text), options: .atomic)
    }

    private func cacheFile(for text: String) -> URL {
        if voiceID == nil {
            let clip = (try? Data(contentsOf: Self.referenceClip)) ?? Data()
            voiceID = SHA256.hash(data: clip).map { String(format: "%02x", $0) }.joined()
        }
        return Self.cacheDirectory.appendingPathComponent(Self.cacheKey(text: text, voice: voiceID ?? "") + ".wav")
    }

    /// ElevenLabs replies were cached as .mp3; they are never read again.
    private func removeOldCache() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "mp3" { try? FileManager.default.removeItem(at: file) }
    }

    /// Acks and fixed phrases repeat; answers with numbers ("Saat 14:05") don't.
    nonisolated static func isCacheable(_ text: String) -> Bool {
        text.count <= 60 && !text.contains(where: \.isNumber)
    }

    nonisolated static func cacheKey(text: String, voice: String) -> String {
        let digest = SHA256.hash(data: Data("\(voiceModel)|\(voice)|\(text)".utf8))
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
