import Foundation

/// Experimental local voice: EMA Lightning (PyTorch on the CPU), served by
/// `servers/tts_ema_server/server.py` on 127.0.0.1. `servers/tts_ema_server/setup.sh` installs it once into
/// `~/Library/Application Support/OpenWhisper/tts-ema`, apart from OmniVoice's venv. One fixed
/// Turkish voice, no cloning. Measured on this Mac: ~1.6 s to load, 30–50 ms for a short reply,
/// ~460 MB RAM. One instance for the app, since it owns the server.
@MainActor
final class LocalEMALightningProvider: LocalServerVoice {
    static let shared = LocalEMALightningProvider()

    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "ema",
        title: "Yerel — EMA Lightning (deneysel)",
        summary: "Bu Mac'te, internetsiz çalışır. Kurulum: app/servers/tts_ema_server/setup.sh",
        models: [SpeechModelOption(id: voiceModel, title: "EMA Lightning", detail: "Sabit Türkçe ses, CPU'da çalışır.")],
        needsAPIKey: false,
        make: { _, _, _ in LocalEMALightningProvider.shared }
    )

    nonisolated static let port = 8770
    /// The cache key: changing the package, model revision or SAMPLE_RATE/SEED/SPEED in
    /// server.py must bump this.
    nonisolated static let voiceModel = "ema-lightning-1.0.1|7a6ba1a|seed7|speed1.0|24k"


    private init() {
        super.init(naming: .init(display: "EMA Lightning", short: "EMA", setupFolder: "servers/tts_ema_server"),
                   port: Self.port, folder: "tts-ema", voiceModel: Self.voiceModel, speakTimeout: 10)
    }
}
