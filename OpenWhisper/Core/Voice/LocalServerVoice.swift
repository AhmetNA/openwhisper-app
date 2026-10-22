import Foundation

/// A Jarvis voice served by one of the small local TTS servers (Pocket, EMA, Piper): the app
/// starts it, waits for its model, and posts `{"text": …}` to `/speak` for WAV data. A server
/// on the port that this app didn't start is replaced, and a server lost mid-reply is started
/// again for that reply. Subclasses only say which server and how it is named.
@MainActor
class LocalServerVoice: SpeechSynthesisProvider {
    struct Naming {
        /// "Pocket TTS": readiness and install messages, Settings.
        let display: String
        /// "Pocket": "Pocket server …" log lines.
        let short: String
        /// "servers/tts_pocket_server": where setup.sh lives in the repo.
        let setupFolder: String
    }

    let naming: Naming
    let server: LocalModelServer
    let cacheIdentity: String
    let replyLanguage: ReplyLanguage
    /// How long one `/speak` may take.
    private let speakTimeout: TimeInterval

    private var serverReady = false
    private var preparing = false

    init(naming: Naming, port: Int, folder: String, voiceModel: String,
         speakTimeout: TimeInterval, replyLanguage: ReplyLanguage = .turkish) {
        self.naming = naming
        server = LocalModelServer(.init(port: port, directory: JarvisVoice.supportDirectory.appendingPathComponent(folder)))
        cacheIdentity = voiceModel
        self.speakTimeout = speakTimeout
        self.replyLanguage = replyLanguage
    }

    var displayName: String { naming.display }
    let prefetchesAcks = true
    var isReady: Bool { serverReady }
    var notReadyReason: String { "\(naming.display) not ready" }

    // MARK: - Server

    /// Starts the voice server if needed and waits until the model is loaded. Safe to call
    /// repeatedly.
    func prepare() async {
        guard !serverReady, !preparing else { return }
        preparing = true
        defer { preparing = false }

        if let stray = await server.strayPID() {
            owLog("[Voice] Replacing \(naming.short) server we didn't start (pid \(stray))")
            await server.replaceStray(stray)
        }

        if await server.health() == nil {
            guard server.isInstalled else {
                owLog("[Voice] \(naming.display) not installed — run app/\(naming.setupFolder)/setup.sh. Replies stay silent")
                return
            }
            do {
                let pid = try server.start()
                owLog("[Voice] Started \(naming.short) server (pid \(pid))")
            } catch {
                owLog("[Voice] Could not start \(naming.short) server: \(error)")
                return
            }
        }

        switch await server.waitUntilReady(timeout: 180, poll: .seconds(1)) {
        case .ready:
            serverReady = true
            owLog("[Voice] \(naming.display) ready")
        case .failed(let error):
            owLog("[Voice] \(naming.display) failed to load: \(error). Log: \(server.logPath)")
        case .exited(let status):
            owLog("[Voice] \(naming.short) server exited (\(status)). Log: \(server.logPath)")
        case .timedOut:
            owLog("[Voice] \(naming.display) did not become ready within 180 s")
        }
    }

    /// Stops the server we started. `prepare()` starts it again (~2 s) when this voice is picked again.
    func suspend() {
        serverReady = false
        if let pid = server.stop() {
            owLog("[Voice] Stopped \(naming.short) server (pid \(pid))")
        }
    }

    // MARK: - Synthesis

    func synthesize(_ text: String) async throws -> Data {
        if !serverReady { await prepare() }
        guard serverReady else { throw SpeechSynthesisError.notReady(notReadyReason) }
        do {
            return try await speak(text)
        } catch SpeechSynthesisError.failed(let reason) where !serverReady {
            // The server went away (e.g. one we attached to but didn't start was closed).
            // Start our own (~2 s) and still read this reply instead of dropping it.
            owLog("[Voice] \(naming.short) server lost (\(reason)); restarting and retrying once")
            server.forgetIfExited()
            await prepare()
            guard serverReady else { throw SpeechSynthesisError.failed(reason) }
            return try await speak(text)
        }
    }

    private func speak(_ text: String) async throws -> Data {
        var request = URLRequest(url: server.baseURL.appendingPathComponent("speak"), timeoutInterval: speakTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // Our own server on localhost; its error body is safe to show.
                owLog("[Voice] \(naming.short) server HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
                if status == 503 { serverReady = false }
                throw SpeechSynthesisError.failed("HTTP \(status)")
            }
            return data
        } catch is CancellationError {
            throw SpeechSynthesisError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw SpeechSynthesisError.cancelled
        } catch let error as URLError {
            // The server may have died; the next reply restarts it.
            if error.code == .cannotConnectToHost { serverReady = false }
            throw SpeechSynthesisError.failed("request failed: \(error.localizedDescription)")
        }
    }
}
