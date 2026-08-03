import Foundation
import AppKit
import os

/// Thread-safe atomic container for state variables.
private final class BridgeState: @unchecked Sendable {
    private var lock = os_unfair_lock()
    var process: Process?
    var stdinPipe: Pipe?
    var stdoutPipe: Pipe?
    var stderrPipe: Pipe?
    var requestID: Int = 0
    var pendingContinuations: [Int: CheckedContinuation<String, Never>] = [:]
    /// Persistent byte buffer for stdout: a single `availableData` chunk from the
    /// readability handler can split a JSON-RPC line mid-way (or merge two lines into
    /// one), and can also split a multi-byte UTF-8 sequence. Buffering as `Data` and
    /// only decoding/parsing complete `\n`-terminated segments avoids both failure modes.
    var stdoutBuffer = Data()

    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return body()
    }
}

/// Swift Client Bridge for the Spotify Smart Dual-Mode MCP Server (`spotify_smart_mcp.py`).
/// Manages the background Python subprocess via standard I/O pipes (stdio) and exchanges
/// JSON-RPC 2.0 requests to control Spotify locally (AppleScript) or online (Web API).
final class LocalMCPBridge: @unchecked Sendable {

    static let shared = LocalMCPBridge()
    private let state = BridgeState()
    private let idleTimeout: TimeInterval = 120
    private var idleShutdownGeneration = 0

    private init() {}

    private func cancelIdleShutdown() {
        state.withLock { idleShutdownGeneration += 1 }
    }

    private func scheduleIdleShutdown() {
        let generation = state.withLock { () -> Int in
            idleShutdownGeneration += 1
            return idleShutdownGeneration
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleTimeout) { [weak self] in
            self?.shutdownIfIdle(generation: generation)
        }
    }

    private func shutdownIfIdle(generation: Int) {
        let processToTerminate = state.withLock { () -> Process? in
            guard generation == idleShutdownGeneration,
                  state.pendingContinuations.isEmpty,
                  let process = state.process,
                  process.isRunning else { return nil }
            state.process = nil
            state.stdinPipe?.fileHandleForWriting.closeFile()
            state.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            state.stderrPipe?.fileHandleForReading.readabilityHandler = nil
            state.stdinPipe = nil
            state.stdoutPipe = nil
            state.stderrPipe = nil
            state.stdoutBuffer.removeAll()
            return process
        }
        guard let processToTerminate else { return }
        owLog("[MCPBridge] Stopping idle Spotify MCP Server after \(Int(idleTimeout))s.")
        processToTerminate.terminate()
    }

