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

        init(element: AXUIElement, pid: pid_t, bundleID: String?, pastedRange: Range<Int>,
             fieldTextAtPaste: String, pastedText: String, generation: Int) {
            self.element = element
            self.pid = pid
            self.bundleID = bundleID
            self.pastedRange = pastedRange
            self.fieldTextAtPaste = fieldTextAtPaste
            self.pastedText = pastedText
            self.generation = generation
        }
    }

    private var current: Boxed?
    private var generationCounter = 0
    private var checkpointTimers: [Timer] = []
    private var axObserver: AXObserver?
    private var axObserverElement: AXUIElement?
    private var installedAt: Date?
    private var activationObserver: NSObjectProtocol?
    private var suppressNextCapture = false

    /// Keys (`wrongRoot->rightRoot`) learned during the CURRENT snapshot generation, preventing
    /// multiple checkpoint rereads from recording the same edit more than once per dictation.
    private var learnedInCurrentGen: Set<String> = []

    /// Configured checkpoint intervals (seconds). Default: 1..30
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
        let stored = UserDefaults.standard.string(forKey: "correctionCheckpoints") ?? CorrectionEngine.defaultCheckpointsString
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
    func capture(pastedText: String, targetApp: NSRunningApplication?) {
        guard CorrectionStore.shared.learningEnabled else { return }
        generationCounter += 1
        let generation = generationCounter
        let pid = targetApp?.processIdentifier ?? 0
        let bundleID = targetApp?.bundleIdentifier

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let element = AXTextAccess.focusedElement() else {
                owLog("[Corrections] Snapshot skipped (gen \(generation)) — no focused AX element")
                return
            }
            let valueResult = AXTextAccess.readString(element, kAXValueAttribute as CFString)
            guard let fieldText = valueResult.value else {
                owLog("[Corrections] Snapshot skipped (gen \(generation)) — value unreadable (\(AXTextAccess.describe(valueResult.error)))")
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
                return
            }

            let boxed = Boxed(
                element: element,
                pid: pid,
                bundleID: bundleID,
                pastedRange: finalRange,
                fieldTextAtPaste: fieldText,
                pastedText: pastedText,
                generation: generation
            )

            Task { @MainActor in
                self?.install(boxed)
            }
        }
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

        // Attempt instant AXObserver setup
        let observerActive = setupAXObserver(pid: boxed.pid, element: boxed.element)

        // Schedule safety-net checkpoint timers
        let intervals = checkpointIntervals
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

    private func handleAXObserverEvent() {
        guard let boxed = current else { return }
        owLog("[Corrections] AXObserver value change detected (gen \(boxed.generation))")
        triggerReread(reason: "AXObserver event", isFinal: false)
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
    /// contents of the same field. This is the manual shortcut path for cases where the
    /// user has finished editing and does not want to wait for a checkpoint or app switch.
    func reviewCurrentDifference() {
        guard current != nil else {
            owLog("[Corrections] Manual review skipped — no active pasted-text snapshot")
            return
        }
        triggerReread(reason: "manual correction shortcut", isFinal: true)
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

    private func triggerReread(reason: String, isFinal: Bool) {
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
                return
            }
            Task { @MainActor in
                self?.diffAndLearn(boxed: boxed, newFieldText: newFieldText, reason: reason)
            }
        }
    }

    private func diffAndLearn(boxed: Boxed, newFieldText: String, reason: String) {
        let oldField = boxed.fieldTextAtPaste
        guard newFieldText != oldField else {
            owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — no change, nothing to learn")
            return
        }

        guard let oldSlice = Self.utf16Substring(oldField, boxed.pastedRange), oldSlice == boxed.pastedText else {
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
              let newSlice = Self.utf16Substring(newFieldText, newSliceStart..<newSliceEnd) else {
            owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — UTF-16 pasted span could not be extracted")
            return
        }

        guard newSlice != oldSlice else {
            owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — pasted span unchanged, nothing to learn")
            return
        }

        let oldWords = CorrectionEngine.words(oldSlice)
        let newWords = CorrectionEngine.words(newSlice)
        let raws = CorrectionEngine.substitutionCandidates(oldWords: oldWords, newWords: newWords)
        let accepted = raws.compactMap(CorrectionEngine.accept)

        guard !accepted.isEmpty else {
            owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — diff found \(raws.count) raw substitution(s), 0 accepted")
            return
        }

        var newlyLearnedCount = 0
        for candidate in accepted {
            let (rootWrong, rootRight) = CorrectionEngine.extractRoot(wrong: candidate.wrong, right: candidate.right)
            let dedupeKey = "\(CorrectionEngine.trLower(rootWrong))->\(rootRight)"

            if learnedInCurrentGen.contains(dedupeKey) {
                owLog("[Corrections] Candidate '\(dedupeKey)' already learned in gen \(boxed.generation), skipping dedupe")
                continue
            }

            learnedInCurrentGen.insert(dedupeKey)
            CorrectionStore.shared.recordObservation(wrong: rootWrong, right: rootRight)
            newlyLearnedCount += 1
        }

        if newlyLearnedCount > 0 {
            owLog("[Corrections] Learned \(newlyLearnedCount) new correction(s) from manual edit (gen \(boxed.generation), \(reason))")
        } else {
            owLog("[Corrections] Reread (gen \(boxed.generation), \(reason)) — candidate(s) already learned in this generation")
        }
    }

    private func clearTimersAndObserver() {
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
