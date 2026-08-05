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
        var count: Int            // observation count — NOT proof the pair was ever applied
        var status: Status
        var firstSeen: Date
        var lastSeen: Date
        /// How many times this pair actually fired inside `CorrectionEngine.applyCorrections`
        /// at paste time (distinct from `count`, which only tracks how many times the user's
        /// edit was *observed* — a record can sit at count=22 and appliedCount=0 forever if it
        /// never matches real dictation text). See `CorrectionStore.recordApplied`.
        var appliedCount: Int = 0
        var lastApplied: Date?
        /// How many times the user has REVERTED this exact pair back after it fired (see
        /// `CorrectionStore.recordRejection`, called from `DictationSnapshot.diffAndLearn`'s
        /// reversal detection). Tracked separately from `count` so a persistent revert can force
        /// `.disabled` even when `count` (built up from unrelated observations) is still high.
        var rejectionCount: Int = 0

        // Custom Codable: existing installs' corrections.json predates `appliedCount`/
        // `lastApplied`/`rejectionCount`. A synthesized decoder would call plain `decode` for the
        // non-optional `appliedCount`/`rejectionCount` and throw `keyNotFound` on that old JSON,
        // and `CorrectionStore.load()` catches decode errors by silently leaving `records` empty
        // — i.e. the default `= 0` above does NOT help decoding (memberwise-init defaults are not
        // consulted by Decodable synthesis); without this custom init every existing user's
        // learned corrections would vanish on first launch after this change. `decodeIfPresent ??
        // 0` here is what actually provides the back-compat fallback.
        private enum CodingKeys: String, CodingKey {
            case wrong, right, count, status, firstSeen, lastSeen, appliedCount, lastApplied, rejectionCount
        }

        init(wrong: String, right: String, count: Int, status: Status, firstSeen: Date, lastSeen: Date, appliedCount: Int = 0, lastApplied: Date? = nil, rejectionCount: Int = 0) {
            self.wrong = wrong
            self.right = right
            self.count = count
            self.status = status
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
            self.appliedCount = appliedCount
            self.lastApplied = lastApplied
            self.rejectionCount = rejectionCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            wrong = try container.decode(String.self, forKey: .wrong)
            right = try container.decode(String.self, forKey: .right)
            count = try container.decode(Int.self, forKey: .count)
            status = try container.decode(Status.self, forKey: .status)
            firstSeen = try container.decode(Date.self, forKey: .firstSeen)
            lastSeen = try container.decode(Date.self, forKey: .lastSeen)
            appliedCount = try container.decodeIfPresent(Int.self, forKey: .appliedCount) ?? 0
            lastApplied = try container.decodeIfPresent(Date.self, forKey: .lastApplied)
            rejectionCount = try container.decodeIfPresent(Int.self, forKey: .rejectionCount) ?? 0
        }
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

        // Guard: a common real word must never sit on the "wrong" side (e.g. "kafes" -> "kafe"
        // would silently mangle every real occurrence of "kafes").
        if CorrectionEngine.isProtectedWrongSide(key) {
            owLog("[Corrections] Rejected observation (protected real word on wrong side): \(key) -> \(right)")
            return
        }

        // Guard: reject anything that would form/reinforce a bidirectional cycle with another
        // still-live (non-disabled) record — this is exactly the "commit'" -> "komit" while
        // "komit" -> "commit" was already active poisoning that caused the store to fight
        // itself. Disabled records are excluded from this check: once a record is inert it
        // should not go on vetoing unrelated future observations forever.
        let rightKey = CorrectionEngine.trLower(right)
        let liveRecords = records.filter { $0.status != .disabled }
        let createsCycle = liveRecords.contains(where: { $0.wrong == rightKey })
            || liveRecords.contains(where: { CorrectionEngine.trLower($0.right) == key })
        if createsCycle {
            owLog("[Corrections] Rejected observation (would create a wrong<->right cycle): \(key) -> \(right)")
            return
        }

        if let idx = records.firstIndex(where: { $0.wrong == key }) {
            records[idx].count += 1
            records[idx].lastSeen = Date()
            // Keep the most recently seen casing for the "right" side.
            records[idx].right = right
            // Short roots (<4 chars) collide too easily with unrelated words, so they may
            // accumulate observations but never auto-promote — the user must approve them by
            // hand in Settings.
            if records[idx].status == .candidate, records[idx].count >= 2, key.count >= 4 {
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

    /// Outcome of `recordManualObservation` — every case maps to exactly one flow-bar message
    /// in `DictationSnapshot`/`AppState`, so the caller always knows what (if anything) to tell
    /// the user.
    enum ManualObservationResult {
        case learned(wrong: String, right: String)
        /// The record is ALREADY `.active` with this exact right-hand side, so nothing changed.
        /// Distinct from `.learned` because repeated Option+Shift+C presses on the same edit are
        /// the expected workflow (the snapshot deliberately stays open now): re-running the
        /// observation would inflate `count` on every press, and reporting "not found" would be
        /// a flat lie — the pair IS active, it just didn't need writing again.
        case alreadyActive(wrong: String, right: String)
        case rejectedProtectedWord(String)
        case rejectedCycle(String)
        case rejectedDisabledRecord(String)   // record exists but user disabled it — do NOT resurrect
        case rejectedLearningOff
    }

    /// Manual-review counterpart of `recordObservation` (Option+Shift+C, via
    /// `DictationSnapshot.reviewCurrentDifference`). The user has just explicitly confirmed this
    /// pair by hand-editing pasted text and asking OpenWhisper to look again, so unlike the
    /// automatic path a single observation goes straight to `.active` rather than waiting for a
    /// second occurrence. This does NOT relax any safety guard: `isProtectedWrongSide` and the
    /// wrong<->right cycle guard are copied verbatim from `recordObservation` (see its comments
    /// for why — the store previously poisoned itself, e.g. "kafes"->"kafe",
    /// "commit'"->"komit"/"komit"->"commit" cycling forever). A record the user previously
    /// disabled (`reject()`) is also never resurrected here — that was a deliberate decision the
    /// user made and a manual review must not silently override it.
    @discardableResult
    func recordManualObservation(wrong: String, right: String) -> ManualObservationResult {
        guard learningEnabled else {
            owLog("[Corrections] Manual observation rejected (learning disabled): \(wrong) -> \(right)")
            return .rejectedLearningOff
        }
        let key = CorrectionEngine.trLower(wrong)

        // Guard: a common real word must never sit on the "wrong" side — copied verbatim from
        // `recordObservation`'s guard, never bypassed even for a manual/explicit review.
        if CorrectionEngine.isProtectedWrongSide(key) {
            owLog("[Corrections] Manual observation rejected (protected real word on wrong side): \(key) -> \(right)")
            return .rejectedProtectedWord(key)
        }

        // Guard: reject anything that would form/reinforce a bidirectional cycle with another
        // still-live (non-disabled) record — copied verbatim from `recordObservation`'s guard.
        let rightKey = CorrectionEngine.trLower(right)
        let liveRecords = records.filter { $0.status != .disabled }
        let createsCycle = liveRecords.contains(where: { $0.wrong == rightKey })
            || liveRecords.contains(where: { CorrectionEngine.trLower($0.right) == key })
        if createsCycle {
            owLog("[Corrections] Manual observation rejected (would create a wrong<->right cycle): \(key) -> \(right)")
            return .rejectedCycle(key)
        }

        if let idx = records.firstIndex(where: { $0.wrong == key }) {
            // The user turned this pair off on purpose (see `reject()`'s doc comment) — a manual
            // review re-observing the same wrong/right text must not quietly re-enable it.
            if records[idx].status == .disabled {
                owLog("[Corrections] Manual observation rejected (record previously disabled by user): \(key) -> \(right)")
                return .rejectedDisabledRecord(key)
            }
            // Idempotent no-op when this pair is already exactly what a manual review would
            // write. `count` is deliberately NOT bumped: pressing Option+Shift+C three times to
            // check on one edit is not three observations, and inflating `count` here would
            // silently widen `activePairs`' `allowSuffixMatching` gate on nothing but presses.
            if records[idx].status == .active,
               CorrectionEngine.trLower(records[idx].right) == CorrectionEngine.trLower(right) {
                records[idx].lastSeen = Date()
                records[idx].right = right   // keep the newest casing, same as below
                owLog("[Corrections] Manual observation: already ACTIVE, no change \(key) -> \(right) (count=\(records[idx].count))")
                save()
                return .alreadyActive(wrong: key, right: right)
            }
            let newCount = max(records[idx].count + 1, 2)
            records[idx].count = newCount
            records[idx].lastSeen = Date()
            records[idx].right = right
            records[idx].status = .active
            if key.count < CorrectionEngine.minRootLengthForSuffixMatch {
                owLog("[Corrections] Manual observation: activating short root (<\(CorrectionEngine.minRootLengthForSuffixMatch) chars) by explicit user intent — suffix-chain matching stays disabled for it (minRootLengthForSuffixMatch): \(key) -> \(right)")
            }
            owLog("[Corrections] Manual observation: ACTIVE \(key) -> \(right) (count=\(newCount))")
            save()
            return .learned(wrong: key, right: right)
        } else {
            let record = Record(wrong: key, right: right, count: 2, status: .active, firstSeen: Date(), lastSeen: Date())
            records.append(record)
            if key.count < CorrectionEngine.minRootLengthForSuffixMatch {
                owLog("[Corrections] Manual observation: activating short root (<\(CorrectionEngine.minRootLengthForSuffixMatch) chars) by explicit user intent — suffix-chain matching stays disabled for it (minRootLengthForSuffixMatch): \(key) -> \(right)")
            }
            owLog("[Corrections] Manual observation: new ACTIVE \(key) -> \(right) (count=2)")
            save()
            return .learned(wrong: key, right: right)
        }
    }

    // MARK: - Applying

    /// All ACTIVE pairs, ready to feed into CorrectionEngine.applyCorrections.
    var activePairs: [CorrectionEngine.LearnedPair] {
        guard learningEnabled else { return [] }
        return records
            .filter { $0.status == .active }
            // Suffix-symmetric matching is more aggressive than exact/apostrophe matching, so
            // it's gated on the pair having been CONFIRMED BY REPETITION — observed 2+ times
            // (`$0.count`, not root length; CorrectionEngine separately enforces its own
            // root-length floor via minRootLengthForSuffixMatch plus a protected-word check).
            //
            // 2, not 3: count 2 is exactly where `recordObservation` auto-promotes candidate ->
            // active, so it is the real "earned by repetition" line. A threshold of 3 matched
            // exactly ONE record in the user's live store (and the migration disables that one),
            // which would have left suffix matching switched off for every pair in practice —
            // i.e. the whole feature inert. Records still sitting at count 1 are the manually
            // approved / legacy ones, and those stay on exact matching only.
            .map { CorrectionEngine.LearnedPair(wrong: $0.wrong, right: $0.right, allowSuffixMatching: $0.count >= 2) }
    }

    /// Bumps `appliedCount`/`lastApplied` for every (wrong, right) pair that actually fired
    /// during one dictation's `CorrectionEngine.applyCorrections` call, then persists once —
    /// a single paste can apply several learned pairs, so this batches into a single `save()`
    /// rather than one per pair.
    func recordApplied(pairs: [(String, String)]) {
        guard !pairs.isEmpty else { return }
        for (wrong, _) in pairs {
            let key = CorrectionEngine.trLower(wrong)
            guard let idx = records.firstIndex(where: { $0.wrong == key }) else { continue }
            records[idx].appliedCount += 1
            records[idx].lastApplied = Date()
        }
        save()
    }

    /// Called when `DictationSnapshot.diffAndLearn` detects the user reverting an applied pair
    /// back to its original wrong form — i.e. the correction fired and the user immediately
    /// undid it, a strong signal the learned pair is bad. Penalizes rather than deletes so a
    /// single accidental revert doesn't nuke a record built from many good observations, but a
    /// SECOND revert (or the penalty dropping `count` below 1) disables it outright. Never
    /// re-runs `recordObservation` for the reversed direction — see the caller.
    func recordRejection(wrong: String) {
        let key = CorrectionEngine.trLower(wrong)
        guard let idx = records.firstIndex(where: { $0.wrong == key }) else {
            owLog("[Corrections] Rejection ignored — no record for '\(key)'")
            return
        }

        records[idx].count -= 1
        records[idx].rejectionCount += 1
        let count = records[idx].count
        let rejectionCount = records[idx].rejectionCount

        if records[idx].status != .disabled, rejectionCount >= 2 || count < 1 {
            records[idx].status = .disabled
            owLog("[Corrections] Rejection: DISABLED '\(key) -> \(records[idx].right)' (rejectionCount=\(rejectionCount), count=\(count)) — persistent user reversal")
        } else {
            owLog("[Corrections] Rejection: penalized '\(key) -> \(records[idx].right)' (count now \(count), rejectionCount=\(rejectionCount))")
        }
        save()
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

        // Manual entries are exempt from the recordObservation guards — the user typed this
        // deliberately — but still worth a log line if it would have tripped the cycle guard,
        // in case the user is about to recreate the commit'/komit-style poisoning by hand.
        let rightKey = CorrectionEngine.trLower(rightTrimmed)
        let liveRecords = records.filter { $0.status != .disabled }
        if liveRecords.contains(where: { $0.wrong == rightKey }) || liveRecords.contains(where: { CorrectionEngine.trLower($0.right) == key }) {
            owLog("[Corrections] Manual add creates a wrong<->right cycle (allowed, user override): \(key) -> \(rightTrimmed)")
        }

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
            return
        }
        migrateCleanupV1IfNeeded()
    }

    /// One-time cleanup of data that predates the `recordObservation` poisoning guards above.
    /// Demotes/disables `.active` records that those guards would have rejected outright had
    /// they existed at the time, plus a short hand-picked list of pairs that are semantically
    /// bad but don't trip any structural rule. Gated by a UserDefaults flag so it runs exactly
    /// once per install and never re-touches a record the user deliberately re-enables later.
    /// Disables rather than deletes — same rationale as `reject()`: a deleted record can be
    /// silently re-learned from scratch, quietly undoing the cleanup.
    private func migrateCleanupV1IfNeeded() {
        let flagKey = "correctionsPurgeV1Done"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        UserDefaults.standard.set(true, forKey: flagKey)

        // Named list: semantically bad pairs no structural rule below catches on its own
        // (real product name, failed root extraction, already-wrong Turkish on the right side,
        // both sides meaningless, or a real English word on the wrong side).
        // "biyet" -> "Diet" belongs here rather than to the <4-char rule: it is 5 characters, so
        // the length floor never catches it, but it is a one-off mishearing whose two disabled
        // siblings ("biyetten"/"vietta" -> "Diette") show the whole cluster was noise.
        let namedDisable: Set<String> = ["gitlab", "bilisayarı", "efene basınca", "spinl", "pushed", "biyet"]

        // Cycle detection needs a stable snapshot of active "wrong" keys as they stood BEFORE
        // this loop starts mutating statuses, so disabling one cyclic record doesn't change
        // whether another one still counts as cyclic.
        let activeWrongKeysBefore = Set(records.filter { $0.status == .active }.map { $0.wrong })

        var disabledCount = 0
        var demotedCount = 0

        for idx in records.indices {
            guard records[idx].status == .active else { continue }
            let wrong = records[idx].wrong
            let rightKey = CorrectionEngine.trLower(records[idx].right)

            if namedDisable.contains(wrong) {
                records[idx].status = .disabled
                disabledCount += 1
                owLog("[Corrections] Migration: disabled (named, semantically bad) \(wrong) -> \(records[idx].right)")
            } else if CorrectionEngine.isProtectedWrongSide(wrong) {
                records[idx].status = .disabled
                disabledCount += 1
                owLog("[Corrections] Migration: disabled (protected real word) \(wrong) -> \(records[idx].right)")
            } else if activeWrongKeysBefore.contains(rightKey) {
                records[idx].status = .disabled
                disabledCount += 1
                owLog("[Corrections] Migration: disabled (wrong<->right cycle) \(wrong) -> \(records[idx].right)")
            } else if wrong.count < 4 {
                records[idx].status = .candidate
                demotedCount += 1
                owLog("[Corrections] Migration: demoted to candidate (root <4 chars) \(wrong) -> \(records[idx].right)")
            }
        }

        if disabledCount > 0 || demotedCount > 0 {
            owLog("[Corrections] Migration V1 complete: \(disabledCount) disabled, \(demotedCount) demoted to candidate")
            save()
        }
    }
}
