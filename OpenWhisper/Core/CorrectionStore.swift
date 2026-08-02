import Foundation
import Observation

/// Persists the "learned corrections" the user's manual edits have taught OpenWhisper —
/// see CorrectionEngine.swift for the diff/accept/root-extraction logic that produces
/// candidates, and DictationSnapshot.swift for how they're captured from real dictations.
@Observable
@MainActor
final class CorrectionStore {

    static let shared = CorrectionStore()

    enum Status: String, Codable {
        case candidate  // seen once — needs the user's explicit approval in Settings
        case active     // seen 2+ times, or manually approved — applied automatically
        case disabled   // user turned it off; never auto-activates again
    }

    struct Record: Codable, Identifiable {
        var id: String { wrong }  // wrong-side ROOT is the natural key (case-insensitive, tr)
        let wrong: String         // stored lowercase (tr locale), root form
        var right: String         // stored with its first-seen casing, root form
        var count: Int
        var status: Status
        var firstSeen: Date
        var lastSeen: Date
    }

    /// Master switch — when off, nothing is captured, learned, or applied. Mirrors the
    /// AppState `didSet { UserDefaults... }` persistence pattern used throughout the app
    /// (this codebase doesn't use @AppStorage anywhere despite the property-wrapper name
    /// suggesting it might).
    var learningEnabled: Bool {
        didSet { UserDefaults.standard.set(learningEnabled, forKey: "correctionLearningEnabled") }
    }

    private(set) var records: [Record] = []

    private let storageURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("OpenWhisper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("corrections.json")
    }()

    private init() {
        learningEnabled = UserDefaults.standard.object(forKey: "correctionLearningEnabled") as? Bool ?? true
        load()
    }

    // MARK: - Recording observed corrections

    /// Record one observed (wrong, right) ROOT pair from a diff. Bumps `count`/`lastSeen`
    /// if already known; a fresh pair starts as `.candidate`. Reaching count 2 promotes a
    /// `.candidate` to `.active` automatically — a `.disabled` record is never re-activated
    /// this way (the user turned it off on purpose).
    func recordObservation(wrong: String, right: String) {
        guard learningEnabled else { return }
        let key = CorrectionEngine.trLower(wrong)
        guard !key.isEmpty else { return }

        if let idx = records.firstIndex(where: { $0.wrong == key }) {
            records[idx].count += 1
            records[idx].lastSeen = Date()
            // Keep the most recently seen casing for the "right" side.
            records[idx].right = right
            if records[idx].status == .candidate, records[idx].count >= 2 {
                records[idx].status = .active
            }
            owLog("[Corrections] Observation bump: \(key) -> \(right) (count=\(records[idx].count), status=\(records[idx].status.rawValue))")
        } else {
            let record = Record(wrong: key, right: right, count: 1, status: .candidate, firstSeen: Date(), lastSeen: Date())
            records.append(record)
            owLog("[Corrections] New candidate: \(key) -> \(right)")
        }
        save()
    }

    // MARK: - Applying

    /// All ACTIVE pairs, ready to feed into CorrectionEngine.applyCorrections.
    var activePairs: [CorrectionEngine.LearnedPair] {
        guard learningEnabled else { return [] }
        return records
            .filter { $0.status == .active }
            .map { CorrectionEngine.LearnedPair(wrong: $0.wrong, right: $0.right) }
    }

    // MARK: - Settings UI actions

    func approve(id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].status = .active
        save()
    }

    /// "Reddet" on a still-pending candidate — per spec, once disabled a record must never
    /// auto-activate again, so this sets status rather than deleting the record outright
    /// (deleting would let a later re-observation of the same mishearing quietly start a
    /// fresh candidate → active cycle, silently undoing the rejection).
    func reject(id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].status = .disabled
        save()
    }

    /// Discard an unimportant candidate without assigning it any meaning.
    /// Unlike `reject`, this removes the record entirely so it cannot be applied,
    /// shown as rejected, or treated as a permanent user decision.
    func discard(id: String) {
        records.removeAll { $0.id == id }
        save()
    }

    func setDisabled(id: String, disabled: Bool) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].status = disabled ? .disabled : .active
        save()
    }

    func delete(id: String) {
        records.removeAll { $0.id == id }
        save()
    }

    /// Manual entry from the Settings "add a correction" field — treated as pre-approved.
    func addManual(wrong: String, right: String) {
        let key = CorrectionEngine.trLower(wrong.trimmingCharacters(in: .whitespacesAndNewlines))
        let rightTrimmed = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !rightTrimmed.isEmpty else { return }

        if let idx = records.firstIndex(where: { $0.wrong == key }) {
            records[idx].right = rightTrimmed
            records[idx].status = .active
            records[idx].lastSeen = Date()
        } else {
            records.append(Record(wrong: key, right: rightTrimmed, count: 2, status: .active, firstSeen: Date(), lastSeen: Date()))
        }
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            owLog("[Corrections] Save error: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            records = try JSONDecoder().decode([Record].self, from: data)
        } catch {
            owLog("[Corrections] Load error: \(error)")
        }
    }
}
