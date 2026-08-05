import AppKit
import ApplicationServices
import Observation

/// Captures what a text field looked like right after OpenWhisper pasted into it, then
/// later re-reads the same field at configured checkpoint intervals (e.g. 5s, 10s, 40s)
/// and via AXObserver (if supported) to see what the user's manual edits left behind,
/// feeding any new diff into CorrectionStore. See CorrectionEngine.swift for filtering/root-
/// extraction rules.
///
/// Concurrency & AXObserver notes:
/// - `AXUIElement` is not Sendable; `Boxed` wraps one as `@unchecked Sendable`.
/// - Each snapshot carries a `generation` counter. Deduplication within a generation prevents
///   multiple checkpoint rereads of the same edit from bumping correction counts repeatedly.
/// - If `AXObserver` registers successfully on the focused element, it instantly catches edits.
///   Checkpoint timers serve both alongside AXObserver and as the primary safety net when
///   AXObserver is unsupported by the target application.
/// - Once the final checkpoint (e.g. 40s) completes its diff, if no AXObserver is active, the
///   snapshot is closed (clear()).
///   Reasoning: Without an active AXObserver, after all scheduled checkpoint timers have elapsed,
///   there are no further automated checks. Keeping the snapshot open indefinitely would waste
///   resources and risk stale diffs if the user types unrelated text much later. If an AXObserver
///   IS active, the snapshot is kept open until a new dictation starts, frontmost app changes,
///   or Option+Z swap invalidates it.
@Observable
@MainActor
final class DictationSnapshot {

    static let shared = DictationSnapshot()

    private final class Boxed: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let bundleID: String?
        let pastedRange: Range<Int>   // UTF-16 offsets into `fieldTextAtPaste`
        let fieldTextAtPaste: String
        let pastedText: String
        let generation: Int
        /// Learned (wrong, right) ROOT pairs that `CorrectionEngine.applyCorrections` actually
        /// fired for THIS dictation's pasted text — used by `diffAndLearn` to detect the user
        /// reverting one of them back (see `capture(appliedPairs:)`). Does NOT include
        /// `PhoneticGlossaryCorrector` substitutions — that's a separate mechanism with no
        /// corresponding entry in `CorrectionStore`.
        let appliedPairs: [(wrong: String, right: String)]

