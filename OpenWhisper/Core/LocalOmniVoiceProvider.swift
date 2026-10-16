import CryptoKit
import Foundation

/// Jarvis's local voice: OmniVoice on MLX, served by `tts_server/server.py` on 127.0.0.1.
/// `tts_server/setup.sh` installs it once into `~/Library/Application Support/OpenWhisper/tts`;
/// the app starts the server itself and the server quits when the app does. Until it is
/// installed and warm Jarvis stays silent. One instance for the app, since it owns the server.
@MainActor
final class LocalOmniVoiceProvider: SpeechSynthesisProvider {
    static let shared = LocalOmniVoiceProvider()

    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "local",
        title: "Yerel — OmniVoice",
        summary: "Bu Mac'te çalışan OmniVoice modeliyle, internetsiz ve ücretsiz. Kurulum bir kez: app/tts_server/setup.sh",
        models: [SpeechModelOption(id: voiceModel, title: "OmniVoice", detail: "Jarvis referans sesinden klonlanır.")],
        needsAPIKey: false,
        make: { _, _, _ in LocalOmniVoiceProvider.shared }
    )

    nonisolated static let port = 8767
    /// Part of the cache key: changing the model or its settings in server.py must bump this.
    nonisolated static let voiceModel = "omnivoice-bf16-steps32"

    static var serverDirectory: URL { JarvisVoice.supportDirectory.appendingPathComponent("tts") }
    private static var referenceClip: URL { serverDirectory.appendingPathComponent("jarvis_ref.wav") }

    private let server = LocalModelServer(.init(port: port, directory: serverDirectory))
    private var serverReady = false
    private var preparing = false
    /// Hash of the reference clip, so a new voice doesn't replay the old one from the cache.
    private var voiceID: String?

    let displayName = "OmniVoice"
    let prefetchesAcks = true
    var isReady: Bool { serverReady }
    var notReadyReason: String { "local voice not ready" }

    /// Same string the cache key was built from before providers existed, so the phrases
    /// already cached on disk stay valid.
    var cacheIdentity: String {
        if voiceID == nil {
            let clip = (try? Data(contentsOf: Self.referenceClip)) ?? Data()
            voiceID = SHA256.hash(data: clip).map { String(format: "%02x", $0) }.joined()
        }
        return "\(Self.voiceModel)|\(voiceID ?? "")"
    }

    // MARK: - Server

    /// Starts the voice server if needed and waits until the model is loaded (~15 s from the
    /// cache). Safe to call repeatedly.
    func prepare() async {
        guard !serverReady, !preparing else { return }
        preparing = true
        defer { preparing = false }

        if await server.health() == nil {
            guard server.isInstalled else {
                owLog("[Voice] Local voice not installed — run app/tts_server/setup.sh. Replies stay silent")
                return
            }
            do {
                let pid = try server.start()
                owLog("[Voice] Started local voice server (pid \(pid))")
            } catch {
                owLog("[Voice] Could not start voice server: \(error)")
                return
            }
        }

        switch await server.waitUntilReady(timeout: 180, poll: .seconds(1)) {
        case .ready:
            serverReady = true
            owLog("[Voice] Local voice ready")
        case .failed(let error):
            owLog("[Voice] Local voice failed to load: \(error). Log: \(server.logPath)")
        case .exited(let status):
            owLog("[Voice] Voice server exited (\(status)). Log: \(server.logPath)")
        case .timedOut:
            owLog("[Voice] Local voice did not become ready within 180 s")
        }
    }

    /// Stops the server we started, freeing its several GB. `prepare()` starts it again
    /// (~15 s) when the local voice is picked again.
    func suspend() {
        serverReady = false
        if let pid = server.stop() {
            owLog("[Voice] Stopped local voice server (pid \(pid))")
        }
    }

    // MARK: - Synthesis

    /// Synthesizing takes ~1–3 s; the music stays paused meanwhile, so the wait is bounded.
    func synthesize(_ text: String) async throws -> Data {
        guard serverReady else { throw SpeechSynthesisError.notReady(notReadyReason) }
        var request = URLRequest(url: server.baseURL.appendingPathComponent("speak"), timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "language": "tr"])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                // Our own server on localhost; its error body is safe to show.
                owLog("[Voice] Voice server HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
                if status == 503 { serverReady = false }
                throw SpeechSynthesisError.failed("HTTP \(status)")
            }
            return data
        } catch is CancellationError {
            throw SpeechSynthesisError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw SpeechSynthesisError.cancelled
        } catch let error as URLError {
            // The server may have died; the next reply restarts it.
            if error.code == .cannotConnectToHost { serverReady = false }
            throw SpeechSynthesisError.failed("request failed: \(error.localizedDescription)")
        }
    }
}
