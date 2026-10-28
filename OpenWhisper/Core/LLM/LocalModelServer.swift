import Foundation

/// One of the local Python model servers (TTS voices, Qwen3-ASR, SetFit): installed by its
/// `setup.sh` into `~/Library/Application Support/OpenWhisper/<folder>`, started by the app
/// on 127.0.0.1 with `--port` and `--parent-pid` (so it quits with the app), and asked
/// `GET /health` until its model is loaded. Every server answers `/health` with `ready`,
/// `error`, `pid` and `parent_pid`.
///
/// It only runs the process and reads its health; logging and what to do about a failure
/// stay with the owner, whose log lines differ.
@MainActor
final class LocalModelServer {
    struct Config {
        let port: Int
        let directory: URL
        /// Added after `--port` and `--parent-pid`.
        var extraArguments: [String] = []
        /// A menu-bar app's child otherwise runs at background QoS (SetFit needs better).
        var qualityOfService: QualityOfService?
    }

    enum Health {
        case loading
        /// The whole `/health` answer, for servers that report more (SetFit's models).
        case ready([String: Any])
        case failed(String)
    }

    enum Outcome {
        case ready([String: Any])
        case failed(String)
        /// The process we started quit while loading.
        case exited(Int32)
        case timedOut
    }

    nonisolated let port: Int
    nonisolated let directory: URL
    private let extraArguments: [String]
    private let qualityOfService: QualityOfService?
    private var process: Process?

    nonisolated init(_ config: Config) {
        port = config.port
        directory = config.directory
        extraArguments = config.extraArguments
        qualityOfService = config.qualityOfService
    }

    nonisolated static func allPorts() -> [Int] {
        [LocalOmniVoiceProvider.port, SetFitDecider.port, QwenASRServer.port,
         LocalEMALightningProvider.port, LocalPocketTTSProvider.port, LocalPiperJarvisProvider.port,
         DamgaNormalizer.port, LocalPhononProvider.port]
    }

    nonisolated var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    nonisolated var python: URL { directory.appendingPathComponent(".venv/bin/python") }
    nonisolated var script: URL { directory.appendingPathComponent("server.py") }
    nonisolated var logPath: String { directory.appendingPathComponent("server.log").path }

    nonisolated var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && FileManager.default.fileExists(atPath: script.path)
    }

    /// The process we started is still there.
    var isRunning: Bool { process?.isRunning ?? false }
    var pid: Int32? { process?.processIdentifier }

    // MARK: - Process

    /// Starts `server.py`, its output going to `server.log`. Returns the pid.
    func start() throws -> Int32 {
        let logURL = URL(fileURLWithPath: logPath)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--port", "\(port)",
                             "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)"] + extraArguments
        process.currentDirectoryURL = directory
        if let qualityOfService { process.qualityOfService = qualityOfService }
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        // setup.sh downloaded the model; don't ask the Hub for updates on every launch.
        environment["HF_HUB_OFFLINE"] = "1"
        process.environment = environment
        if let log = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        try process.run()
        self.process = process
        return process.processIdentifier
    }

    /// Stops the server we started; returns its pid when it was still running.
    @discardableResult
    func stop() -> Int32? {
        guard let process else { return nil }
        self.process = nil
        guard process.isRunning else { return nil }
        process.terminate()
        return process.processIdentifier
    }

    /// Forgets a process that already quit, so the next `prepare` starts a new one.
    func forgetIfExited() {
        if let process, !process.isRunning { self.process = nil }
    }

    // MARK: - Health

    func healthJSON() async -> [String: Any]? {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"), timeoutInterval: 1)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// nil: nothing answers on the port.
    func health() async -> Health? {
        guard let json = await healthJSON() else { return nil }
        if json["ready"] as? Bool == true { return .ready(json) }
        if let error = json["error"] as? String { return .failed(error) }
        return .loading
    }

    /// The pid of a server on our port that this app didn't start, or nil (none, or ours).
    func strayPID() async -> pid_t? {
        guard process == nil,
              let json = await healthJSON(),
              let pid = json["pid"] as? Int, pid > 0
        else { return nil }
        let parent = json["parent_pid"] as? Int
        return parent == Int(ProcessInfo.processInfo.processIdentifier) ? nil : pid_t(pid)
    }

    /// Ends a server we didn't start (e.g. a manual test run): whoever started it may close it
    /// at any moment. Waits up to 5 s for the port to go quiet.
    func replaceStray(_ pid: pid_t) async {
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if await health() == nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Polls `/health` until the model is loaded, it fails, our process quits, or `timeout`.
    /// `onReady` may return false to keep waiting (SetFit reloading another base model).
    func waitUntilReady(timeout: TimeInterval, poll: Duration,
                        onReady: ([String: Any]) async -> Bool = { _ in true }) async -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch await health() {
            case .ready(let json):
                if await onReady(json) { return .ready(json) }
            case .failed(let error):
                return .failed(error)
            case .loading, nil:
                if let process, !process.isRunning {
                    self.process = nil
                    return .exited(process.terminationStatus)
                }
                do { try await Task.sleep(for: poll) } catch { return .timedOut }
            }
        }
        return .timedOut
    }
}
