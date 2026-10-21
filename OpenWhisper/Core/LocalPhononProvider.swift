import Foundation

/// Optional offline English Phonon 31m voice, installed by tts_phonon_server/setup.sh.
@MainActor
final class LocalPhononProvider: LocalServerVoice {
    static let shared = LocalPhononProvider()

    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "phonon",
        title: "Yerel — Phonon 31m (İngilizce)",
        summary: "Bu Mac'te çalışan küçük Phonon 31m modeliyle, internetsiz ve ücretsiz. Jarvis İngilizce cevap verir; Türkçe sistem cevapları yerel modelle (Ollama) İngilizceye çevrilir. Kurulum bir kez: app/tts_phonon_server/setup.sh",
        models: [SpeechModelOption(id: voiceModel, title: "Phonon 31m Q8", detail: "İngilizce ses; yanıta göre hafif, otomatik tonlama.")],
        needsAPIKey: false,
        make: { _, _, _ in LocalPhononProvider.shared }
    )

    nonisolated static let port = 8775
    /// Includes model, runtime, voice and quantization to isolate cached speech.
    nonisolated static let voiceModel = "phonon-31m|52433c4|ptts0.4.0|default|q8|24k|prosody-v1-seed42-temp0.3"


    private init() {
        super.init(naming: .init(display: "Phonon 31m", short: "Phonon", setupFolder: "tts_phonon_server"),
                   port: Self.port, folder: "tts-phonon", voiceModel: Self.voiceModel, speakTimeout: 30,
                   replyLanguage: .english)
    }
}
