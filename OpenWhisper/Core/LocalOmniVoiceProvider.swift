import CryptoKit
import Foundation

/// Jarvis's local voice: OmniVoice on MLX, served by `tts_server/server.py` on 127.0.0.1.
/// `tts_server/setup.sh` installs it once into `~/Library/Application Support/OpenWhisper/tts`;
/// the app starts the server itself and the server quits when the app does. Until it is
/// installed and warm Jarvis stays silent. One instance for the app, since it owns the server.
@MainActor
final class LocalOmniVoiceProvider: SpeechSynthesisProvider {
    static let shared = LocalOmniVoiceProvider()

    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "local",
        title: "Yerel — OmniVoice",
        summary: "Bu Mac'te çalışan OmniVoice modeliyle, internetsiz ve ücretsiz. Kurulum bir kez: app/tts_server/setup.sh",
        models: [SpeechModelOption(id: voiceModel, title: "OmniVoice", detail: "Jarvis referans sesinden klonlanır.")],
        needsAPIKey: false,
        make: { _, _, _ in LocalOmniVoiceProvider.shared }
    )

    nonisolated static let port = 8767
    /// Part of the cache key: changing the model or its settings in server.py must bump this.
    nonisolated static let voiceModel = "omnivoice-bf16-steps32"

    static var serverDirectory: URL { JarvisVoice.supportDirectory.appendingPathComponent("tts") }
    private static var python: URL { serverDirectory.appendingPathComponent(".venv/bin/python") }
    private static var serverScript: URL { serverDirectory.appendingPathComponent("server.py") }
    private static var referenceClip: URL { serverDirectory.appendingPathComponent("jarvis_ref.wav") }
    private static let baseURL = URL(string: "http://127.0.0.1:\(port)")!

    private var serverProcess: Process?
    private var serverReady = false
    private var preparing = false
    /// Hash of the reference clip, so a new voice doesn't replay the old one from the cache.
    private var voiceID: String?

    let displayName = "OmniVoice"
    let prefetchesAcks = true
    var isReady: Bool { serverReady }
    var notReadyReason: String { "local voice not ready" }

    /// Same string the cache key was built from before providers existed, so the phrases
    /// already cached on disk stay valid.
    var cacheIdentity: String {
        if voiceID == nil {
            let clip = (try? Data(contentsOf: Self.referenceClip)) ?? Data()
            voiceID = SHA256.hash(data: clip).map { String(format: "%02x", $0) }.joined()
        }
        return "\(Self.voiceModel)|\(voiceID ?? "")"
    }

    // MARK: - Server

    /// Starts the voice server if needed and waits until the model is loaded (~15 s from the
    /// cache). Safe to call repeatedly.
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

    /// Stops the server we started, freeing its several GB. `prepare()` starts it again
    /// (~15 s) when the local voice is picked again.
    func suspend() {
        serverReady = false
        guard let serverProcess else { return }
        self.serverProcess = nil
        if serverProcess.isRunning {
            serverProcess.terminate()
            owLog("[Voice] Stopped local voice server (pid \(serverProcess.processIdentifier))")
        }
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

    // MARK: - Synthesis

    /// Synthesizing takes ~1–3 s; the music stays paused meanwhile, so the wait is bounded.
    func synthesize(_ text: String) async throws -> Data {
        guard serverReady else { throw SpeechSynthesisError.notReady(notReadyReason) }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("speak"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "language": "tr"])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // Our own server on localhost; its error body is safe to show.
                owLog("[Voice] Voice server HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
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
