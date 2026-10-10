import Foundation

/// Default local voice: Pocket TTS Turkish (PyTorch on the CPU), served by
/// `tts_pocket_server/server.py` on 127.0.0.1. `tts_pocket_server/setup.sh` installs it once into
/// `~/Library/Application Support/OpenWhisper/tts-pocket`, apart from OmniVoice's venv. Clones
/// Jarvis from the same `jarvis_ref.wav` as OmniVoice. Measured on this Mac: ~2 s to load,
/// 0.2–0.5 s for a short reply, ~1.0 GB RAM. Also reads the Turkish fallback when the English
/// voice can't get a reply translated. One instance for the app, since it owns the server.
@MainActor
final class LocalPocketTTSProvider: SpeechSynthesisProvider {
    static let shared = LocalPocketTTSProvider()

    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "pocket",
        title: "Yerel — Pocket TTS (Türkçe)",
        summary: "Bu Mac'te çalışan küçük Pocket TTS Turkish modeliyle, internetsiz ve ücretsiz. Jarvis sesini referans kayıttan klonlar. Kurulum bir kez: app/tts_pocket_server/setup.sh",
        models: [SpeechModelOption(id: voiceModel, title: "Pocket TTS Turkish", detail: "Jarvis klonu, CPU'da çalışır.")],
        needsAPIKey: false,
        make: { _, _, _ in LocalPocketTTSProvider.shared }
    )

    nonisolated static let port = 8772
    /// The cache key: changing the package, model revision, reference clip or SEED in server.py
    /// must bump this.
    nonisolated static let voiceModel = "pocket-tts-turkish-0.1.0|fcbd37c|jarvis_ref|seed7|tr-only|24k|eos1"

    static var serverDirectory: URL { JarvisVoice.supportDirectory.appendingPathComponent("tts-pocket") }
    private static var python: URL { serverDirectory.appendingPathComponent(".venv/bin/python") }
    private static var serverScript: URL { serverDirectory.appendingPathComponent("server.py") }
    private static let baseURL = URL(string: "http://127.0.0.1:\(port)")!

    private var serverProcess: Process?
    private var serverReady = false
    private var preparing = false

    let displayName = "Pocket TTS"
    let prefetchesAcks = true
    var isReady: Bool { serverReady }
    var notReadyReason: String { "Pocket TTS not ready" }
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
            owLog("[Voice] Replacing Pocket server we didn't start (pid \(stray))")
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
                owLog("[Voice] Pocket TTS not installed — run app/tts_pocket_server/setup.sh. Replies stay silent")
                return
            }
            guard startServer() else { return }
        }

        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            switch await health() {
            case .ready:
                serverReady = true
                owLog("[Voice] Pocket TTS ready")
                return
            case .failed(let error):
                owLog("[Voice] Pocket TTS failed to load: \(error). Log: \(Self.serverDirectory.path)/server.log")
                return
            case .loading, nil:
                if let serverProcess, !serverProcess.isRunning {
                    owLog("[Voice] Pocket server exited (\(serverProcess.terminationStatus)). Log: \(Self.serverDirectory.path)/server.log")
                    self.serverProcess = nil
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        owLog("[Voice] Pocket TTS did not become ready within 180 s")
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
            owLog("[Voice] Could not start Pocket server: \(error)")
            return false
        }
        serverProcess = process
        owLog("[Voice] Started Pocket server (pid \(process.processIdentifier))")
        return true
    }

    /// Stops the server we started. `prepare()` starts it again (~2 s) when Pocket TTS is picked again.
    func suspend() {
        serverReady = false
        guard let serverProcess else { return }
        self.serverProcess = nil
        if serverProcess.isRunning {
            serverProcess.terminate()
            owLog("[Voice] Stopped Pocket server (pid \(serverProcess.processIdentifier))")
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
            owLog("[Voice] Pocket server lost (\(reason)); restarting and retrying once")
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
                owLog("[Voice] Pocket server HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
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
