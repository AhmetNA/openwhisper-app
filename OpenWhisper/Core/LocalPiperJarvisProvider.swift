import Foundation

/// Jarvis's English voice: Piper's Jarvis model (jgkawell/jarvis, medium, ONNX on the CPU),
/// served by `tts_piper_server/server.py` on 127.0.0.1. `tts_piper_server/setup.sh` installs it
/// once into `~/Library/Application Support/OpenWhisper/tts-piper` (needs Homebrew's espeak-ng).
/// Picking it makes Jarvis answer in English: `JarvisVoice` translates the Turkish replies and
/// the chat answers in English. Measured on this Mac: ~2 s to load, ~70 ms for a short reply,
/// ~150 MB RAM. One instance for the app, since it owns the server.
@MainActor
final class LocalPiperJarvisProvider: LocalServerVoice {
    static let shared = LocalPiperJarvisProvider()

    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "piper",
        title: "Yerel — Piper Jarvis (İngilizce)",
        summary: "Bu Mac'te, internetsiz çalışır. Jarvis İngilizce cevap verir. Kurulum: brew install espeak-ng, sonra app/tts_piper_server/setup.sh",
        models: [SpeechModelOption(id: voiceModel, title: "Piper Jarvis medium", detail: "İngilizce Jarvis sesi, CPU'da çalışır.")],
        needsAPIKey: false,
        make: { _, _, _ in LocalPiperJarvisProvider.shared }
    )

    nonisolated static let port = 8773
    /// The cache key: changing the model revision or the phonemization in server.py must bump
    /// this.
    nonisolated static let voiceModel = "piper-jarvis-medium|37f8763|espeak-en-gb|22k"


    private init() {
        super.init(naming: .init(display: "Piper Jarvis", short: "Piper", setupFolder: "tts_piper_server"),
                   port: Self.port, folder: "tts-piper", voiceModel: Self.voiceModel, speakTimeout: 30,
                   replyLanguage: .english)
    }
}
