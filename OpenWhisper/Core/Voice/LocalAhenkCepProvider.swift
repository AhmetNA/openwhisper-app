import Foundation

/// Ahenk Cep's fixed synthetic Turkish voice, served locally on the CPU.
@MainActor
final class LocalAhenkCepProvider: LocalServerVoice {
    static let shared = LocalAhenkCepProvider()
    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "ahenk",
        title: "Yerel — Ahenk Cep (Türkçe)",
        summary: "İnternetsiz, yapay kadın sesi. Ahenk Cep / Ahenk, CC BY 4.0.",
        models: [SpeechModelOption(id: voiceModel, title: "Ahenk Cep", detail: "Sabit Türkçe kadın sesi, CPU'da çalışır.")],
        needsAPIKey: false,
        make: { _, _, _ in LocalAhenkCepProvider.shared }
    )
    nonisolated static let port = 8776
    nonisolated static let voiceModel = "ahenk-345c4cb|ema1.1.2|trnorm8981df9|seed0|steps16|cfg2|speed1|48k"

    private init() {
        super.init(naming: .init(display: "Ahenk Cep", short: "Ahenk", setupFolder: "servers/tts_ahenk_server"),
                   port: Self.port, folder: "tts-ahenk", voiceModel: Self.voiceModel, speakTimeout: 30)
    }
}
