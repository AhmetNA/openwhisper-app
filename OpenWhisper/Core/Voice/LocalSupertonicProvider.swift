import Foundation

/// Supertonic 3's M1 voice in Turkish, int4 Core ML on the Neural Engine (~120 MB RAM).
@MainActor
final class LocalSupertonicProvider: LocalServerVoice {
    static let shared = LocalSupertonicProvider()
    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "supertonic",
        title: "Yerel — Supertonic 3 (Türkçe)",
        summary: "İnternetsiz, hazır erkek sesi. Supertone Supertonic 3, OpenRAIL-M.",
        models: [SpeechModelOption(id: voiceModel, title: "Supertonic 3 int4", detail: "Sabit Türkçe erkek sesi, Neural Engine'de çalışır.")],
        needsAPIKey: false,
        make: { _, _, _ in LocalSupertonicProvider.shared }
    )
    nonisolated static let port = 8777
    /// Includes model revision, quantization, voice and sampling, to isolate cached speech.
    nonisolated static let voiceModel = "supertonic3-coreml-2b5b939|v2-L128-int4|M1|tr|steps8|speed1.05|seed42"

    private init() {
        super.init(naming: .init(display: "Supertonic 3", short: "Supertonic", setupFolder: "servers/tts_supertonic_server"),
                   port: Self.port, folder: "tts-supertonic", voiceModel: Self.voiceModel, speakTimeout: 30)
    }
}
