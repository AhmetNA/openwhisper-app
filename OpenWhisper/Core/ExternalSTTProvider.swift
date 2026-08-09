import Foundation

/// A provider manifest describes an external local ASR runtime without adding a Swift model
/// class. Its bridge must implement:
///   --check                 -> JSON, exit 0 when the runtime/model can be prepared
///   --transcribe <wav-path> -> {"text":"..."} JSON on stdout
struct ExternalSTTProviderManifest: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let bridge: String
    let supportedLanguages: [String]
    let python: String?
}

final class ExternalSTTProvider: @unchecked Sendable {
    private struct Runtime: Sendable {
        let python: URL
        let bridge: URL
    }

    private enum ProviderError: LocalizedError {
        case runtimeNotFound
        case invalidResponse
        case processFailed(String)

        var errorDescription: String? {
            switch self {
            case .runtimeNotFound:
                return "Dış STT sağlayıcısı için Python ortamı veya köprü bulunamadı."
            case .invalidResponse:
                return "Dış STT sağlayıcısı geçerli JSON sonuç döndürmedi."
            case .processFailed(let message):
                return "Dış STT sağlayıcısı başarısız oldu: \(message)"
            }
        }
    }

    let manifest: ExternalSTTProviderManifest
    let descriptor: TranscriptionModelDescriptor
    private let manifestURL: URL
    private var ready = false

    init(manifest: ExternalSTTProviderManifest, manifestURL: URL) {
        self.manifest = manifest
        descriptor = TranscriptionModelDescriptor(id: manifest.id, displayName: manifest.displayName)
        self.manifestURL = manifestURL
    }

    /// Availability means the bridge and its launcher can be found. We deliberately do not run
    /// model inference here; selecting a provider performs the real --check and may download
    /// weights through the provider's own cache mechanism.
    var isAvailable: Bool { resolveRuntime() != nil }
    var isDownloaded: Bool { isAvailable }

    func loadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.10)
        let runtime = try resolveRuntimeOrThrow()
        progress(0.25)
        _ = try await run(arguments: ["--check"], runtime: runtime)
        ready = true
        progress(1.0)
        owLog("[STTProvider:\(manifest.id)] \(manifest.displayName) hazır")
    }

    func transcribe(audioData: [Float], language: String) async throws -> String {
        guard ready else { throw ProviderError.processFailed("model henüz yüklenmedi") }
        if !manifest.supportedLanguages.isEmpty,
           language != "auto",
           !manifest.supportedLanguages.contains(language) {
            owLog("[STTProvider:\(manifest.id)] language='\(language)' desteklenmiyor; sağlayıcının varsayılan dili kullanılacak")
        }

        let runtime = try resolveRuntimeOrThrow()
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openwhisper-stt-\(manifest.id)-\(UUID().uuidString).wav")
        try Self.writePCM16WAV(audioData, to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let response = try await run(arguments: ["--transcribe", wavURL.path], runtime: runtime)
        guard let text = response["text"] as? String else { throw ProviderError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveRuntimeOrThrow() throws -> Runtime {
        guard let runtime = resolveRuntime() else { throw ProviderError.runtimeNotFound }
        return runtime
    }

    private func resolveRuntime() -> Runtime? {
        let fm = FileManager.default
        let bridgeURL = manifestURL.deletingLastPathComponent().appendingPathComponent(manifest.bridge)
        guard fm.isReadableFile(atPath: bridgeURL.path) else { return nil }

        var candidates: [URL] = []
        if let configuredPython = manifest.python, !configuredPython.isEmpty {
            let configuredURL = URL(fileURLWithPath: configuredPython)
            candidates.append(configuredURL.path.hasPrefix("/")
                              ? configuredURL
                              : manifestURL.deletingLastPathComponent().appendingPathComponent(configuredPython))
        }
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["OPENWHISPER_STT_PYTHON"] ?? environment["OPENWHISPER_TURKISH_STT_PYTHON"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates += [
            sourceRoot.appendingPathComponent(".venv/bin/python"),
            sourceRoot.appendingPathComponent(".venv/bin/python3"),
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ]
        guard let python = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else { return nil }
        return Runtime(python: python, bridge: bridgeURL)
    }

    private func run(arguments: [String], runtime: Runtime) async throws -> [String: Any] {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = runtime.python
            process.arguments = [runtime.bridge.path] + arguments
            process.standardOutput = stdout
            process.standardError = stderr
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONUNBUFFERED"] = "1"
            process.environment = environment
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw ProviderError.processFailed(error.localizedDescription)
            }

            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let detail = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "exit \(process.terminationStatus)"
                throw ProviderError.processFailed(detail)
            }
            guard let object = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                throw ProviderError.invalidResponse
            }
            return object
        }.value
    }

    private static func writePCM16WAV(_ samples: [Float], to url: URL) throws {
        var pcm = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var value = Int16((clamped * 32767.0).rounded())
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        var header = Data()
        func appendASCII(_ value: String) { header.append(value.data(using: .ascii)!) }
        func appendUInt32LE(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
        }
        func appendUInt16LE(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendUInt32LE(UInt32(36 + pcm.count))
        appendASCII("WAVEfmt ")
        appendUInt32LE(16)
        appendUInt16LE(1)
        appendUInt16LE(1)
        appendUInt32LE(16_000)
        appendUInt32LE(32_000)
        appendUInt16LE(2)
        appendUInt16LE(16)
        appendASCII("data")
        appendUInt32LE(UInt32(pcm.count))
        try (header + pcm).write(to: url, options: .atomic)
    }
}

extension ExternalSTTProvider: TranscriptionModelProvider {
    func transcribe(audioData: [Float], language: String, overlapSampleCount: Int) async throws -> String {
        try await transcribe(audioData: audioData, language: language)
    }
}
