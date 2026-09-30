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
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ollama: return "Ollama (LLM)"
            case .setfit: return "SetFit (hızlı) + Ollama yedek"
            }
        }
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
    private static var python: URL { supportDirectory.appendingPathComponent(".venv/bin/python") }
    private static var serverScript: URL { supportDirectory.appendingPathComponent("server.py") }
    private nonisolated static let baseURL = URL(string: "http://127.0.0.1:\(port)")!

    /// Read from any thread by the static callers (SpotifyManager, WakeWordVerifier…).
    private nonisolated static let readyFlag = OSAllocatedUnfairLock(initialState: false)
    nonisolated static var isReady: Bool { readyFlag.withLock { $0 } }
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.string(forKey: defaultsKey) == Engine.setfit.rawValue
    }
    /// SetFit is selected and its server answered /health.
    nonisolated static var isActive: Bool { isEnabled && isReady }

    private(set) var status = "Kapalı"
    private var serverProcess: Process?
    private var preparing = false

    // MARK: - Server

    /// Starts the server if needed and waits until the models are loaded (~5 s). Safe to call
    /// repeatedly; `status` describes the outcome for Settings.
    func prepare() async {
        guard !Self.isReady, !preparing else { return }
        preparing = true
        defer { preparing = false }

        if await health() == nil {
            guard FileManager.default.isExecutableFile(atPath: Self.python.path),
                  FileManager.default.fileExists(atPath: Self.serverScript.path)
            else {
                status = "Kurulu değil — terminalde: decision_model/install.sh"
                owLog("[Decider] SetFit not installed — run decision_model/install.sh. Using Ollama")
                return
            }
            guard startServer() else { return }
        }
        status = "Yükleniyor…"
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            switch await health() {
            case .ready(let models):
                Self.readyFlag.withLock { $0 = true }
                status = "Hazır — \(models)"
                owLog("[Decider] SetFit ready: \(models)")
                return
            case .failed(let error):
                status = "Yüklenemedi: \(error)"
                owLog("[Decider] SetFit failed to load: \(error). Log: \(Self.supportDirectory.path)/server.log")
                return
            case .loading, nil:
                if let serverProcess, !serverProcess.isRunning {
                    status = "Sunucu kapandı (\(serverProcess.terminationStatus))"
                    owLog("[Decider] SetFit server exited (\(serverProcess.terminationStatus)). Log: \(Self.supportDirectory.path)/server.log")
                    self.serverProcess = nil
                    return
                }
                try? await _Concurrency.Task.sleep(for: .milliseconds(500))
            }
        }
        status = "90 sn içinde hazır olmadı"
        owLog("[Decider] SetFit server did not become ready within 90 s")
    }

    /// Switching back to Ollama frees the server's memory (~0.5 GB).
    func stop() {
        Self.readyFlag.withLock { $0 = false }
        serverProcess?.terminate()
        serverProcess = nil
        status = "Kapalı"
    }

    private func startServer() -> Bool {
        let logURL = Self.supportDirectory.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let process = Process()
        process.executableURL = Self.python
        process.arguments = [Self.serverScript.path, "--port", "\(Self.port)",
                             "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)"]
        process.currentDirectoryURL = Self.supportDirectory
        // A menu-bar app's child otherwise runs at background QoS: efficiency cores and
        // coalesced timers made ~1 in 3 decisions take 300–400 ms instead of ~10 ms.
        process.qualityOfService = .userInitiated
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["HF_HUB_OFFLINE"] = "1"
        process.environment = environment
        if let log = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        do {
            try process.run()
        } catch {
            status = "Başlatılamadı: \(error.localizedDescription)"
            owLog("[Decider] Could not start SetFit server: \(error)")
            return false
        }
        serverProcess = process
        owLog("[Decider] Started SetFit server (pid \(process.processIdentifier))")
        return true
    }

    private enum Health { case loading, ready(String), failed(String) }

    private func health() async -> Health? {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("health"), timeoutInterval: 1)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if json["ready"] as? Bool == true {
            let models = (json["models"] as? [String: [String: Any]] ?? [:])
                .sorted { $0.key < $1.key }
                .map { name, meta in
                    let accuracy = (meta["accuracy"] as? Double).map { String(format: "%%%.0f", $0 * 100) } ?? "?"
                    return "\(name) \(accuracy)"
                }
                .joined(separator: ", ")
            return .ready(models)
        }
        if let error = json["error"] as? String { return .failed(error) }
        return .loading
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
