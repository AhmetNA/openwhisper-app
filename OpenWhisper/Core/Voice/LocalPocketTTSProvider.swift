import Foundation

/// Default local voice: Pocket TTS Turkish (PyTorch on the CPU), served by
/// `servers/tts_pocket_server/server.py` on 127.0.0.1. `servers/tts_pocket_server/setup.sh` installs it once into
/// `~/Library/Application Support/OpenWhisper/tts-pocket`, apart from OmniVoice's venv. Clones
/// Jarvis from the same `jarvis_ref.wav` as OmniVoice. Measured on this Mac: ~2 s to load,
/// 0.2–0.5 s for a short reply, ~1.0 GB RAM. Also reads the Turkish fallback when the English
/// voice can't get a reply translated. One instance for the app, since it owns the server.
@MainActor
final class LocalPocketTTSProvider: LocalServerVoice {
    static let shared = LocalPocketTTSProvider()

    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "pocket",
        title: "Yerel — Pocket TTS (Türkçe)",
        summary: "Bu Mac'te, internetsiz çalışır. Kurulum: app/servers/tts_pocket_server/setup.sh",
        models: [SpeechModelOption(id: voiceModel, title: "Pocket TTS Turkish", detail: "Jarvis klonu, CPU'da çalışır.")],
        needsAPIKey: false,
        make: { _, _, _ in LocalPocketTTSProvider.shared }
    )

    nonisolated static let port = 8772
    /// The cache key: changing the package, model revision, reference clip or SEED in server.py
    /// must bump this.
    nonisolated static let voiceModel = "pocket-tts-turkish-0.1.0|fcbd37c|jarvis_ref|seed7|tr-only|24k|eos1"


    private init() {
        super.init(naming: .init(display: "Pocket TTS", short: "Pocket", setupFolder: "servers/tts_pocket_server"),
                   port: Self.port, folder: "tts-pocket", voiceModel: Self.voiceModel, speakTimeout: 30)
    }
}
