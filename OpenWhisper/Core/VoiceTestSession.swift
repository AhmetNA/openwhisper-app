import Foundation

/// Reads and writes TODO.md for test mode and remembers what was skipped this run.
@MainActor
final class VoiceTestSession {
    nonisolated static let todoPathKey = "voiceTestTodoPath"

    private(set) var current: VoiceTestItem?
    private(set) var isActive = false
    private var passedOver: Set<String> = []
    private let todoURL: URL
    private let logURL: URL?

    init(todoURL: URL = VoiceTestSession.defaultTodoURL, logURL: URL? = VoiceTestSession.defaultLogURL) {
        self.todoURL = todoURL
        self.logURL = logURL
    }

    nonisolated static var defaultTodoURL: URL {
        if let custom = UserDefaults.standard.string(forKey: todoPathKey), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Github/Kişisel Projeler/Voice2TextLocal/TODO.md")
    }

    nonisolated static var defaultLogURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OpenWhisper/voice_test_results.log")
    }

    func start() -> VoiceTestOutcome {
        isActive = true
        passedOver = []
        return advance()
    }

    func stop() -> VoiceTestOutcome {
        isActive = false
        current = nil
        return .stopped
    }

    func skip() -> VoiceTestOutcome {
        if let current { passedOver.insert(current.line); log("atlandı", current, note: nil) }
        return advance()
    }

    func pass(now: Date = Date()) -> VoiceTestOutcome {
        guard let item = current else { return advance() }
        guard let markdown = read() else { return .todoMissing }
        guard let updated = VoiceTestTodo.removing(item, from: markdown) else { return changed(item) }
        guard write(updated) else { return .todoMissing }
        log("geçti", item, note: nil, now: now)
        return advance()
    }

    func fail(note: String?, now: Date = Date()) -> VoiceTestOutcome {
        guard let item = current else { return advance() }
        guard let markdown = read() else { return .todoMissing }
        guard let updated = VoiceTestTodo.markingFailed(item, note: note, date: now, in: markdown) else { return changed(item) }
        guard write(updated.markdown) else { return .todoMissing }
        passedOver.insert(updated.line)
        log("kaldı", item, note: note, now: now)
        return advance()
    }

    /// The item was edited or removed by someone else meanwhile; nothing is written.
    private func changed(_ item: VoiceTestItem) -> VoiceTestOutcome {
        passedOver.insert(item.line)
        current = nil
        return .itemChanged
    }

    private func advance() -> VoiceTestOutcome {
        guard let markdown = read() else { current = nil; return .todoMissing }
        let open = VoiceTestTodo.items(in: markdown).filter { !passedOver.contains($0.line) }
        guard let next = open.first else {
            isActive = false
            current = nil
            return .finished
        }
        current = next
        return .next(next, remaining: open.count)
    }

    private func read() -> String? { try? String(contentsOf: todoURL, encoding: .utf8) }

    private func write(_ markdown: String) -> Bool {
        (try? markdown.write(to: todoURL, atomically: true, encoding: .utf8)) != nil
    }

    private func log(_ result: String, _ item: VoiceTestItem, note: String?, now: Date = Date()) {
        owLog("[VoiceTest] \(result): \(item.section) — \(item.spoken)\(note.map { " (\($0))" } ?? "")")
        guard let logURL else { return }
        let stamp = ISO8601DateFormatter().string(from: now)
        let entry = "\(stamp)\t\(result)\t\(item.section)\t\(item.line)\(note.map { "\t\($0)" } ?? "")\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: logURL)
        }
    }
}