    /// Locates and launches `spotify_smart_mcp.py` as a background process.
    private func startServerIfNeeded() {
        let (isRunning, hadDeadProcess) = state.withLock { () -> (Bool, Bool) in
            if let proc = state.process {
                if proc.isRunning { return (true, false) }
                // The process exists but has died (e.g. crashed, or was killed).
                // Clear all stale state so we don't write to dead pipes and so any
                // requests that were still waiting on this process fail immediately
                // instead of hanging until the 3s timeout.
                return (false, true)
            }
            return (false, false)
        }

        guard !isRunning else { return }

        if hadDeadProcess {
            owLog("[MCPBridge] Previous MCP process is no longer running — resetting state and restarting.")
            failAllPendingContinuations(with: "MCP sunucusu beklenmedik şekilde kapandı, yeniden başlatılıyor.")
            state.withLock {
                state.process = nil
                state.stdinPipe = nil
                state.stdoutPipe = nil
                state.stderrPipe = nil
                state.stdoutBuffer.removeAll()
            }
        }

        let fm = FileManager.default
        let mainBundlePath = Bundle.main.bundlePath
        let possiblePaths: [String] = [
            Bundle.main.path(forResource: "spotify_smart_mcp", ofType: "py")
        ].compactMap { $0 } + [
            // Installed app bundles keep loose resources under Contents/Resources.
            // Keep this explicit fallback because Bundle.main resource lookup can
            // differ between `swift run` and the packaged .app.
            URL(fileURLWithPath: mainBundlePath)
                .appendingPathComponent("Contents/Resources/spotify_smart_mcp.py").path,
            (mainBundlePath as NSString).deletingLastPathComponent + "/scripts/spotify_smart_mcp.py"
        ]

        var scriptPath: String?
        for path in possiblePaths {
            if fm.fileExists(atPath: path) {
                scriptPath = path
                break
            }
        }

        guard let validScriptPath = scriptPath else {
            owLog("[MCPBridge] Could not find spotify_smart_mcp.py script path. Searched: \(possiblePaths.compactMap { $0 }.joined(separator: ", "))")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [validScriptPath]

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Set stdout readability handler to continuously parse JSON-RPC lines. A single
        // `availableData` chunk can split a line mid-way (or merge several lines into one
        // read), and can even split a multi-byte UTF-8 sequence — so we accumulate into a
        // persistent `Data` buffer and only decode+parse complete `\n`-terminated segments,
        // leaving any trailing partial line in the buffer for the next chunk.
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendStdoutAndDrainLines(data)
        }

        // Capture stderr so a Python-side crash (import error, traceback, etc.) leaves a
        // trace in the log instead of the silent "MCP does nothing" symptom this was
        // originally reported as.
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            owLog("[MCPBridge][stderr] \(text)")
        }

        // If the Python process dies (crash, killed, etc.) after having started
        // successfully, make sure we notice: log it, fail any requests still waiting on
        // it instead of leaving them to the 3s timeout, and reset state so the next call
        // to `startServerIfNeeded()` actually restarts it instead of thinking a dead
        // `Process` reference is still good.
        proc.terminationHandler = { [weak self] terminatedProc in
            owLog("[MCPBridge] MCP process exited (status: \(terminatedProc.terminationStatus), reason: \(terminatedProc.terminationReason.rawValue)).")
            guard let self else { return }
            self.failAllPendingContinuations(with: "MCP sunucusu beklenmedik şekilde kapandı (exit \(terminatedProc.terminationStatus)).")
            self.state.withLock {
                if self.state.process === terminatedProc {
                    self.state.process = nil
                    self.state.stdinPipe = nil
                    self.state.stdoutPipe = nil
                    self.state.stderrPipe = nil
                    self.state.stdoutBuffer.removeAll()
                }
            }
        }

