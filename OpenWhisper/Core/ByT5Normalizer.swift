import Foundation

/// Persistent bridge to the CPU-only ByT5 Turkish normalizer. The Python worker stays alive so
/// model loading is paid once per app session instead of once per dictation.
actor ByT5Normalizer {
    static let shared = ByT5Normalizer()

    enum NormalizerError: LocalizedError {
        case runtimeUnavailable
        case workerStopped(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .runtimeUnavailable:
                return "ByT5 çalışma ortamı bulunamadı. scripts/setup_byt5.sh dosyasını çalıştırın."
            case .workerStopped(let message):
                return "ByT5 işlemi durdu: \(message)"
            case .invalidResponse:
                return "ByT5 geçerli bir sonuç döndürmedi."
            }
        }
    }

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputBuffer = Data()
    private var pending: [String: CheckedContinuation<String, Error>] = [:]

    static func checkAvailability() async -> Bool {
        guard let runtime = resolveRuntime() else { return false }
        let process = Process()
        let output = Pipe()
        process.executableURL = runtime.python
        process.arguments = [runtime.script.path, "--check"]
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func normalize(_ text: String) async throws -> String {
        try startIfNeeded()
        guard let inputHandle else { throw NormalizerError.runtimeUnavailable }

        let id = UUID().uuidString
        let request: [String: String] = ["id": id, "text": text]
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try inputHandle.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
                stopWorker(reason: error.localizedDescription)
            }
        }
    }

    private struct Runtime {
        let python: URL
        let script: URL
    }

    private static func resolveRuntime() -> Runtime? {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let installedPython = appSupport.appendingPathComponent("OpenWhisper/ByT5/.venv/bin/python")
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourcePython = sourceRoot.appendingPathComponent(".venv/bin/python")
        let pythonCandidates = [installedPython, sourcePython]

        let scriptCandidates: [URL] = [
            Bundle.module.url(forResource: "byt5_normalizer", withExtension: "py"),
            Bundle.main.url(forResource: "byt5_normalizer", withExtension: "py"),
            sourceRoot.appendingPathComponent("OpenWhisper/Resources/byt5_normalizer.py")
        ].compactMap { $0 }

        guard let python = pythonCandidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }),
              let script = scriptCandidates.first(where: { fileManager.isReadableFile(atPath: $0.path) })
        else { return nil }
        // Do not resolve the venv's `python` symlink: Python uses the invoked path to discover
        // pyvenv.cfg and site-packages. Launching its resolved base interpreter silently drops
        // the isolated environment and makes installed modules appear missing.
        return Runtime(python: python.standardizedFileURL, script: script.resolvingSymlinksInPath())
    }

    private func startIfNeeded() throws {
        if let process, process.isRunning { return }
        guard let runtime = Self.resolveRuntime() else { throw NormalizerError.runtimeUnavailable }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = runtime.python
        process.arguments = [runtime.script.path, "--serve"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let message = String(data: data, encoding: .utf8) {
                owLog("[ByT5] \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        process.terminationHandler = { [weak self] process in
            Task { await self?.stopWorker(reason: "exit \(process.terminationStatus)") }
        }

        try process.run()
        self.process = process
        inputHandle = input.fileHandleForWriting
        owLog("[ByT5] CPU worker started")
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let id = object["id"] as? String,
                  let continuation = pending.removeValue(forKey: id)
            else { continue }

            if let text = object["text"] as? String {
                continuation.resume(returning: text)
            } else {
                let message = object["error"] as? String ?? "unknown response"
                continuation.resume(throwing: NormalizerError.workerStopped(message))
            }
        }
    }

    private func stopWorker(reason: String) {
        process = nil
        inputHandle = nil
        outputBuffer.removeAll(keepingCapacity: true)
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: NormalizerError.workerStopped(reason))
        }
    }
}
