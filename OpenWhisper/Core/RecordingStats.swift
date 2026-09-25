import Foundation

/// What a saved recording contained: how long it ran, how much of it was speech, how loud.
/// Speech is found by energy against the recording's own noise floor (no model), in 30 ms frames.
struct RecordingStats: Codable, Equatable, Sendable {
    var totalSeconds: Double
    /// Sum of the speech parts, short in-sentence pauses included.
    var speechSeconds: Double
    var speechParts: Int
    var longestPauseSeconds: Double
    var peakDBFS: Double
    var speechLevelDBFS: Double?
    var noiseFloorDBFS: Double
    var clippedPercent: Double
    var wordCount: Int?
    var whisperSegments: Int?

    var speechPercent: Double { totalSeconds > 0 ? speechSeconds / totalSeconds * 100 : 0 }
    var silenceSeconds: Double { max(0, totalSeconds - speechSeconds) }
    var wordsPerMinute: Double? {
        guard let wordCount, speechSeconds >= 1 else { return nil }
        return Double(wordCount) / speechSeconds * 60
    }

    /// One `key: value` per line, for the recording's trace header.
    var logLines: [String] {
        var lines = [
            String(format: "Total: %.1f s", totalSeconds),
            String(format: "Speech: %.1f s (%.0f%%), silence %.1f s", speechSeconds, speechPercent, silenceSeconds),
            String(format: "Speech parts: %d, longest pause %.1f s", speechParts, longestPauseSeconds),
            String(format: "Level: peak %.1f dBFS, speech %@, noise floor %.1f dBFS, clipped %.2f%%",
                   peakDBFS, speechLevelDBFS.map { String(format: "%.1f dBFS", $0) } ?? "-", noiseFloorDBFS, clippedPercent),
        ]
        if let wordCount {
            let rate = wordsPerMinute.map { String(format: ", %.0f words/min", $0) } ?? ""
            lines.append("Words: \(wordCount)\(rate)")
        }
        if let whisperSegments { lines.append("Whisper segments: \(whisperSegments)") }
        return lines
    }

    /// Single line for /tmp/openwhisper.log.
    var summary: String { logLines.joined(separator: " | ") }

    /// Short Turkish line for the Recordings list.
    var label: String {
        var parts = [String(format: "Konuşma %.0f/%.0f sn", speechSeconds, totalSeconds), "\(speechParts) parça"]
        if let wordCount { parts.append("\(wordCount) kelime") }
        return parts.joined(separator: " · ")
    }

    static func wordCount(in text: String?) -> Int? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("[BLANK"), !trimmed.hasPrefix("(BLANK") else { return 0 }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }.count
    }
}

/// Fed the recording in pieces as it is written; `finish` computes `RecordingStats`.
struct RecordingStatsAccumulator: Sendable {
    static let sampleRate = 16_000
    static let frameSamples = 480 // 30 ms
    /// Voice frames closer than this merge into one part (breaths, short word gaps).
    static let mergeGapFrames = 10 // 300 ms
    /// Parts shorter than this are clicks or bumps, not speech.
    static let minimumPartFrames = 5 // 150 ms
    /// Speech must stand this far above the recording's noise floor…
    static let speechMarginDB = 12.0
    /// …and never below this absolute level (digital silence would make the margin meaningless).
    static let absoluteFloorDB = -65.0

    private(set) var sampleCount = 0
    private var peak: Float = 0
    private var clipped = 0
    private var frameDB: [Double] = []
    private var framePower: [Double] = []
    private var pending: [Float] = []

    mutating func add<S: Collection>(_ samples: S) where S.Element == Float {
        sampleCount += samples.count
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            if a >= 0.999 { clipped += 1 }
        }
        pending.append(contentsOf: samples)
        var start = 0
        while start + Self.frameSamples <= pending.count {
            var sum: Double = 0
            for i in start..<start + Self.frameSamples { sum += Double(pending[i]) * Double(pending[i]) }
            let power = sum / Double(Self.frameSamples)
            framePower.append(power)
            frameDB.append(10 * log10(max(power, 1e-12)))
            start += Self.frameSamples
        }
        pending.removeFirst(start)
    }

    func finish(transcript: String? = nil, whisperSegments: Int? = nil) -> RecordingStats {
        let seconds = Double(Self.frameSamples) / Double(Self.sampleRate)
        let sorted = frameDB.sorted()
        let floor = sorted.isEmpty ? -120 : sorted[sorted.count / 10]
        let threshold = max(floor + Self.speechMarginDB, Self.absoluteFloorDB)

        // Voiced frames → runs, merged across short gaps, tiny ones dropped.
        var runs: [(start: Int, end: Int)] = []
        for (i, db) in frameDB.enumerated() where db >= threshold {
            if let last = runs.last, i - last.end <= Self.mergeGapFrames {
                runs[runs.count - 1].end = i + 1
            } else {
                runs.append((i, i + 1))
            }
        }
        runs.removeAll { $0.end - $0.start < Self.minimumPartFrames }

        let speechFrames = runs.reduce(0) { $0 + $1.end - $1.start }
        let longestGap = zip(runs, runs.dropFirst()).map { $1.start - $0.end }.max() ?? 0
        let voicedPower = runs.flatMap { framePower[$0.start..<$0.end] }.filter { 10 * log10(max($0, 1e-12)) >= threshold }
        let speechLevel = voicedPower.isEmpty ? nil : 10 * log10(voicedPower.reduce(0, +) / Double(voicedPower.count))

        return RecordingStats(
            totalSeconds: Double(sampleCount) / Double(Self.sampleRate),
            speechSeconds: Double(speechFrames) * seconds,
            speechParts: runs.count,
            longestPauseSeconds: Double(longestGap) * seconds,
            peakDBFS: 20 * log10(max(Double(peak), 1e-6)),
            speechLevelDBFS: speechLevel,
            noiseFloorDBFS: floor,
            clippedPercent: sampleCount > 0 ? Double(clipped) / Double(sampleCount) * 100 : 0,
            wordCount: RecordingStats.wordCount(in: transcript),
            whisperSegments: whisperSegments
        )
    }
}

/// How a recording was started. A Fn hold that Space locks into hands-free counts as `fnSpace`.
enum RecordingTrigger: String, Codable, Sendable {
    case wakeWord
    case fnHold
    case fnSpace
    case keyboardShortcut
    case external

    var title: String {
        switch self {
        case .wakeWord: "Sesle (Hey Jarvis)"
        case .fnHold: "Fn basılı tutularak"
        case .fnSpace: "Fn + Space"
        case .keyboardShortcut: "⌘⌥⌃D"
        case .external: "Kısayol / URL"
        }
    }
}
