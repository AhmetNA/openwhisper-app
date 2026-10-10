import Foundation

/// Jarvis's English voice: Piper's Jarvis model (jgkawell/jarvis, medium, ONNX on the CPU),
/// served by `tts_piper_server/server.py` on 127.0.0.1. `tts_piper_server/setup.sh` installs it
/// once into `~/Library/Application Support/OpenWhisper/tts-piper` (needs Homebrew's espeak-ng).
/// Picking it makes Jarvis answer in English: `JarvisVoice` translates the Turkish replies and
/// the chat answers in English. Measured on this Mac: ~2 s to load, ~70 ms for a short reply,
/// ~150 MB RAM. One instance for the app, since it owns the server.
@MainActor
final class LocalPiperJarvisProvider: SpeechSynthesisProvider {
    static let shared = LocalPiperJarvisProvider()

    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "piper",
        title: "Yerel — Piper Jarvis (İngilizce)",
        summary: "Bu Mac'te çalışan küçük Piper Jarvis modeliyle, internetsiz ve ücretsiz. Jarvis İngilizce cevap verir; Türkçe sistem cevapları yerel modelle (Ollama) İngilizceye çevrilir. Kurulum bir kez: app/tts_piper_server/setup.sh (brew install espeak-ng gerekir)",
        models: [SpeechModelOption(id: voiceModel, title: "Piper Jarvis medium", detail: "İngilizce Jarvis sesi, CPU'da çalışır.")],
        needsAPIKey: false,
        make: { _, _, _ in LocalPiperJarvisProvider.shared }
    )

    nonisolated static let port = 8773
    /// The cache key: changing the model revision or the phonemization in server.py must bump
    /// this.
    nonisolated static let voiceModel = "piper-jarvis-medium|37f8763|espeak-en-gb|22k"

    static var serverDirectory: URL { JarvisVoice.supportDirectory.appendingPathComponent("tts-piper") }
    private static var python: URL { serverDirectory.appendingPathComponent(".venv/bin/python") }
    private static var serverScript: URL { serverDirectory.appendingPathComponent("server.py") }
    private static let baseURL = URL(string: "http://127.0.0.1:\(port)")!

    private var serverProcess: Process?
    private var serverReady = false
    private var preparing = false

    let displayName = "Piper Jarvis"
    let replyLanguage = ReplyLanguage.english
    let prefetchesAcks = true
    var isReady: Bool { serverReady }
    var notReadyReason: String { "Piper Jarvis not ready" }
    var cacheIdentity: String { Self.voiceModel }

    // MARK: - Server

    /// Starts the voice server if needed and waits until the model is loaded. Safe to call
    /// repeatedly.
    func prepare() async {
        guard !serverReady, !preparing else { return }
        preparing = true
        defer { preparing = false }

        if let stray = await strayServerPID() {
            // A server we didn't start (e.g. a manual test run) answers on our port. Don't adopt
            // it: whoever started it may close it at any moment and replies would go silent.
            owLog("[Voice] Replacing Piper server we didn't start (pid \(stray))")
            kill(stray, SIGTERM)
            for _ in 0..<20 {
                if await health() == nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        if await health() == nil {
            guard FileManager.default.isExecutableFile(atPath: Self.python.path),
                  FileManager.default.fileExists(atPath: Self.serverScript.path)
            else {
                owLog("[Voice] Piper Jarvis not installed — run app/tts_piper_server/setup.sh. Replies stay silent")
                return
            }
            guard startServer() else { return }
        }

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            switch await health() {
            case .ready:
                serverReady = true
                owLog("[Voice] Piper Jarvis ready")
                return
            case .failed(let error):
                owLog("[Voice] Piper Jarvis failed to load: \(error). Log: \(Self.serverDirectory.path)/server.log")
                return
            case .loading, nil:
                if let serverProcess, !serverProcess.isRunning {
                    owLog("[Voice] Piper server exited (\(serverProcess.terminationStatus)). Log: \(Self.serverDirectory.path)/server.log")
                    self.serverProcess = nil
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        owLog("[Voice] Piper Jarvis did not become ready within 180 s")
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
            owLog("[Voice] Could not start Piper server: \(error)")
            return false
        }
        serverProcess = process
        owLog("[Voice] Started Piper server (pid \(process.processIdentifier))")
        return true
    }

    /// Stops the server we started. `prepare()` starts it again (~2 s) when Piper Jarvis is picked again.
    func suspend() {
        serverReady = false
        guard let serverProcess else { return }
        self.serverProcess = nil
        if serverProcess.isRunning {
            serverProcess.terminate()
            owLog("[Voice] Stopped Piper server (pid \(serverProcess.processIdentifier))")
        }
    }

    private enum Health { case loading, ready, failed(String) }

    /// The pid of a server on our port that this app didn't start, or nil (none, or ours).
    private func strayServerPID() async -> pid_t? {
        guard serverProcess == nil,
              let json = await healthJSON(),
              let pid = json["pid"] as? Int, pid > 0
        else { return nil }
        let parent = json["parent_pid"] as? Int
        return parent == Int(ProcessInfo.processInfo.processIdentifier) ? nil : pid_t(pid)
    }

    private func healthJSON() async -> [String: Any]? {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("health"), timeoutInterval: 1)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func health() async -> Health? {
        guard let json = await healthJSON() else { return nil }
        if json["ready"] as? Bool == true { return .ready }
        if let error = json["error"] as? String { return .failed(error) }
        return .loading
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
            owLog("[Voice] Piper server lost (\(reason)); restarting and retrying once")
            if let serverProcess, !serverProcess.isRunning { self.serverProcess = nil }
            await prepare()
            guard serverReady else { throw SpeechSynthesisError.failed(reason) }
            return try await speak(text)
        }
    }

    private func speak(_ text: String) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("speak"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // Our own server on localhost; its error body is safe to show.
                owLog("[Voice] Piper server HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
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