        init(element: AXUIElement, pid: pid_t, bundleID: String?, pastedRange: Range<Int>,
             fieldTextAtPaste: String, pastedText: String, generation: Int,
             appliedPairs: [(wrong: String, right: String)]) {
            self.element = element
            self.pid = pid
            self.bundleID = bundleID
            self.pastedRange = pastedRange
            self.fieldTextAtPaste = fieldTextAtPaste
            self.pastedText = pastedText
            self.generation = generation
            self.appliedPairs = appliedPairs
        }
    }

    private var current: Boxed?
    private var generationCounter = 0
    private var checkpointTimers: [Timer] = []
    private var observerDebounceTimer: Timer?
    private var axObserver: AXObserver?
    private var axObserverElement: AXUIElement?
    private var installedAt: Date?
    private var activationObserver: NSObjectProtocol?
    private var suppressNextCapture = false

    /// The last successfully installed dictation's pasted text + applied learned pairs,
    /// retained across `clear()`/final rereads so Option+Shift+C still has something to review
    /// even after the snapshot itself has closed (checkpoint completed, app switched away,
    /// next dictation started, etc.). Deliberately NOT retained across `invalidateForSwap()` —
    /// that path means the user discarded this dictation outright (Option+Z), so there is
    /// nothing legitimate left to review. The `generation` tag lets a LATE-arriving capture
    /// failure (see `invalidateRetainedTextIfStale`) tell whether it's still the most recent
    /// capture attempt before clearing this — a failed recapture must not blow away a genuinely
    /// newer successful one that already raced ahead of it.
    private var lastReviewableText: (pastedText: String, appliedPairs: [(wrong: String, right: String)], generation: Int)?

    /// Fired exactly once per Option+Shift+C press, on the MainActor, once the manual review's
    /// diff has actually completed (it's async — cross-process AX reads happen on a background
    /// queue). `DictationSnapshot` must not depend on AppState/AppKit UI, so this is a plain
    /// closure the app layer wires to `AppState.showFlowBarMessage`. The automatic path
    /// (AXObserver/checkpoint/app-switch reread) never invokes this.
    var onManualReviewResult: ((String) -> Void)?

    /// Keys (`wrongRoot->rightRoot`) learned during the CURRENT snapshot generation, preventing
    /// multiple checkpoint rereads from recording the same edit more than once per dictation.
    private var learnedInCurrentGen: Set<String> = []

    /// Reversal penalty keys (`trLower(matchedPair.wrong)`) already sent to
    /// `CorrectionStore.recordRejection` during the CURRENT snapshot generation — mirrors
    /// `learnedInCurrentGen`'s dedupe, but for penalties instead of learns. Manual review
    /// (task 1) deliberately keeps the snapshot open across repeated Option+Shift+C presses
    /// (`isFinal: false`), so without this a user reverting a correction and pressing the
    /// shortcut twice on the SAME still-reverted text — now the expected, encouraged gesture —
    /// would call `recordRejection` twice and disable an otherwise-good record purely because
    /// of repeated presses, not repeated genuine reversals. ONLY consulted for the manual path
    /// with an active snapshot (`manual && dedupe` in `processDiff`); the automatic path's
    /// per-checkpoint penalty calls are left completely unchanged, and the retained-text
    /// fallback (`reviewRetained`, no generation to scope a dedupe to) never penalizes at all.
    private var penalizedInCurrentGen: Set<String> = []

    /// Configured checkpoint intervals (seconds), used only when AXObserver is unavailable.
    private(set) var checkpointIntervals: [TimeInterval] = CorrectionEngine.defaultCheckpoints

    /// Raw comma-separated string persisted in UserDefaults.
    var checkpointsString: String {
        didSet {
            if let parsed = CorrectionEngine.parseCheckpoints(checkpointsString) {
                checkpointIntervals = parsed
                UserDefaults.standard.set(checkpointsString, forKey: "correctionCheckpoints")
            }
        }
    }

    private init() {
        let storedValue = UserDefaults.standard.string(forKey: "correctionCheckpoints")
        // Migrate the old every-second default while preserving a user's deliberate custom list.
        let stored = storedValue == CorrectionEngine.legacyDefaultCheckpointsString
            ? CorrectionEngine.defaultCheckpointsString
            : (storedValue ?? CorrectionEngine.defaultCheckpointsString)
        if let parsed = CorrectionEngine.parseCheckpoints(stored) {
            self.checkpointsString = stored
            self.checkpointIntervals = parsed
        } else {
            self.checkpointsString = CorrectionEngine.defaultCheckpointsString
            self.checkpointIntervals = CorrectionEngine.defaultCheckpoints
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleActivation(note)
            }
        }
    }

    // MARK: - Capture

    /// Called right after TextInjector's `onPasted` fires for a real dictation paste — takes
    /// the AX snapshot on a background queue and installs it if successful. Silently gives
    /// up (log only, no user-facing error) if AX can't read the field.
    func capture(pastedText: String, targetApp: NSRunningApplication?, appliedPairs: [(wrong: String, right: String)] = []) {
        guard CorrectionStore.shared.learningEnabled else { return }
        generationCounter += 1
        let generation = generationCounter
        let pid = targetApp?.processIdentifier ?? 0
        let bundleID = targetApp?.bundleIdentifier

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let element = AXTextAccess.focusedElement() else {
                owLog("[Corrections] Snapshot skipped (gen \(generation)) — no focused AX element")
                Task { @MainActor in self?.invalidateRetainedTextIfStale(generation: generation) }
                return
            }
            let valueResult = AXTextAccess.readString(element, kAXValueAttribute as CFString)
            guard let fieldText = valueResult.value else {
                owLog("[Corrections] Snapshot skipped (gen \(generation)) — value unreadable (\(AXTextAccess.describe(valueResult.error)))")
                Task { @MainActor in self?.invalidateRetainedTextIfStale(generation: generation) }
                return
            }

            let fieldUTF16Count = fieldText.utf16.count
            let pastedUTF16Len = pastedText.utf16.count
            var range: Range<Int>?

            let rangeResult = AXTextAccess.readSelectedRange(element)
            if let cfRange = rangeResult.range {
                let cursorEnd = cfRange.location
                let cursorStart = cursorEnd - pastedUTF16Len
                if cursorStart >= 0, cursorEnd <= fieldUTF16Count,
                   Self.utf16Slice(fieldText, cursorStart..<cursorEnd) == pastedText {
                    range = cursorStart..<cursorEnd
                }
            }

            if range == nil, let found = fieldText.range(of: pastedText, options: .backwards) {
                let s = found.lowerBound.utf16Offset(in: fieldText)
                let e = found.upperBound.utf16Offset(in: fieldText)
                range = s..<e
            }

            guard let finalRange = range else {
                owLog("[Corrections] Snapshot skipped (gen \(generation)) — pasted text not locatable in field")
                Task { @MainActor in self?.invalidateRetainedTextIfStale(generation: generation) }
                return
            }

            let boxed = Boxed(
                element: element,
                pid: pid,
                bundleID: bundleID,
                pastedRange: finalRange,
                fieldTextAtPaste: fieldText,
                pastedText: pastedText,
                generation: generation,
                appliedPairs: appliedPairs
            )

            Task { @MainActor in
                self?.install(boxed)
            }
        }
    }

    /// Called from every failure branch of `capture`'s background AX read. If `capture` cannot
    /// confirm what the field now contains (no focused element, unreadable value, or the pasted
    /// text isn't locatable), the previously retained pasted text may now be stale — most
    /// concretely: AppState re-runs `capture` after LLM cleanup replaces the pasted text in
    /// place (see AppState's `replaceInjectedText` completion), and if THAT recapture fails here,
    /// `lastReviewableText` would otherwise keep pointing at the pre-cleanup RAW text forever
    /// even though the field genuinely now holds the cleaned text — exactly the raw-vs-cleaned
    /// staleness this feature exists to prevent, just relocated to the retained-text fallback.
    /// Guarded by generation so a late-arriving failure for an OLDER capture can't clobber a
    /// genuinely newer successful one that already raced ahead of it.
    private func invalidateRetainedTextIfStale(generation: Int) {
        guard let last = lastReviewableText, last.generation < generation else { return }
        owLog("[Corrections] Retained reviewable text cleared — capture (gen \(generation)) failed to confirm current field contents")
        lastReviewableText = nil
    }

    private func install(_ boxed: Boxed) {
        if suppressNextCapture {
            suppressNextCapture = false
            owLog("[Corrections] Snapshot dropped (gen \(boxed.generation)) — suppressed by an intervening Option+Z swap")
            return
        }

        clear() // Clear any active timers/observer from a previous snapshot

        current = boxed
        installedAt = Date()
        learnedInCurrentGen.removeAll()
        penalizedInCurrentGen.removeAll()
        lastReviewableText = (boxed.pastedText, boxed.appliedPairs, boxed.generation)

        // Attempt instant AXObserver setup
        let observerActive = setupAXObserver(pid: boxed.pid, element: boxed.element)

        // AXObserver delivers the relevant edits immediately. Timers are needed only for apps
        // which cannot provide that notification; otherwise they caused 30 needless wakeups.
        let intervals = observerActive ? [] : checkpointIntervals
        for (index, interval) in intervals.enumerated() {
            let isLast = (index == intervals.count - 1)
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.handleCheckpoint(
                        index: index + 1,
                        total: intervals.count,
                        interval: interval,
                        isLast: isLast,
                        generation: boxed.generation
                    )
                }
            }
            checkpointTimers.append(timer)
        }

        owLog("[Corrections] Snapshot installed (gen \(boxed.generation), pid \(boxed.pid), bundle \(boxed.bundleID ?? "?"), checkpoints: \(intervals)s, observer: \(observerActive ? "active" : "unavailable"))")
    }

    // MARK: - AXObserver Setup

    private func setupAXObserver(pid: pid_t, element: AXUIElement) -> Bool {
        var observer: AXObserver?
        let callback: AXObserverCallback = { observer, element, notification, refcon in
            guard let refcon = refcon else { return }
            let instance = Unmanaged<DictationSnapshot>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                instance.handleAXObserverEvent()
            }
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let createErr = AXObserverCreate(pid, callback, &observer)
        guard createErr == .success, let observer = observer else { return false }

        let addErr = AXObserverAddNotification(observer, element, kAXValueChangedNotification as CFString, refcon)
        guard addErr == .success else { return false }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

        axObserver = observer
        axObserverElement = element
        return true
    }

    private func removeAXObserver() {
        if let observer = axObserver, let element = axObserverElement {
            AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
            let source = AXObserverGetRunLoopSource(observer)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        axObserver = nil
        axObserverElement = nil
    }

    /// How long the field must sit still before an AXObserver burst is treated as a finished
    /// edit. This was 0.35s, which is shorter than the pause between two keystrokes — so the
    /// automatic path diffed and LEARNED FROM half-typed text. Live evidence from one edit of
    /// "komitat" into "commit at": at 15:31:47 it diffed against `komitat -> com` (rejected on
    /// similarity), at 15:31:48 it wrote `komitat -> comit at` as a real new candidate, and only
    /// at 15:31:51 did it see the finished `komitat -> commit at`. That run self-repaired purely
    /// because the wrong-side key never changed; an edit that also touches the wrong-side word
    /// would leave the junk record behind permanently. 1.5s is above a normal inter-keystroke
    /// pause but still well inside the time it takes to switch apps or start a new dictation
    /// (both of which force a final reread anyway), so no finished edit is lost by waiting.
    private static let observerDebounceInterval: TimeInterval = 1.5

    private func handleAXObserverEvent() {
        guard let boxed = current else { return }
        // Text fields can emit a burst of value-change notifications for one user edit. Coalesce
        // the burst before performing the cross-process AX read and diff.
        observerDebounceTimer?.invalidate()
        observerDebounceTimer = Timer.scheduledTimer(withTimeInterval: Self.observerDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.current?.generation == boxed.generation else { return }
                self.observerDebounceTimer = nil
                owLog("[Corrections] AXObserver value change settled (gen \(boxed.generation))")
                self.triggerReread(reason: "AXObserver event", isFinal: false)
            }
        }
    }

    // MARK: - Checkpoints & Invalidation

    private func handleCheckpoint(index: Int, total: Int, interval: TimeInterval, isLast: Bool, generation: Int) {
        guard let boxed = current, boxed.generation == generation else { return }
        let observerActive = (axObserver != nil)
        // If this is the last checkpoint and AXObserver is not active, this reread will close the snapshot.
        let isFinal = isLast && !observerActive
        let reason = "checkpoint \(index)/\(total) (\(Int(interval))s)"
        owLog("[Corrections] Checkpoint \(index)/\(total) (\(Int(interval))s) reached (gen \(generation))")
        triggerReread(reason: reason, isFinal: isFinal)
    }

    /// Called by AppState.commitSwap(). Option+Z swap invalidates the snapshot without diffing.
    func invalidateForSwap() {
        suppressNextCapture = true
        lastReviewableText = nil
        if current != nil {
            owLog("[Corrections] Snapshot discarded — Option+Z swap")
            clear()
        }
    }

    /// Called before a new dictation starts — completes any in-flight snapshot diff first.
    func handleNewDictationStarting() {
        suppressNextCapture = false
        if current != nil {
            triggerReread(reason: "next dictation starting", isFinal: true)
        }
    }

    /// Immediately compares the text that was pasted by OpenWhisper with the current
    /// contents of the same field. This is the manual (Option+Shift+C) shortcut path for
    /// cases where the user has finished editing and does not want to wait for a checkpoint
    /// or app switch.
    ///
    /// `isFinal: false` deliberately — unlike every automatic trigger, a manual review must
    /// NOT close its own snapshot. Closing it here would guarantee a second press finds no
    /// active snapshot (exactly the reported bug); checkpoints/AXObserver keep watching the
    /// same snapshot afterwards, and the user can press the shortcut again after further edits.
    ///
    /// If there is no active snapshot (checkpoints already finished and closed it, the user
    /// switched apps and back, etc.), falls back to `lastReviewableText`: re-reads the
    /// currently focused field fresh and diffs it against the last dictation's pasted text,
    /// gated by a 50% LCS word-coverage check so an unrelated field never gets diffed against.
    func reviewCurrentDifference() {
        if current != nil {
            triggerReread(reason: "manual correction shortcut", isFinal: false, manual: true)
            return
        }

        guard let retained = lastReviewableText else {
            owLog("[Corrections] Manual review — no active snapshot and no retained pasted text")
            onManualReviewResult?("karşılaştırılacak dikte yok")
            return
        }

        owLog("[Corrections] Manual review — no active snapshot, re-anchoring against the currently focused field")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let element = AXTextAccess.focusedElement() else {
                owLog("[Corrections] Manual review (re-anchored) — no focused AX element")
                Task { @MainActor in self?.onManualReviewResult?("metin okunamadı") }
                return
            }
            let valueResult = AXTextAccess.readString(element, kAXValueAttribute as CFString)
            guard let fieldText = valueResult.value else {
                owLog("[Corrections] Manual review (re-anchored) — value unreadable (\(AXTextAccess.describe(valueResult.error)))")
                Task { @MainActor in self?.onManualReviewResult?("metin okunamadı") }
                return
            }
            Task { @MainActor in
                self?.reviewRetained(pastedText: retained.pastedText, appliedPairs: retained.appliedPairs, fieldText: fieldText)
            }
        }
    }

    /// The no-active-snapshot fallback for `reviewCurrentDifference`. `fieldText` was just read
    /// fresh from whatever is currently focused — it may not even be the same field/app the
    /// original dictation was pasted into, so this requires the retained pasted text's words to
    /// be at least 50% covered by an LCS match against the field's words before diffing at all;
    /// below that it's treated as an unrelated document and nothing is learned.
    private func reviewRetained(pastedText: String, appliedPairs: [(wrong: String, right: String)], fieldText: String) {
        guard fieldText != pastedText else {
            owLog("[Corrections] Manual review (re-anchored) — no change, nothing to learn")
            onManualReviewResult?("değişiklik yok")
            return
        }

        let oldWords = CorrectionEngine.words(pastedText)
        let fieldWords = CorrectionEngine.words(fieldText)
        let coverage: Double
        if oldWords.isEmpty {
            coverage = 0
        } else {
            let matches = CorrectionEngine.lcsMatches(oldWords, fieldWords)
            coverage = Double(matches.count) / Double(oldWords.count)
        }
        owLog("[Corrections] Manual review (re-anchored) — LCS coverage \(String(format: "%.2f", coverage)) of retained text's words")
        guard coverage >= 0.5 else {
            owLog("[Corrections] Manual review (re-anchored) — coverage below 50%, refusing to diff against what looks like an unrelated field")
            onManualReviewResult?("karşılaştırılacak dikte yok")
            return
        }

        let message = processDiff(
            oldSlice: pastedText,
            newSlice: fieldText,
            appliedPairs: appliedPairs,
            manual: true,
            dedupe: false,
            logLabel: "Manual review (re-anchored, no active snapshot)"
        )
        if let message {
            onManualReviewResult?(message)
        }
    }

    private func handleActivation(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if let installedAt, Date().timeIntervalSince(installedAt) < 2.0 { return }
        if current != nil {
            triggerReread(reason: "frontmost app changed", isFinal: true)
        }
    }

    // MARK: - Reread & Diff

    private func triggerReread(reason: String, isFinal: Bool, manual: Bool = false) {
        guard let boxed = current else { return }
        if isFinal {
            clearTimersAndObserver()
            current = nil
            installedAt = nil
            owLog("[Corrections] Reread triggered (\(reason), gen \(boxed.generation)) — final check, closing snapshot")
        } else {
            owLog("[Corrections] Reread triggered (\(reason), gen \(boxed.generation))")
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let valueResult = AXTextAccess.readString(boxed.element, kAXValueAttribute as CFString)
            var newFieldText = valueResult.value

            // GPT/ChatGPT and other Electron/WebKit apps can replace the focused AX text
            // element as soon as the user edits it. The original element then returns
            // kAXErrorInvalidUIElement even though the current composer is readable through
            // a newly-created focused element. Reacquire that replacement before giving up.
            if newFieldText == nil,
               let refreshedElement = AXTextAccess.focusedElement(matchingPID: boxed.pid) {
                let refreshedResult = AXTextAccess.readString(refreshedElement, kAXValueAttribute as CFString)
                newFieldText = refreshedResult.value
                if newFieldText != nil {
                    owLog("[Corrections] Reread reacquired refreshed focused element (gen \(boxed.generation))")
                } else {
                    owLog("[Corrections] Reread refreshed element unreadable (gen \(boxed.generation)) — \(AXTextAccess.describe(refreshedResult.error))")
                }
            }

            guard let newFieldText else {
                owLog("[Corrections] Reread skipped (gen \(boxed.generation)) — element/value unreadable (\(AXTextAccess.describe(valueResult.error)))")
                if manual {
                    Task { @MainActor in self?.onManualReviewResult?("metin okunamadı") }
                }
                return
            }
            Task { @MainActor in
                self?.diffAndLearn(boxed: boxed, newFieldText: newFieldText, reason: reason, manual: manual)
            }
        }
    }

    /// `manual == false` (AXObserver/checkpoint/app-switch/next-dictation): strict path,
    /// UNCHANGED from before — locates the exact pasted span inside the old/new field text via
    /// prefix/suffix matching and bails the instant anything *around* that span also changed.
    /// This byte-identical behavior is a hard requirement; do not touch it.
    ///
    /// `manual == true` (Option+Shift+C, active snapshot): soft-anchored instead of strict —
    /// the ORIGINAL prefix/suffix around the pasted span (from `boxed.fieldTextAtPaste` +
    /// `boxed.pastedRange`, exactly what the strict path already has on hand) is still the
    /// anchor, but `CorrectionEngine.softAnchorRange` only requires the CURRENT field text to
    /// match as much of that prefix/suffix as it still does, trims off whatever still matches,
    /// and diffs `boxed.pastedText` against what's left in between. This relaxes ONLY the
    /// "surrounding text must match exactly" guard — the shape rules in
    /// `substitutionCandidates`, `accept`'s thresholds, and word-boundary safety (a cut can
    /// never land mid-word) are all unchanged. (Verified by dedicated Tools/main.swift tests.)
    private func diffAndLearn(boxed: Boxed, newFieldText: String, reason: String, manual: Bool) {
        let oldField = boxed.fieldTextAtPaste
        guard newFieldText != oldField else {
            owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — no change, nothing to learn")
            if manual { onManualReviewResult?("değişiklik yok") }
            return
        }

        let oldSlice: String
        let newSlice: String

        if manual {
            let prefix = String(decoding: Array(oldField.utf16.prefix(boxed.pastedRange.lowerBound)), as: UTF16.self)
            let suffixStart = boxed.pastedRange.upperBound
            let suffix = String(decoding: Array(oldField.utf16.suffix(oldField.utf16.count - suffixStart)), as: UTF16.self)

            let softRange = CorrectionEngine.softAnchorRange(currentText: newFieldText, originalPrefix: prefix, originalSuffix: suffix)
            guard let trimmedSlice = Self.utf16Substring(newFieldText, softRange) else {
                // softAnchorRange always returns an in-bounds range in practice; stay defensive
                // rather than diffing garbage if that assumption is ever wrong.
                owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — manual soft anchor produced an invalid range, skipping")
                onManualReviewResult?("metin okunamadı")
                return
            }
            oldSlice = boxed.pastedText
            newSlice = trimmedSlice
            owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — manual soft anchor trimmed to |\(String(trimmedSlice.prefix(200)))|")
        } else {
            guard let extractedOldSlice = Self.utf16Substring(oldField, boxed.pastedRange), extractedOldSlice == boxed.pastedText else {
                owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — recorded range no longer matches pasted text, skipping")
                return
            }

            let prefix = String(decoding: Array(oldField.utf16.prefix(boxed.pastedRange.lowerBound)), as: UTF16.self)
            let suffixStart = boxed.pastedRange.upperBound
            let suffix = String(decoding: Array(oldField.utf16.suffix(oldField.utf16.count - suffixStart)), as: UTF16.self)

            guard newFieldText.hasPrefix(prefix), newFieldText.hasSuffix(suffix),
                  newFieldText.utf16.count >= prefix.utf16.count + suffix.utf16.count else {
                owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — surrounding text changed too, skipping")
                return
            }

            // AX ranges are UTF-16 based. Using String.Index offsetBy with `prefix.count` /
            // `suffix.count` breaks as soon as the surrounding text contains a composed emoji
            // or another multi-scalar character, causing the wrong span to be diffed.
            let newSliceStart = prefix.utf16.count
            let newSliceEnd = newFieldText.utf16.count - suffix.utf16.count
            guard newSliceStart >= 0, newSliceEnd >= newSliceStart,
                  let extractedNewSlice = Self.utf16Substring(newFieldText, newSliceStart..<newSliceEnd) else {
                owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — UTF-16 pasted span could not be extracted")
                return
            }
            oldSlice = extractedOldSlice
            newSlice = extractedNewSlice
        }

        guard newSlice != oldSlice else {
            owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — pasted span unchanged, nothing to learn")
            if manual { onManualReviewResult?("değişiklik yok") }
            return
        }

        let message = processDiff(
            oldSlice: oldSlice,
            newSlice: newSlice,
            appliedPairs: boxed.appliedPairs,
            manual: manual,
            dedupe: true,
            logLabel: "Reread (gen \(boxed.generation), \(reason))"
        )
        if manual, let message {
            onManualReviewResult?(message)
        }
    }

    /// Shared by both `diffAndLearn` (active-snapshot path, automatic or manual) and
    /// `reviewRetained` (manual, no active snapshot). Extracts substitution candidates between
    /// `oldSlice`/`newSlice`, excludes reversals of `appliedPairs` (penalizing via
    /// `recordRejection`, same as before), filters every remaining raw candidate through
    /// `CorrectionEngine.acceptWithReason` — logging the reason for every rejection — and
    /// records each accepted root pair: via `CorrectionStore.recordManualObservation` when
    /// `manual` is true, `recordObservation` otherwise (the automatic path's behavior and
    /// call site are unchanged). `dedupe` gates the existing `learnedInCurrentGen` protection —
    /// on for the active-snapshot path (repeated presses/checkpoints on the same generation
    /// must not re-learn the same pair), off for the retained-text fallback (there is no
    /// enclosing generation to dedupe against there).
    ///
    /// Returns the single flow-bar message to show when `manual` is true (always non-nil in
    /// that case), or nil when `manual` is false — the automatic path must never post one.
    @discardableResult
    private func processDiff(
        oldSlice: String,
        newSlice: String,
        appliedPairs: [(wrong: String, right: String)],
        manual: Bool,
        dedupe: Bool,
        logLabel: String
    ) -> String? {
        let truncatedOld = String(oldSlice.prefix(200))
        let truncatedNew = String(newSlice.prefix(200))
        owLog("[Corrections] \(logLabel) — old span: |\(truncatedOld)|, new span: |\(truncatedNew)|")

        let oldWords = CorrectionEngine.words(oldSlice)
        let newWords = CorrectionEngine.words(newSlice)
        let raws = CorrectionEngine.substitutionCandidates(oldWords: oldWords, newWords: newWords)

        // Reversal detection: for each raw candidate, check whether it exactly undoes one of
        // THIS dictation's applied learned pairs — i.e. the diff's (wrong, right) is the applied
        // pair's (right, wrong) reversed. A reversal candidate must NEVER reach
        // `CorrectionStore.recordObservation`/`recordManualObservation`: learning it would create
        // the opposite-direction record (e.g. "commit" -> "komit") that cycles forever against
        // the very pair that just fired ("komit" -> "commit") — exactly how the "commit'"/
        // "komit" poisoned pair was born. Instead the offending record is normally penalized via
        // `recordRejection` — but WHO penalizes and how often is deliberately different per path:
        //
        // - Automatic (manual == false): completely unchanged from before this feature —
        //   `recordRejection` fires once per raw match, deduped only within this single call via
        //   a call-local set (`penalizedThisCall`), exactly as it always did.
        // - Manual, active snapshot (`manual && dedupe`): task 1 made repeated Option+Shift+C
        //   presses on the SAME still-reverted text (the snapshot deliberately stays open now)
        //   the expected workflow. Without a generation-scoped dedupe here, two presses on an
        //   unchanged reversal would call `recordRejection` twice and disable an otherwise-good
        //   record purely because the user checked twice — not because they reverted twice. Uses
        //   `penalizedInCurrentGen`, reset in the same places as `learnedInCurrentGen`.
        // - Manual, no active snapshot (`manual && !dedupe`, the retained-text fallback): there
        //   is no generation to scope a dedupe to, and this path can be invoked repeatedly with
        //   no bound at all — so it excludes the candidate from learning (still correct) but
        //   never calls `recordRejection`. A real, repeated user reversal will still eventually
        //   get penalized the next time an actual dictation snapshot is active.
        var nonReversalRaws: [CorrectionEngine.RawSubstitution] = []
        var penalizedThisCall: Set<String> = []
        for raw in raws {
            owLog("[Corrections] \(logLabel) — raw candidate: '\(raw.wrong)' -> '\(raw.right)'")
            let rawWrongLower = CorrectionEngine.trLower(raw.wrong)
            let rawRightLower = CorrectionEngine.trLower(raw.right)
            if let matchedPair = appliedPairs.first(where: {
                rawWrongLower == CorrectionEngine.trLower($0.right) &&
                rawRightLower == CorrectionEngine.trLower($0.wrong)
            }) {
                let penaltyKey = CorrectionEngine.trLower(matchedPair.wrong)
                owLog("[Corrections] \(logLabel) — REVERSAL detected: user reverted applied correction '\(matchedPair.wrong)' -> '\(matchedPair.right)' back to '\(raw.right)'. Excluding from learning.")
                if manual {
                    if dedupe {
                        if !penalizedInCurrentGen.contains(penaltyKey) {
                            penalizedInCurrentGen.insert(penaltyKey)
                            owLog("[Corrections] \(logLabel) — penalizing record (first time this generation)")
                            CorrectionStore.shared.recordRejection(wrong: matchedPair.wrong)
                        } else {
                            owLog("[Corrections] \(logLabel) — reversal of '\(penaltyKey)' already penalized this generation, not penalizing again")
                        }
                    } else {
                        owLog("[Corrections] \(logLabel) — no active snapshot to scope a penalty dedupe to, excluding without penalizing")
                    }
                } else if !penalizedThisCall.contains(penaltyKey) {
                    penalizedThisCall.insert(penaltyKey)
                    CorrectionStore.shared.recordRejection(wrong: matchedPair.wrong)
                }
                continue
            }
            nonReversalRaws.append(raw)
        }

        var accepted: [CorrectionEngine.Candidate] = []
        for raw in nonReversalRaws {
            let (candidate, reason) = CorrectionEngine.acceptWithReason(raw)
            if let candidate {
                accepted.append(candidate)
            } else {
                owLog("[Corrections] \(logLabel) — rejected '\(raw.wrong)' -> '\(raw.right)': \(reason)")
            }
        }

        guard !accepted.isEmpty else {
            owLog("[Corrections] \(logLabel) — diff found \(raws.count) raw substitution(s) (\(raws.count - nonReversalRaws.count) reversal(s) excluded), 0 accepted")
            return manual ? "uygun düzeltme bulunamadı" : nil
        }

        var newlyLearnedCount = 0
        var learnedPairs: [(wrong: String, right: String)] = []
        var alreadyActivePairs: [(wrong: String, right: String)] = []
        var sawProtected = false
        var sawCycle = false
        var sawDisabled = false

        for candidate in accepted {
            let (rootWrong, rootRight) = CorrectionEngine.extractRoot(wrong: candidate.wrong, right: candidate.right)
            owLog("[Corrections] \(logLabel) — extracted root pair: '\(rootWrong)' -> '\(rootRight)'")
            let dedupeKey = "\(CorrectionEngine.trLower(rootWrong))->\(rootRight)"

            // The generation dedupe exists to stop repeated AUTOMATIC rereads of ONE edit
            // (AXObserver bursts, checkpoint timers, app-switch, next-dictation) from bumping
            // `count` over and over. It must NOT gate a manual press. Live evidence: at
            // 15:31:48 the AXObserver learned 'komitat' -> 'commit at' on its own, so the user's
            // Option+Shift+C at 15:31:53 hit this dedupe and the flow bar reported "uygun
            // düzeltme bulunamadı" — a flat false failure, while the record sat in the store as
            // a mere `.candidate` that a manual press is supposed to promote to `.active`.
            // Letting every manual press through is safe because `recordManualObservation` is
            // idempotent: an unchanged pair returns `.alreadyActive` without touching `count`.
            // The key is still INSERTED on the manual path so a later automatic reread of the
            // same generation doesn't re-observe what the manual press just handled.
            if !manual, dedupe, learnedInCurrentGen.contains(dedupeKey) {
                owLog("[Corrections] Candidate '\(dedupeKey)' already learned in this generation, skipping dedupe")
                continue
            }
            if dedupe { learnedInCurrentGen.insert(dedupeKey) }

            if manual {
                let result = CorrectionStore.shared.recordManualObservation(wrong: rootWrong, right: rootRight)
                switch result {
                case .learned(let wrong, let right):
                    newlyLearnedCount += 1
                    learnedPairs.append((wrong, right))
                case .alreadyActive(let wrong, let right):
                    alreadyActivePairs.append((wrong, right))
                case .rejectedProtectedWord:
                    sawProtected = true
                case .rejectedCycle:
                    sawCycle = true
                case .rejectedDisabledRecord:
                    sawDisabled = true
                case .rejectedLearningOff:
                    break
                }
            } else {
                CorrectionStore.shared.recordObservation(wrong: rootWrong, right: rootRight)
                newlyLearnedCount += 1
            }
        }

        if newlyLearnedCount > 0 {
            owLog("[Corrections] Learned \(newlyLearnedCount) new correction(s) (\(logLabel))")
        } else if !alreadyActivePairs.isEmpty {
            owLog("[Corrections] \(logLabel) — \(alreadyActivePairs.count) candidate(s) were already active, nothing to write")
        } else {
            owLog("[Corrections] \(logLabel) — candidate(s) already learned this generation or rejected, nothing newly learned")
        }

        guard manual else { return nil }

        if newlyLearnedCount == 1, let pair = learnedPairs.first {
            return "öğrenildi: \(pair.wrong) → \(pair.right)"
        } else if newlyLearnedCount > 1 {
            return "\(newlyLearnedCount) düzeltme öğrenildi"
        } else if alreadyActivePairs.count == 1, let pair = alreadyActivePairs.first {
            // Report the truth rather than a failure: the pair IS active, this press just had
            // nothing left to write (usually because the automatic AXObserver path got there
            // first, or because the user pressed twice).
            return "zaten aktif: \(pair.wrong) → \(pair.right)"
        } else if alreadyActivePairs.count > 1 {
            return "\(alreadyActivePairs.count) düzeltme zaten aktif"
        } else if sawProtected {
            return "korumalı kelime, öğrenilmedi"
        } else if sawCycle {
            return "döngü riski, öğrenilmedi"
        } else if sawDisabled {
            return "bu düzeltme kapatılmış"
        } else {
            return "uygun düzeltme bulunamadı"
        }
    }

    private func clearTimersAndObserver() {
        observerDebounceTimer?.invalidate()
        observerDebounceTimer = nil
        for timer in checkpointTimers {
            timer.invalidate()
        }
        checkpointTimers.removeAll()
        removeAXObserver()
    }

    private func clear() {
        clearTimersAndObserver()
        current = nil
        installedAt = nil
        learnedInCurrentGen.removeAll()
        penalizedInCurrentGen.removeAll()
    }

    // MARK: - UTF-16 helpers

    private nonisolated static func utf16Substring(_ text: String, _ range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= text.utf16.count else { return nil }
        return utf16Slice(text, range)
    }

    private nonisolated static func utf16Slice(_ text: String, _ range: Range<Int>) -> String {
        let utf16View = text.utf16
        guard let startUTF16 = utf16View.index(utf16View.startIndex, offsetBy: range.lowerBound, limitedBy: utf16View.endIndex),
              let endUTF16 = utf16View.index(utf16View.startIndex, offsetBy: range.upperBound, limitedBy: utf16View.endIndex),
              let start = String.Index(startUTF16, within: text),
              let end = String.Index(endUTF16, within: text) else {
            return ""
        }
        return String(text[start..<end])
    }
}
