import Foundation

struct TranscriptionModelDescriptor: Sendable, Hashable {
    let id: String
    let displayName: String
}

private struct WhisperKitModelCatalog: Codable {
    let schemaVersion: Int
    let models: [Model]

    struct Model: Codable {
        let id: String
        let displayName: String
    }
}

/// Common abstraction for every selectable speech-to-text model. Swift protocols are used instead
/// of a model-specific abstract base class so WhisperKit, external processes, and future native
/// runtimes can all participate without inheriting implementation details.
protocol TranscriptionModelProvider: WhisperTranscriptionService {
    var descriptor: TranscriptionModelDescriptor { get }
    var isAvailable: Bool { get }
    var isDownloaded: Bool { get }
    func loadModel(progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Adapts one WhisperKit variant to the same provider contract used by external model bridges.
final class WhisperKitTranscriptionProvider: @unchecked Sendable {
    let descriptor: TranscriptionModelDescriptor
    private let modelName: String
    private let transcriber: WhisperTranscriber

    init(modelName: String, displayName: String, transcriber: WhisperTranscriber) {
        self.modelName = modelName
        descriptor = TranscriptionModelDescriptor(id: modelName, displayName: displayName)
        self.transcriber = transcriber
    }

    var isAvailable: Bool { true }
    var isDownloaded: Bool { transcriber.isModelDownloaded(name: modelName) }

    func loadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await transcriber.loadModel(name: modelName, progress: progress)
    }
}

extension WhisperKitTranscriptionProvider: TranscriptionModelProvider {
    func transcribe(audioData: [Float], language: String, overlapSampleCount: Int) async throws -> String {
        try await transcriber.transcribe(
            audioData: audioData,
            language: language,
            overlapSampleCount: overlapSampleCount
        )
    }

    func transcribeTimed(
        audioData: [Float],
        language: String,
        overlapSampleCount: Int
    ) async throws -> TimedTranscriptionResult {
        try await transcriber.transcribeTimed(
            audioData: audioData,
            language: language,
            overlapSampleCount: overlapSampleCount
        )
    }
}

/// Single registry for built-in and user-installed speech providers.
final class TranscriptionModelRegistry: @unchecked Sendable {
    private(set) var providers: [String: any TranscriptionModelProvider] = [:]

    static let defaultModelID = "large-v3-v20240930_turbo"

    init() {
        let whisperTranscriber = WhisperTranscriber()
        if let catalogURL = Bundle.module.url(forResource: "whisperkit_models", withExtension: "json"),
           let data = try? Data(contentsOf: catalogURL),
           let catalog = try? JSONDecoder().decode(WhisperKitModelCatalog.self, from: data),
           catalog.schemaVersion == 1 {
            for model in catalog.models {
                register(WhisperKitTranscriptionProvider(
                    modelName: model.id,
                    displayName: model.displayName,
                    transcriber: whisperTranscriber
                ))
            }
        } else {
            owLog("[TranscriptionModelRegistry] WhisperKit model manifesti bulunamadı")
        }

        let userDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpenWhisper/STTProviders")
        var manifestURLs = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        if let userURLs = try? FileManager.default.contentsOfDirectory(
            at: userDirectory, includingPropertiesForKeys: nil
        ) {
            manifestURLs.append(contentsOf: userURLs.filter { $0.pathExtension.lowercased() == "json" })
        }

        for url in manifestURLs {
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(ExternalSTTProviderManifest.self, from: data),
                  manifest.schemaVersion == 1 else { continue }
            register(ExternalSTTProvider(manifest: manifest, manifestURL: url))
        }
        owLog("[TranscriptionModelRegistry] keşfedilen sağlayıcılar: \(providers.keys.sorted().joined(separator: ", "))")
    }

    var availableProviders: [any TranscriptionModelProvider] {
        providers.values
            .filter(\.isAvailable)
            .sorted { $0.descriptor.displayName < $1.descriptor.displayName }
    }

    func provider(for id: String) -> (any TranscriptionModelProvider)? { providers[id] }

    private func register(_ provider: any TranscriptionModelProvider) {
        guard providers[provider.descriptor.id] == nil else {
            owLog("[TranscriptionModelRegistry] duplicate provider ignored: \(provider.descriptor.id)")
            return
        }
        providers[provider.descriptor.id] = provider
    }
}
