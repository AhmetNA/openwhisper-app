import Foundation

/// Every "Jarvis" trigger's clip plus what each check said about it, so speaker-check changes
/// can be measured on the same real audio (step 1 of WAKE-SPEAKER-PLANI.md).
///
/// Files, under Application Support/OpenWhisper/WakeClips: `<id>.wav` (16 kHz Int16 mono) and
/// `wake_clips.jsonl`, one line per trigger once it is decided. Labels are added offline by
/// `tools/wake_clips.py` into `labels.json`, so the log itself stays append-only.
/// Off: `defaults write com.openwhisper.app wakeClipLoggingEnabled -bool false`
@MainActor
final class WakeClipLog {
    struct Record: Codable {
        let id: String
        let createdAt: Date
        /// "direct" (score ≥ threshold) or "candidate" (grey zone, verified before recording).
        let kind: String
        let wakeScore: Float
        var speakerScore: Float?
        var speakerThreshold: Float?
        /// Whisper/LLM word check: "accepted: …" or "rejected: …"; nil when it did not run.
        var wordCheck: String?
        /// In-session own-voice scores (`OwnVoiceStopGate`, every 0.5 s).
        var ownVoiceScores: [Float] = []
        /// Target-speaker filter decision per batch.
        var filterDecisions: [String] = []
        /// "transcribed", "discarded", "candidate rejected" or "not started".
        var outcome: String?
        var transcript: String?
    }

    static let shared = WakeClipLog()
    nonisolated static let maxClips = 1000

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "wakeClipLoggingEnabled") as? Bool ?? true
    }

    let directory: URL
    private var open: [UUID: Record] = [:]
    /// Disk writes stay off the main thread.
    private let io = DispatchQueue(label: "com.openwhisper.wakecliplog", qos: .utility)
    private var finishedSincePrune = 0

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = directory ?? support.appendingPathComponent("OpenWhisper/WakeClips", isDirectory: true)
    }

    /// Starts a record and writes its audio (-1…1 at 16 kHz); nil when logging is off.
    func begin(audio: [Float], wakeScore: Float, kind: String) -> UUID? {
        guard Self.isEnabled else { return nil }
        let id = UUID()
        open[id] = Record(id: id.uuidString, createdAt: Date(), kind: kind, wakeScore: wakeScore)
        let url = directory.appendingPathComponent("\(id.uuidString).wav")
        let directory = directory
        io.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Self.wav(audio).write(to: url)
            } catch {
                owLog("[WakeClipLog] Clip write failed: \(error)")
            }
        }
        return id
    }

    /// Changes an open record; a record already finished (or nil id) is left alone.
    func update(_ id: UUID?, _ change: (inout Record) -> Void) {
        guard let id, var record = open[id] else { return }
        change(&record)
        open[id] = record
    }

    /// Appends the record to `wake_clips.jsonl` and closes it.
    func finish(_ id: UUID?, outcome: String, transcript: String? = nil) {
        guard let id, var record = open.removeValue(forKey: id) else { return }
        record.outcome = outcome
        if let transcript, !transcript.isEmpty { record.transcript = transcript }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        let url = directory.appendingPathComponent("wake_clips.jsonl")
        let directory = directory
        finishedSincePrune += 1
        let prune = finishedSincePrune >= 50
        if prune { finishedSincePrune = 0 }
        io.async {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                owLog("[WakeClipLog] Record write failed: \(error)")
            }
            if prune { Self.pruneClips(in: directory) }
        }
    }

    /// Deletes the oldest clips beyond `maxClips`; their jsonl lines stay (the tool skips them).
    nonisolated private static func pruneClips(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]
        ))?.filter { $0.pathExtension == "wav" } ?? []
        guard files.count > maxClips else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - maxClips) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func wav(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data()
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * Float(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
