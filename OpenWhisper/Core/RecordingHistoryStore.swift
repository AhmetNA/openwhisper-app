import AVFoundation
import Foundation

struct SavedRecording: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let sampleCount: Int
    /// A short transcript excerpt for the menu. Older index entries decode as nil.
    let previewText: String?

    var duration: TimeInterval { Double(sampleCount) / 16_000 }

    var durationLabel: String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var previewLabel: String {
        guard let previewText else { return "Önizleme hazırlanıyor…" }
        return previewText.isEmpty ? "Metin çıkarılamadı" : previewText
    }

    var menuLabel: String {
        let maxCharacters = 38
        let text = previewLabel
        guard text.count > maxCharacters else { return "\(durationLabel) · \(text)" }
        let prefix = String(text.prefix(maxCharacters))
        let end = prefix.lastIndex(of: " ") ?? prefix.endIndex
        return "\(durationLabel) · \(prefix[..<end])…"
    }
}

/// Stores only completed dictations. Audio stays on this Mac under Application Support.
actor RecordingHistoryStore {
    static let limit = 7
    private let directory: URL
    private var recordings: [SavedRecording]
    private var active: [UInt64: (file: AVAudioFile, url: URL, id: UUID, date: Date, samples: Int)] = [:]

    init(directory: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storageDirectory = directory ?? support.appendingPathComponent("OpenWhisper/Recordings", isDirectory: true)
        self.directory = storageDirectory
        let indexURL = storageDirectory.appendingPathComponent("index.json")
        let decoded = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([SavedRecording].self, from: $0) } ?? []
        self.recordings = decoded
            .filter { FileManager.default.fileExists(atPath: storageDirectory.appendingPathComponent("\($0.id.uuidString).caf").path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func items() -> [SavedRecording] { recordings }

    func append(_ segment: CompletedAudioSegment, sessionID: UInt64, startedAt: Date) throws {
        let samples = segment.samples.dropFirst(segment.overlapSampleCount)
        guard !samples.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if active[sessionID] == nil {
            let id = UUID()
            let url = directory.appendingPathComponent("\(id.uuidString).partial.caf")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            active[sessionID] = (file, url, id, startedAt, 0)
        }
        guard var entry = active[sessionID],
              let buffer = AVAudioPCMBuffer(pcmFormat: entry.file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        try entry.file.write(from: buffer)
        entry.samples += samples.count
        active[sessionID] = entry
    }

    func finish(sessionID: UInt64, keep: Bool, previewText: String? = nil) throws -> [SavedRecording] {
        guard let metadata = ({ () -> (URL, UUID, Date, Int)? in
            guard let entry = active.removeValue(forKey: sessionID) else { return nil }
            return (entry.url, entry.id, entry.date, entry.samples)
        })() else { return recordings }
        // AVAudioFile is released before the partial file is moved.
        let (partialURL, id, date, count) = metadata
        if !keep || count < 6_400 {
            try? FileManager.default.removeItem(at: partialURL)
            return recordings
        }
        let finalURL = directory.appendingPathComponent("\(id.uuidString).caf")
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        let updated = ([SavedRecording(id: id, createdAt: date, sampleCount: count, previewText: Self.normalizedPreview(previewText))] + recordings)
            .sorted { $0.createdAt > $1.createdAt }
        let retained = Array(updated.prefix(Self.limit))
        do {
            let data = try JSONEncoder().encode(retained)
            try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: finalURL)
            throw error
        }
        recordings = retained
        for old in updated.dropFirst(Self.limit) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(old.id.uuidString).caf"))
        }
        return recordings
    }

    func updatePreview(id: UUID, text: String) throws -> [SavedRecording] {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return recordings }
        var updated = recordings
        let old = updated[index]
        updated[index] = SavedRecording(
            id: old.id,
            createdAt: old.createdAt,
            sampleCount: old.sampleCount,
            previewText: Self.normalizedPreview(text)
        )
        let data = try JSONEncoder().encode(updated)
        try data.write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        recordings = updated
        return recordings
    }

    private static func normalizedPreview(_ text: String?) -> String? {
        text.map { String($0.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240)) }
    }

    func segment(id: UUID, startingAt frame: Int64) throws -> (CompletedAudioSegment, Int64)? {
        guard recordings.contains(where: { $0.id == id }) else { return nil }
        let url = directory.appendingPathComponent("\(id.uuidString).caf")
        let file = try AVAudioFile(forReading: url)
        guard frame < file.length else { return nil }
        let overlap = frame == 0 ? 0 : min(Int64(16_000), frame)
        file.framePosition = frame - overlap
        let capacity = AVAudioFrameCount(min(Int64(180 * 16_000) + overlap, file.length - file.framePosition))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { return nil }
        try file.read(into: buffer)
        // AVAudioFile can return only the requested overlap at EOF even while its
        // reported length is larger. Never return a segment that cannot advance replay.
        guard let channel = buffer.floatChannelData?[0], Int64(buffer.frameLength) > overlap else { return nil }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let nextFrame = frame + Int64(buffer.frameLength) - overlap
        return (CompletedAudioSegment(samples: samples, overlapSampleCount: Int(overlap)), nextFrame)
    }
}
