import Foundation

/// Alternative speech model: NVIDIA Nemotron 3.5 ASR 0.6B on PyTorch/MPS, served by
/// `servers/nemotron_asr_server/server.py` on 127.0.0.1. `servers/nemotron_asr_server/setup.sh`
/// installs it once into `~/Library/Application Support/OpenWhisper/nemotron`; the app starts the
/// server when it is picked and the server quits when the app does.
actor NemotronASRServer {
    static let shared = NemotronASRServer()

    nonisolated static let port = 8776
    nonisolated private static let server = LocalModelServer(.init(
        port: port, directory: JarvisVoice.supportDirectory.appendingPathComponent("nemotron")))

    nonisolated static var isInstalled: Bool { server.isInstalled }

    enum ServerError: LocalizedError {
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Nemotron 3.5 ASR kurulu değil — terminalde: app/servers/nemotron_asr_server/setup.sh"
            case .failed(let message):
                return "Nemotron 3.5 ASR: \(message)"
            }
        }
    }

    private var ready = false

    /// Starts the server if needed and waits until the model is loaded (~20 s from the cache).
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let server = Self.server
        if ready, case .ready? = await server.health() { return }
        ready = false
        progress(0.1)
        if await server.health() == nil {
            guard Self.isInstalled else { throw ServerError.notInstalled }
            do {
                let pid = try await server.start()
                owLog("[NemotronASR] Started server (pid \(pid))")
            } catch {
                throw ServerError.failed("sunucu başlatılamadı: \(error.localizedDescription)")
            }
        }
        progress(0.3)
        switch await server.waitUntilReady(timeout: 180, poll: .milliseconds(500)) {
        case .ready:
            ready = true
            progress(1.0)
            owLog("[NemotronASR] Server ready")
        case .failed(let error):
            throw ServerError.failed("model yüklenemedi: \(error). Log: \(server.logPath)")
        case .exited(let status):
            throw ServerError.failed("sunucu kapandı (\(status)). Log: \(server.logPath)")
        case .timedOut:
            try Task.checkCancellation()
            throw ServerError.failed("180 sn içinde hazır olmadı")
        }
    }

    /// Frees the model's memory when another speech model is picked.
    func stop() async {
        ready = false
        if let pid = await Self.server.stop() {
            owLog("[NemotronASR] Stopped server (pid \(pid))")
        }
    }

    func transcribe(_ samples: [Float], language: String) async throws -> String {
        guard ready else { throw ServerError.failed("model henüz yüklenmedi") }
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            var value = Int16((max(-1, min(1, sample)) * 32767).rounded()).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }
        let body: [String: Any] = ["audio_pcm16_b64": pcm.base64EncodedString(), "language": language]

        var request = URLRequest(url: Self.server.baseURL.appendingPathComponent("transcribe"), timeoutInterval: 60)
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
            owLog(String(format: "[NemotronASR] %.0f ms for %.1f s audio", ms, seconds))
        }
        return text
    }
}

/// The Settings option backed by `NemotronASRServer`.
final class LocalNemotronASRProvider: @unchecked Sendable {
    static let id = "nemotron-3.5-asr-0.6b"

    let descriptor = TranscriptionModelDescriptor(id: id, displayName: "Nemotron 3.5 ASR 0.6B (deneysel)")
}

extension LocalNemotronASRProvider: TranscriptionModelProvider {
    /// Always listed so it can be picked; `loadModel` explains how to install it when missing.
    var isAvailable: Bool { true }
    var isDownloaded: Bool { NemotronASRServer.isInstalled }

    func loadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await NemotronASRServer.shared.prepare(progress: progress)
    }

    func transcribe(audioData: [Float], language: String, overlapSampleCount: Int) async throws -> String {
        try await NemotronASRServer.shared.transcribe(audioData, language: language)
    }
}