        do {
            try proc.run()
            state.withLock {
                state.process = proc
                state.stdinPipe = inPipe
                state.stdoutPipe = outPipe
                state.stderrPipe = errPipe
            }

            owLog("[MCPBridge] Started Spotify MCP Server process at: \(validScriptPath)")
            sendRawRequest(method: "initialize", params: [:])
        } catch {
            owLog("[MCPBridge] Failed to start MCP process: \(error)")
        }
    }

    /// Appends a raw stdout chunk to the persistent buffer and parses out every complete
    /// `\n`-terminated line currently available, leaving any trailing partial line buffered.
    private func appendStdoutAndDrainLines(_ data: Data) {
        var linesToHandle: [String] = []
        state.withLock {
            state.stdoutBuffer.append(data)
            while let newlineIndex = state.stdoutBuffer.firstIndex(of: 0x0A) { // "\n"
                let lineData = state.stdoutBuffer[state.stdoutBuffer.startIndex..<newlineIndex]
                state.stdoutBuffer.removeSubrange(state.stdoutBuffer.startIndex...newlineIndex)
                if let text = String(data: lineData, encoding: .utf8) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { linesToHandle.append(trimmed) }
                }
            }
        }
        for line in linesToHandle {
            handleIncomingJSONRPCLine(line)
        }
    }

    /// Completes every currently pending continuation with a text error instead of letting
    /// them hang until `executeTool`'s 3s timeout — used when the underlying process is
    /// known to be gone (dead-process detection at start, or `terminationHandler` firing).
    private func failAllPendingContinuations(with message: String) {
        let continuations = state.withLock { () -> [CheckedContinuation<String, Never>] in
            let values = Array(state.pendingContinuations.values)
            state.pendingContinuations.removeAll()
            return values
        }
        for continuation in continuations {
            continuation.resume(returning: message)
        }
    }

    private func handleIncomingJSONRPCLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else { return }

        let targetContinuation = state.withLock {
            state.pendingContinuations.removeValue(forKey: id)
        }

        guard let continuation = targetContinuation else { return }

        if let resultDict = json["result"] as? [String: Any],
           let contentArr = resultDict["content"] as? [[String: Any]],
           let firstContent = contentArr.first,
           let text = firstContent["text"] as? String {
            continuation.resume(returning: text)
        } else if let errorDict = json["error"] as? [String: Any],
                  let message = errorDict["message"] as? String {
            continuation.resume(returning: "MCP Error: \(message)")
        } else {
            continuation.resume(returning: line)
        }
    }

    /// Sends a JSON-RPC request to the MCP server with a 3-second timeout.
    private func executeTool(name: String, arguments: [String: Any] = [:]) async -> String {
        cancelIdleShutdown()
        startServerIfNeeded()

        let (currentStdin, currentID) = state.withLock { () -> (FileHandle?, Int) in
            state.requestID += 1
            return (state.stdinPipe?.fileHandleForWriting, state.requestID)
        }

        guard let stdin = currentStdin else {
            return "MCP Server process not connected."
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": currentID,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments
            ]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              var jsonString = String(data: data, encoding: .utf8) else {
            return "Failed to serialize MCP request."
        }

        jsonString += "\n"

        let result = await withTaskGroup(of: String.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    self.state.withLock {
                        self.state.pendingContinuations[currentID] = continuation
                    }

                    if let writeData = jsonString.data(using: .utf8) {
                        stdin.write(writeData)
                    } else {
                        self.state.withLock {
                            _ = self.state.pendingContinuations.removeValue(forKey: currentID)
                        }
                        continuation.resume(returning: "Encoding error.")
                    }
                }
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return "__MCP_TIMEOUT__"
            }

            if let firstResult = await group.next() {
                if firstResult == "__MCP_TIMEOUT__" {
                    self.state.withLock {
                        _ = self.state.pendingContinuations.removeValue(forKey: currentID)
                    }
                    group.cancelAll()
                    return "MCP isteği zaman aşımına uğradı (3 sn)."
                } else {
                    group.cancelAll()
                    return firstResult
                }
            }
            return "MCP işlemi tamamlandı."
        }
        scheduleIdleShutdown()
        return result
    }

    private func sendRawRequest(method: String, params: [String: Any]) {
        let (currentStdin, currentID) = state.withLock { () -> (FileHandle?, Int) in
            state.requestID += 1
            return (state.stdinPipe?.fileHandleForWriting, state.requestID)
        }

        guard let stdin = currentStdin else { return }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": currentID,
            "method": method,
            "params": params
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           var str = String(data: data, encoding: .utf8) {
            str += "\n"
            stdin.write(Data(str.utf8))
        }
    }

    // MARK: - Swift Public API

    func playPause() async -> String {
        await executeTool(name: "spotify_play_pause")
    }

    func nextTrack() async -> String {
        await executeTool(name: "spotify_next_track")
    }

    func previousTrack() async -> String {
        await executeTool(name: "spotify_previous_track")
    }

    func setVolume(_ vol: Int) async -> String {
        await executeTool(name: "spotify_set_volume", arguments: ["volume": vol])
    }

    func getCurrentTrack() async -> String {
        await executeTool(name: "spotify_get_current_track")
    }

    func searchAndPlay(query: String) async -> String {
        await executeTool(name: "spotify_search_and_play", arguments: ["query": query])
    }

    func likeCurrentTrack() async -> String {
        await executeTool(name: "spotify_like_current_track")
    }
}
