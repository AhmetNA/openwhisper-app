import XCTest
@testable import OpenWhisper

/// Every real transcript in `Fixtures/route_corpus.tsv` (built from the app's logs by
/// `tools/route_corpus.py`) goes through the deterministic routing rules in the same order
/// as `AppState.finishTranscription`, and the result must match `route_corpus_snapshot.tsv`.
/// Ollama, SetFit and keyboard focus are left out: a row the rules don't claim ends as
/// `none` (those models decide it in the app).
///
/// A diff is not necessarily a bug, it is a behaviour change: check each listed row, then
/// accept the new behaviour with
///     UPDATE_ROUTE_SNAPSHOT=1 swift test --filter RouteCorpusTests
@MainActor
final class RouteCorpusTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    private static let corpusURL = fixtures.appendingPathComponent("route_corpus.tsv")
    private static let snapshotURL = fixtures.appendingPathComponent("route_corpus_snapshot.tsv")

    /// A fixed app list so the result doesn't depend on what this Mac has installed.
    private static let installedApps = [
        "Safari", "Spotify", "Claude", "ChatGPT", "Codex", "Slack", "Google Chrome", "Mail",
        "Notes", "Calendar", "Terminal", "WhatsApp", "Finder", "Music", "System Settings"
    ]

    private struct Row { let mode, logged, text: String }

    /// Mirrors the rule part of `AppState.finishTranscription`; keep the order in sync.
    static func ruleRoute(_ text: String, voice: Bool) -> String {
        if let agent = AgentCommandParser.parse(text) {
            if let target = agent.target { return "agent:\(target.rawValue)" }
            if agent.send { return agent.body.isEmpty ? "agent-send:empty" : "agent-send" }
        }
        // Fn, Fn+Space and the recording shortcut accept commands too, so no voice check here.
        if JarvisAddressee.leadingTypeCommand(text) != nil || JarvisAddressee.trailingTypeCommand(text) != nil {
            return "typed"
        }
        if voice, JarvisAddressee.explicitChatCommand(text) != nil { return "chat" }
        if voice, let meta = JarvisReply.meta(in: text) { return "meta:\(meta)" }
        if voice, let memory = UserMemoryCommand.parse(text) { return "memory:\(memory)" }
        if voice, let query = TimeQuery.parse(text) { return "memory-time:\(query.label)" }
        if voice, let greeting = JarvisReply.greeting(in: text) { return "greeting:\(greeting) (unless a text field has focus)" }

        // No timer is running or ringing in the corpus, so state-dependent forms stay out.
        if let timer = TimerCommandParser.parse(text) {
            if case .alarm = timer { return "timer:alarm" }  // the date depends on today
            return "timer:\(timer)"
        }

        func system(_ candidate: String) -> SystemCommand? {
            SystemCommandParser.parse(candidate, installedApps: installedApps, shortcuts: [])
        }
        let firstSentence = voice ? AppState.leadingSentence(of: text) : nil
        if let command = system(text) ?? firstSentence.flatMap(system).flatMap({ $0 == .developerMode ? nil : $0 }) {
            return "system:\(command)"
        }
        if ReminderManager.deletionRequest(text) != nil { return "reminder-deletion" }
        if ReminderManager.isReminder(text) { return "reminder" }
        if let intent = SpotifyManager.explicitIntent(in: text) { return "spotify:\(Self.describe(intent))" }
        if let firstSentence, let intent = SpotifyManager.explicitIntent(in: firstSentence) {
            return "spotify:\(Self.describe(intent)) (first sentence)"
        }
        return "none"
    }

    /// Search requests carry a lot of fields; the query text is what routing changes affect.
    private static func describe(_ intent: SpotifyManager.ExplicitSpotifyIntent) -> String {
        if case .search(let request) = intent { return "search(\(request.displayText))" }
        return String(describing: intent)
    }

    private static func load(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") }
    }

    func testRuleRoutesMatchSnapshot() throws {
        let rows = try Self.load(Self.corpusURL).compactMap { line -> Row? in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return parts.count == 3 ? Row(mode: parts[0], logged: parts[1], text: parts[2]) : nil
        }
        XCTAssertGreaterThan(rows.count, 100, "corpus looks empty; run tools/route_corpus.py")

        let current = rows.map { row in
            (key: "\(row.mode)\t\(row.text)", route: Self.ruleRoute(row.text, voice: row.mode == "voice"), logged: row.logged)
        }

        if ProcessInfo.processInfo.environment["UPDATE_ROUTE_SNAPSHOT"] != nil {
            let body = current.map { "\($0.key)\t\($0.route)\n" }.joined()
            try ("# mode\ttext\trule route — written by RouteCorpusTests (UPDATE_ROUTE_SNAPSHOT=1)\n" + body)
                .write(to: Self.snapshotURL, atomically: true, encoding: .utf8)
            print("[RouteCorpus] wrote \(current.count) rows to the snapshot")
            return
        }

        var snapshot: [String: String] = [:]
        for line in try Self.load(Self.snapshotURL) {
            guard let cut = line.range(of: "\t", options: .backwards) else { continue }
            snapshot[String(line[..<cut.lowerBound])] = String(line[cut.upperBound...])
        }

        var diffs: [String] = []
        for row in current {
            guard let expected = snapshot[row.key] else {
                diffs.append("NEW      \(row.key.replacingOccurrences(of: "\t", with: " | ")) → \(row.route)")
                continue
            }
            if expected != row.route {
                diffs.append("CHANGED  \(row.key.replacingOccurrences(of: "\t", with: " | "))\n         was \(expected) → now \(row.route) (app logged: \(row.logged))")
            }
        }
        XCTAssert(diffs.isEmpty, "\(diffs.count) routing change(s); review, then UPDATE_ROUTE_SNAPSHOT=1:\n" + diffs.joined(separator: "\n"))
    }
}
