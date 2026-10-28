import Foundation

/// "Bu makaleyi oku": reads a page aloud sentence by sentence. Any new recording cuts Jarvis
/// short; the sentence that was playing is remembered, so "devam et" goes on from it for a
/// few minutes afterwards.
@MainActor
final class ArticleReader {
    static let shared = ArticleReader()

    private var sentences: [String] = []
    /// The sentence to read next: the one that was playing when the reading was cut.
    private var next = 0
    private var reading = false
    private var stoppedAt: Date?
    private static let resumeWindow: TimeInterval = 10 * 60
    private static let maxCharacters = 40000
    /// Each clip stops after 20 s at most (`JarvisVoice.play`); a long sentence is split first.
    nonisolated private static let maxSentence = 220

    /// Cut short a moment ago with more left to read.
    var isPaused: Bool { pausedFor(Self.resumeWindow) }
    /// Cut by the recording now being routed: its "dur" is about the reading.
    var wasJustCut: Bool { pausedFor(30) }

    private func pausedFor(_ seconds: TimeInterval) -> Bool {
        guard !reading, next < sentences.count, let stoppedAt else { return false }
        return Date().timeIntervalSince(stoppedAt) < seconds
    }

    /// Music or a video started after the reading: "devam et" is theirs again.
    func forget() {
        guard !reading else { return }
        stoppedAt = nil
    }

    /// Reads the front page; nil when there is nothing to read.
    func load() -> String? {
        guard let page = BrowserController.articleText() else { return nil }
        let parts = Self.sentences(in: String(page.text.prefix(Self.maxCharacters)))
        guard parts.count >= 2 || (parts.first?.count ?? 0) >= 80 else { return nil }
        sentences = parts
        next = 0
        stoppedAt = nil
        owLog("[Reader] Loaded '\(page.title)' (\(parts.count) sentences)")
        return page.title
    }

    /// Reads from `next` to the end, or until the voice is stopped. Not awaited by the command:
    /// a long page reads for minutes.
    func start(onSpeaking: @escaping (Bool) -> Void = { _ in }) {
        guard !reading, next < sentences.count else { return }
        reading = true
        let remaining = Array(sentences[next...])
        let offset = next
        Task { @MainActor in
            let (stream, continuation) = AsyncStream<String>.makeStream()
            remaining.forEach { continuation.yield($0) }
            continuation.finish()
            var last = offset - 1
            await JarvisVoice.shared.speak(sentences: stream, onStart: { onSpeaking(true) }, onSentence: { last = offset + $0 })
            onSpeaking(false)
            reading = false
            if last >= sentences.count - 1 {
                owLog("[Reader] Finished")
                sentences = []
                next = 0
            } else {
                next = max(last, offset)
                stoppedAt = Date()
                owLog("[Reader] Stopped at sentence \(next + 1) of \(sentences.count)")
            }
        }
    }

    /// "Dur": the recording that heard it already cut the voice; the place stays for "devam et".
    func stop() {
        JarvisVoice.shared.stop()
    }

    /// Sentences of at most `maxSentence` characters: long ones are split at a comma or a space.
    nonisolated static func sentences(in text: String) -> [String] {
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var sentence = ""
            for char in line {
                sentence.append(char)
                if ".!?…".contains(char) {
                    result.append(contentsOf: split(sentence))
                    sentence = ""
                }
            }
            result.append(contentsOf: split(sentence))
        }
        return result
    }

    private nonisolated static func split(_ sentence: String) -> [String] {
        var rest = sentence.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        while rest.count > maxSentence {
            let head = rest.prefix(maxSentence)
            let cut = head.lastIndex(where: { ",;:".contains($0) }) ?? head.lastIndex(of: " ") ?? head.endIndex
            let end = cut == head.endIndex ? cut : rest.index(after: cut)
            parts.append(rest[..<end].trimmingCharacters(in: .whitespaces))
            rest = rest[end...].trimmingCharacters(in: .whitespaces)
        }
        if rest.contains(where: \.isLetter) { parts.append(rest) }
        return parts.filter { !$0.isEmpty }
    }
}
