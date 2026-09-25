import Foundation

/// The saved recording whose handling is in progress on this task. `owLog` copies every line
/// written while it is set into that recording's trace, so the Spotify parser, reminders, LLM
/// cleanup and so on need no knowledge of it. Unstructured `Task {}`s inherit it;
/// `Task.detached` and GCD/completion callbacks do not, so those capture it and re-bind it.
enum VoiceTrace {
    @TaskLocal static var current: UUID?
}

/// One text trace per saved recording: `<Recordings>/<id>.log`, next to `<id>.caf`, so every
/// kept recording can be replayed alongside what was heard, what the models answered, which
/// command ran and how it ended. `RecordingHistoryStore` deletes the trace with its audio.
///
/// Safe to call from any thread: writes go through one serial queue.
final class VoiceEventLog: @unchecked Sendable {
    static let shared = VoiceEventLog()

    let directory: URL
    private let queue = DispatchQueue(label: "com.openwhisper.voice-event-log", qos: .utility)
    /// When each trace began, for the "+ms" column. Only touched on `queue`.
    private var starts: [UUID: Date] = [:]
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("OpenWhisper/Recordings", isDirectory: true)
    }

    static func fileName(for id: UUID) -> String { "\(id.uuidString).log" }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent(Self.fileName(for: id))
    }

    /// Starts (or restarts) the trace of `id` with a header block.
    func begin(_ id: UUID, header: [String]) {
        let now = Date()
        queue.async { [self] in
            starts[id] = now
            let text = header.map { "# \($0)\n" }.joined()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? text.data(using: .utf8)?.write(to: url(for: id), options: .atomic)
        }
    }

    /// Appends one line to the trace of `id`. Ignored if the trace was never begun or has
    /// since been pruned with its recording.
    func append(_ id: UUID, _ message: String) {
        let now = Date()
        queue.async { [self] in
            let fileURL = url(for: id)
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            let offset = starts[id].map { String(format: " +%5dms", Int(now.timeIntervalSince($0) * 1000)) } ?? ""
            let line = "[\(clock.string(from: now))\(offset)] \(message)\n"
            _ = try? handle.seekToEnd()
            if let data = line.data(using: .utf8) { try? handle.write(contentsOf: data) }
        }
    }

    /// Appends to the trace of the recording bound to the current task, if any.
    func appendToCurrent(_ message: String) {
        guard let id = VoiceTrace.current else { return }
        append(id, message)
    }

    func read(_ id: UUID) -> String? {
        queue.sync { try? String(contentsOf: url(for: id), encoding: .utf8) }
    }

    /// Waits for every queued write. Tests only.
    func flush() {
        queue.sync {}
    }
}
