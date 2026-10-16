import Foundation
import os

/// Fast local classifier for the decisions Ollama used to make (Spotify intent, "is this a real
/// wake call", "is the user talking to Jarvis", "did the user confirm the reminder deletion"). SetFit models trained on Jarvis' own data
/// (`decision_model/`) are served by `decider/server.py` on 127.0.0.1:8768: ~7 ms per decision
/// instead of ~1 s. The app starts the server itself and it quits with the app.
///
/// Only used when Settings › "Karar motoru" is SetFit. Every caller keeps its Ollama path: when
/// the server is down, slow, or its confidence is below the task's threshold, the decision falls
/// through to Ollama exactly as before, so SetFit can only skip an LLM round trip, never remove
/// a safety check. Each decision is logged as `[Decider]` with the backend that made it.
@MainActor
final class SetFitDecider {
    static let shared = SetFitDecider()

    nonisolated static let port = 8768
    nonisolated static let defaultsKey = "decisionEngine"

    enum Engine: String, CaseIterable, Identifiable {
        case ollama, setfit
        /// Experiment: EmbeddingGemma-300M base (`train.py --base embeddinggemma`). Tasks that
        /// have no such model yet use the MiniLM one.
        case setfitGemma = "setfit-embeddinggemma"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ollama: return "Ollama (LLM)"
            case .setfit: return "SetFit (hızlı) + Ollama yedek"
            case .setfitGemma: return "SetFit EmbeddingGemma (deneysel)"
            }
        }
        /// Used until the user picks one. Without the decider installed, every decision still
        /// falls through to Ollama (`prepare` reports "Kurulu değil").
        static let defaultEngine: Engine = .setfit
        var usesSetFit: Bool { self != .ollama }
        /// `server.py --variant`.
        var serverVariant: String { self == .setfitGemma ? "embeddinggemma" : "minilm" }
    }

    enum Task: String, Sendable {
        case spotifyIntent = "spotify_intent"
        case wakeCall = "wake_call"
        case addressee
        case reminderConfirm = "reminder_confirm"

        /// Below this, the answer is ignored and Ollama decides. Measured on the dev set
        /// (27 Sep 2026): spotify at 0.9 was 96% right while answering 75% of the texts.
        var minConfidence: Double {
            switch self {
            case .spotifyIntent: return 0.9
            case .wakeCall, .addressee: return 0.8
            // Deleting is irreversible, so ReminderManager also never lets SetFit approve alone.
            case .reminderConfirm: return 0.9
            }
        }
    }

    struct Decision: Sendable {
        let label: String
        let confidence: Double
        let probabilities: [String: Double]
        let ms: Double
        var confident: Bool = false
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWhisper/decider")
    }
    private nonisolated static let baseURL = URL(string: "http://127.0.0.1:\(port)")!

    /// Read from any thread by the static callers (SpotifyManager, WakeWordVerifier…).
    private nonisolated static let readyFlag = OSAllocatedUnfairLock(initialState: false)
    nonisolated static var isReady: Bool { readyFlag.withLock { $0 } }
    nonisolated static var isEnabled: Bool {
        (UserDefaults.standard.string(forKey: defaultsKey).flatMap(Engine.init(rawValue:)) ?? .defaultEngine).usesSetFit
    }
    /// SetFit is selected and its server answered /health.
    nonisolated static var isActive: Bool { isEnabled && isReady }

    private(set) var status = "Kapalı"
    // A menu-bar app's child otherwise runs at background QoS: efficiency cores and
    // coalesced timers made ~1 in 3 decisions take 300–400 ms instead of ~10 ms.
    private let server = LocalModelServer(.init(port: port, directory: supportDirectory,
                                                extraArguments: ["--variant", Engine.setfit.serverVariant],
                                                qualityOfService: .userInitiated))
    private var preparing = false
    private var variant = Engine.setfit.serverVariant {
        didSet { server.setExtraArguments(["--variant", variant]) }
    }

    // MARK: - Server

    /// Starts the server if needed and waits until the models are loaded (~5 s). Safe to call
    /// repeatedly; `status` describes the outcome for Settings.
    func prepare(engine: Engine = .setfit) async {
        if variant != engine.serverVariant {
            stop()
            variant = engine.serverVariant
        }
        guard !Self.isReady, !preparing else { return }
        preparing = true
        defer { preparing = false }

        if await server.health() == nil {
            guard server.isInstalled else {
                status = "Kurulu değil — terminalde: decision_model/install.sh"
                owLog("[Decider] SetFit not installed — run decision_model/install.sh. Using Ollama")
                return
            }
            do {
                let pid = try server.start()
                owLog("[Decider] Started SetFit server (pid \(pid))")
            } catch {
                status = "Başlatılamadı: \(error.localizedDescription)"
                owLog("[Decider] Could not start SetFit server: \(error)")
                return
            }
        }
        status = "Yükleniyor…"
        let outcome = await server.waitUntilReady(timeout: 90, poll: .milliseconds(500)) { json in
            let served = json["variant"] as? String ?? "minilm"
            guard served == variant else {
                // A server left from another run serves the other base model.
                status = "Model değiştiriliyor…"
                owLog("[Decider] SetFit server has \(served), reloading as \(variant)")
                await reload()
                return false
            }
            return true
        }
        switch outcome {
        case .ready(let json):
            let models = Self.describeModels(json)
            Self.readyFlag.withLock { $0 = true }
            status = "Hazır — \(models)"
            owLog("[Decider] SetFit ready: \(models)")
        case .failed(let error):
            status = "Yüklenemedi: \(error)"
            owLog("[Decider] SetFit failed to load: \(error). Log: \(server.logPath)")
        case .exited(let code):
            status = "Sunucu kapandı (\(code))"
            owLog("[Decider] SetFit server exited (\(code)). Log: \(server.logPath)")
        case .timedOut:
            status = "90 sn içinde hazır olmadı"
            owLog("[Decider] SetFit server did not become ready within 90 s")
        }
    }

    /// Switching back to Ollama frees the server's memory (~0.5 GB).
    func stop() {
        Self.readyFlag.withLock { $0 = false }
        server.stop()
        status = "Kapalı"
    }

    private func reload() async {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("reload"), timeoutInterval: 90)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["variant": variant])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// "addressee %94, reminder_confirm %89, …" from the `/health` answer.
    private static func describeModels(_ json: [String: Any]) -> String {
        (json["models"] as? [String: [String: Any]] ?? [:])
            .sorted { $0.key < $1.key }
            .map { name, meta in
                let accuracy = (meta["accuracy"] as? Double).map { String(format: "%%%.0f", $0 * 100) } ?? "?"
                let base = meta["variant"] as? String == "embeddinggemma" ? " (Gemma)" : ""
                return "\(name) \(accuracy)\(base)"
            }
            .joined(separator: ", ")
    }

    // MARK: - Decisions

    /// One decision, or nil when SetFit is off, not ready, or doesn't answer within `timeout`.
    /// `confident` says whether it cleared the task's threshold; callers act only on those.
    nonisolated static func decide(_ task: Task, text: String, timeout: TimeInterval = 0.5) async -> Decision? {
        guard isActive else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("decide"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["task": task.rawValue, "text": text])
        let started = Date()
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let label = json["label"] as? String,
              let confidence = json["confidence"] as? Double
        else {
            owLog("[Decider] SetFit \(task.rawValue) gave no answer in \(Int(Date().timeIntervalSince(started) * 1000)) ms → Ollama")
            return nil
        }
        var decision = Decision(label: label, confidence: confidence,
                                probabilities: json["probabilities"] as? [String: Double] ?? [:],
                                ms: json["ms"] as? Double ?? 0)
        decision.confident = confidence >= task.minConfidence
        owLog(String(format: "[Decider] SetFit %@ '%@' → %@ %.2f (%.0f ms)%@",
                     task.rawValue, text, label, confidence, decision.ms,
                     decision.confident ? "" : " below \(task.minConfidence) → Ollama"))
        return decision
    }
}
