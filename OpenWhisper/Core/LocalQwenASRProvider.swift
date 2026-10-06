import Foundation

/// Alternative speech model: Qwen3-ASR 1.7B on MLX, served by `asr_server/server.py` on
/// 127.0.0.1. `asr_server/setup.sh` installs it once into
/// `~/Library/Application Support/OpenWhisper/asr`; the app starts the server when a Qwen option
/// is picked and the server quits when the app does. One server backs both Settings options.
actor QwenASRServer {
    static let shared = QwenASRServer()

    nonisolated static let port = 8769
    nonisolated static var serverDirectory: URL {
        JarvisVoice.supportDirectory.appendingPathComponent("asr")
    }
    nonisolated private static var python: URL { serverDirectory.appendingPathComponent(".venv/bin/python") }
    nonisolated private static var serverScript: URL { serverDirectory.appendingPathComponent("server.py") }
    nonisolated private static let baseURL = URL(string: "http://127.0.0.1:\(port)")!

    nonisolated static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: serverScript.path)
    }

    enum ServerError: LocalizedError {
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Qwen3-ASR kurulu değil — terminalde: app/asr_server/setup.sh"
            case .failed(let message):
                return "Qwen3-ASR: \(message)"
            }
        }
    }

    private var process: Process?
    private var ready = false

    /// Starts the server if needed and waits until the model is loaded (~5–10 s from the cache).
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if ready, await health() == .ready { return }
        ready = false
        progress(0.1)
        if await health() == nil {
            guard Self.isInstalled else { throw ServerError.notInstalled }
            try startServer()
        }
        progress(0.3)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            switch await health() {
            case .ready:
                ready = true
                progress(1.0)
                owLog("[QwenASR] Server ready")
                return
            case .failed(let error):
                throw ServerError.failed("model yüklenemedi: \(error). Log: \(Self.serverDirectory.path)/server.log")
            case .loading, nil:
                if let process, !process.isRunning {
                    self.process = nil
                    throw ServerError.failed("sunucu kapandı (\(process.terminationStatus)). Log: \(Self.serverDirectory.path)/server.log")
                }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw ServerError.failed("180 sn içinde hazır olmadı")
    }

    /// Frees the model's memory when another speech model is picked.
    func stop() {
        ready = false
        guard let process else { return }
        self.process = nil
        if process.isRunning {
            process.terminate()
            owLog("[QwenASR] Stopped server (pid \(process.processIdentifier))")
        }
    }

    func transcribe(_ samples: [Float], language: String, hotwords: [String]?) async throws -> String {
        guard ready else { throw ServerError.failed("model henüz yüklenmedi") }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16((max(-1, min(1, sample)) * 32767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        var body: [String: Any] = ["audio_pcm16_b64": pcm.base64EncodedString(), "language": language]
        if let hotwords, !hotwords.isEmpty { body["hotwords"] = hotwords }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("transcribe"), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            ready = false  // the server died; the next model load restarts it
            throw ServerError.failed("sunucuya bağlanılamadı")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String
        else {
            if status == 503 { ready = false }
            throw ServerError.failed("HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        if let ms = json["ms"] as? Double, let seconds = json["seconds"] as? Double {
            owLog(String(format: "[QwenASR] %.0f ms for %.1f s audio (hotwords: %d)", ms, seconds, hotwords?.count ?? 0))
        }
        return text
    }

    private func startServer() throws {
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
            throw ServerError.failed("sunucu başlatılamadı: \(error.localizedDescription)")
        }
        self.process = process
        owLog("[QwenASR] Started server (pid \(process.processIdentifier))")
    }

    private enum Health: Equatable { case loading, ready, failed(String) }

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
}

/// One Settings option backed by `QwenASRServer`. With `useGlossary`, the user's glossary is
/// sent as hotwords (Whisper can't take it in this app; see `WhisperTranscriber`), which can
/// make Qwen write the glossary words themselves on short or unclear clips.
final class LocalQwenASRProvider: @unchecked Sendable {
    static let plainID = "qwen3-asr-1.7b"
    static let glossaryID = "qwen3-asr-1.7b-glossary"

    let descriptor: TranscriptionModelDescriptor
    private let useGlossary: Bool

    init(useGlossary: Bool) {
        self.useGlossary = useGlossary
        descriptor = useGlossary
            ? TranscriptionModelDescriptor(id: Self.glossaryID, displayName: "Qwen3-ASR 1.7B + sözlük (deneysel)")
            : TranscriptionModelDescriptor(id: Self.plainID, displayName: "Qwen3-ASR 1.7B (deneysel)")
    }

    static func isQwen(_ id: String) -> Bool { id == plainID || id == glossaryID }
}

extension LocalQwenASRProvider: TranscriptionModelProvider {
    /// Always listed so it can be picked; `loadModel` explains how to install it when missing.
    var isAvailable: Bool { true }
    var isDownloaded: Bool { QwenASRServer.isInstalled }

    func loadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await QwenASRServer.shared.prepare(progress: progress)
    }

    func transcribe(audioData: [Float], language: String, overlapSampleCount: Int) async throws -> String {
        try await QwenASRServer.shared.transcribe(
            audioData,
            language: language,
            hotwords: useGlossary ? GlossaryStore.terms() : nil
        )
    }
}
