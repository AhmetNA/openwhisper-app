import AppKit
import CoreGraphics
import ApplicationServices

enum ClipboardOnlyReason: Equatable {
    case emptyText
    case clipboardWriteFailed
    case targetApplicationUnavailable
    case targetApplicationTerminated
    case targetApplicationChanged
    case accessibilityUnavailable
    case activationTimedOut
    case noSafeEditableDestination
    case pasteEventUnavailable
}

enum PasteOutcome: Equatable {
    case pastedVerified
    case pastedUnverified
    case clipboardOnly(ClipboardOnlyReason)
}

/// Seam allowing `AppState` to swap in a fake for tests -- without it, exercising any paste
/// path in a test would post real CGEvent keystrokes and try to activate whatever app happens
/// to be frontmost in the test runner. Not `Sendable`: every call in this app happens on the
/// main actor (from `AppState`), so there's no need to widen the contract.
protocol TextInjecting: AnyObject {
    func copyToClipboard(_ text: String)
    func pasteText(_ text: String, targetApp: NSRunningApplication?, onPasted: (() -> Void)?)
    func replaceInjectedText(
        oldText: String,
        newText: String,
        targetApp: NSRunningApplication?,
        onReplaced: (() -> Void)?
    )

    /// Result-bearing API for new integrations.  The default adapter keeps existing fakes and
    /// older integrations source-compatible: they receive the legacy completion callback and
    /// are reported as unverified because the fake cannot provide AX proof.
    /// Integration sequence: capture `let context = PasteContext.capture(targetApp: app)` at
    /// recording start, then call `pasteTextResult(text, targetApp: app, context: context)`.
    /// Handle `pastedVerified` and `pastedUnverified` as delivered output; for
    /// `clipboardOnly(reason)`, leave the clipboard payload visible and do not claim that text
    /// reached the target or overwrite it with a backup copy.
    func pasteTextResult(
        _ text: String,
        targetApp: NSRunningApplication?,
        context: PasteContext?,
        onOutcome: ((PasteOutcome) -> Void)?
    )
}

extension TextInjecting {
    func pasteTextResult(
        _ text: String,
        targetApp: NSRunningApplication? = nil,
        context: PasteContext? = nil,
        onOutcome: ((PasteOutcome) -> Void)? = nil
    ) {
        pasteText(text, targetApp: targetApp) {
            onOutcome?(.pastedUnverified)
        }
    }
}

final class TextInjector: TextInjecting, @unchecked Sendable {

    /// Copy text to the system clipboard.
    func copyToClipboard(_ text: String) {
        _ = writeToClipboard(text)
    }

    /// Legacy source-compatible entry point.  New integration code should capture a
    /// `PasteContext` at recording start and call `pasteTextResult` so it can distinguish a
    /// verified paste from a clipboard-only fallback.
    func pasteText(
        _ text: String,
        targetApp: NSRunningApplication? = nil,
        onPasted: (() -> Void)? = nil
    ) {
        let cleaned = cleanedText(text)
        guard !cleaned.isEmpty else {
            owLog("[TextInjector] Skipping empty/junk text: \(cleaned)")
            return
        }

        let context = PasteContext.capture(targetApp: targetApp)
        pasteTextResult(cleaned, targetApp: targetApp, context: context) { outcome in
            owLog("[TextInjector] Legacy paste completed: \(outcome.logDescription)")
            // A clipboard-only fallback must remain the exact payload.  Older callers use
            // `onPasted` to overwrite the clipboard with a backup copy, so do not signal that
            // callback when no Cmd+V was sent.
            if case .clipboardOnly = outcome {
                return
            }
            onPasted?()
        }
    }

    /// Deliver text only after proving that the captured target is still the intended process
    /// and that an editable destination can be focused in that process.
    func pasteTextResult(
        _ text: String,
        targetApp: NSRunningApplication? = nil,
        context: PasteContext? = nil,
        onOutcome: ((PasteOutcome) -> Void)? = nil
    ) {
        let cleaned = cleanedText(text)
        guard !cleaned.isEmpty else {
            complete(.clipboardOnly(.emptyText), onOutcome: onOutcome)
            return
        }

        owLog("[TextInjector] Starting paste (\(cleaned.count) chars)")
        guard writeToClipboard(cleaned) else {
            complete(.clipboardOnly(.clipboardWriteFailed), onOutcome: onOutcome)
            return
        }

        let captured = context ?? PasteContext.capture(targetApp: targetApp)
        resolveDestination(captured) { [weak self] resolution in
            guard let self else { return }
            switch resolution {
            case .failed(let outcome):
                self.complete(outcome, onOutcome: onOutcome)
            case .ready(let destination):
                self.sendPaste(
                    cleaned,
                    context: captured,
                    destination: destination,
                    retryCount: 0,
                    onOutcome: onOutcome
                )
            }
        }
    }

    /// Replace text previously injected at the cursor with a different version: deletes
    /// `oldText` via one Backspace CGEvent per Unicode character, then pastes `newText` through
    /// the same target-safe delivery path.  Target resolution happens before any Backspace is
    /// posted, so a closed or unfocusable target cannot cause deletion in another app.
    func replaceInjectedText(
        oldText: String,
        newText: String,
        targetApp: NSRunningApplication?,
        onReplaced: (() -> Void)? = nil
    ) {
        let cleaned = cleanedText(newText)
        guard !cleaned.isEmpty else {
            onReplaced?()
            return
        }

        let context = PasteContext.capture(targetApp: targetApp)
        resolveDestination(context) { [weak self] resolution in
            guard let self else { return }
            switch resolution {
            case .failed:
                // Keep the exact replacement available without sending deletion to a wrong
                // process.  The legacy callback still fires so swap state cannot remain stuck.
                self.copyToClipboard(cleaned)
                onReplaced?()
            case .ready:
                let charCount = oldText.count
                owLog("[TextInjector] Swap: deleting \(charCount) chars, injecting \(cleaned.count) chars")

                // Brief pause for the already-resolved target to retain focus before we send
                // the backspace burst off the main thread.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self else { return }
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self else { return }
                        self.sendBackspaces(count: charCount)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            // The deletion changed the AX baseline.  Capture it again before
                            // sending the replacement so verification cannot mistake the
                            // backspaces for a successful paste.
                            let latestContext = PasteContext.capture(targetApp: targetApp)
                            self.pasteTextResult(
                                cleaned,
                                targetApp: targetApp,
                                context: latestContext
                            ) { _ in
                                onReplaced?()
                            }
                        }
                    }
                }
            }
        }
    }

    private struct PasteDestination {
        let element: AXUIElement
        let pid: pid_t
    }

    private enum DestinationResolution {
        case ready(PasteDestination)
        case failed(PasteOutcome)
    }

    private enum Verification {
        case verified
        case unchanged
        case unverified
    }

    private let backspaceKeyCode: CGKeyCode = 51

    private func cleanedText(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("[BLANK") || cleaned.hasPrefix("(BLANK") {
            return ""
        }
        return cleaned
    }

    private func writeToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func resolveDestination(
        _ context: PasteContext,
        completion: @escaping (DestinationResolution) -> Void
    ) {
        guard let pid = context.targetPID, pid > 0 else {
            completion(.failed(.clipboardOnly(.targetApplicationUnavailable)))
            return
        }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            completion(.failed(.clipboardOnly(.targetApplicationTerminated)))
            return
        }
        if let expectedBundle = context.bundleIdentifier,
           app.bundleIdentifier != expectedBundle {
            completion(.failed(.clipboardOnly(.targetApplicationChanged)))
            return
        }
        guard AXIsProcessTrusted() else {
            completion(.failed(.clipboardOnly(.accessibilityUnavailable)))
            return
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if frontmostPID != pid {
            owLog("[TextInjector] Activating captured target: \(context.applicationName ?? "?") (pid \(pid))")
            app.activate(options: [.activateIgnoringOtherApps])
        }
        waitForFrontmost(pid: pid, app: app, deadline: Date().addingTimeInterval(0.5)) { [weak self] ready in
            guard let self else { return }
            guard ready else {
                let reason: ClipboardOnlyReason = app.isTerminated
                    ? .targetApplicationTerminated
                    : .activationTimedOut
                completion(.failed(.clipboardOnly(reason)))
                return
            }

            if let capturedElement = context.focusedElement,
               AXTextAccess.isSafeEditableElement(capturedElement, matchingPID: pid),
               AXTextAccess.focus(capturedElement, matchingPID: pid) {
                completion(.ready(PasteDestination(element: capturedElement, pid: pid)))
                return
            }

            guard let currentElement = AXTextAccess.focusedEditableElement(matchingPID: pid) else {
                completion(.failed(.clipboardOnly(.noSafeEditableDestination)))
                return
            }
            // The current focused element was obtained with a matching PID, and focus is
            // rechecked before delivery to avoid a late focus change crossing process bounds.
            guard AXTextAccess.focus(currentElement, matchingPID: pid) else {
                completion(.failed(.clipboardOnly(.noSafeEditableDestination)))
                return
            }
            completion(.ready(PasteDestination(element: currentElement, pid: pid)))
        }
    }

    private func waitForFrontmost(
        pid: pid_t,
        app: NSRunningApplication,
        deadline: Date,
        completion: @escaping (Bool) -> Void
    ) {
        if app.isTerminated {
            completion(false)
            return
        }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            completion(true)
            return
        }
        guard Date() < deadline else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.waitForFrontmost(pid: pid, app: app, deadline: deadline, completion: completion)
        }
    }

    private func sendPaste(
        _ text: String,
        context: PasteContext,
        destination: PasteDestination,
        retryCount: Int,
        onOutcome: ((PasteOutcome) -> Void)?
    ) {
        // The user may have switched apps during the bounded AX/focus preparation interval.
        // Re-check immediately before posting the event; clipboard fallback is safer than
        // sending Cmd+V to whatever became frontmost in the meantime.
        guard let target = NSRunningApplication(processIdentifier: destination.pid),
              !target.isTerminated else {
            complete(.clipboardOnly(.targetApplicationTerminated), onOutcome: onOutcome)
            return
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == destination.pid else {
            complete(.clipboardOnly(.activationTimedOut), onOutcome: onOutcome)
            return
        }
        guard simulateCmdV() else {
            complete(.clipboardOnly(.pasteEventUnavailable), onOutcome: onOutcome)
            return
        }

        // Give the target a short, bounded interval to process Cmd+V before reading AX state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            let state = AXTextAccess.readTextState(destination.element)
            switch self.verify(state: state, against: context, pastedText: text) {
            case .verified:
                self.complete(.pastedVerified, onOutcome: onOutcome)
            case .unverified:
                // AX-unreadable destinations (including terminals) are sent exactly once.
                self.complete(.pastedUnverified, onOutcome: onOutcome)
            case .unchanged:
                guard retryCount == 0,
                      AXTextAccess.focus(destination.element, matchingPID: destination.pid) else {
                    self.complete(.pastedUnverified, onOutcome: onOutcome)
                    return
                }
                owLog("[TextInjector] AX field unchanged after paste; refocusing and retrying once")
                self.sendPaste(
                    text,
                    context: context,
                    destination: destination,
                    retryCount: retryCount + 1,
                    onOutcome: onOutcome
                )
            }
        }
    }

    private func verify(
        state: AXTextAccess.TextState,
        against context: PasteContext,
        pastedText: String
    ) -> Verification {
        guard let beforeValue = context.valueAtCapture, let afterValue = state.value else {
            return .unverified
        }

        if beforeValue != afterValue {
            return .verified
        }

        // Pasting the same text over a selection leaves value unchanged but collapses/moves
        // the selection.  That is a definitive success and must not trigger a duplicate paste.
        if let beforeRange = context.selectedRangeAtCapture,
           let afterRange = state.selectedRange,
           !sameRange(beforeRange, afterRange) {
            return .verified
        }

        // If both value and readable selection are unchanged, the first event was definitively
        // ignored.  This is the only case eligible for the single safe retry.
        if let beforeRange = context.selectedRangeAtCapture,
           let afterRange = state.selectedRange,
           sameRange(beforeRange, afterRange) {
            return .unchanged
        }

        // A readable value with an unsupported selection attribute is not definitive enough to
        // retry: the paste may have happened in a destination that cannot expose its range.
        _ = pastedText
        return .unverified
    }

    private func sameRange(_ lhs: CFRange, _ rhs: CFRange) -> Bool {
        lhs.location == rhs.location && lhs.length == rhs.length
    }

    private func complete(_ outcome: PasteOutcome, onOutcome: ((PasteOutcome) -> Void)?) {
        onOutcome?(outcome)
    }

    private func sendBackspaces(count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: false) else {
                continue
            }
            // Explicitly clear flags: a freshly-created CGEvent otherwise picks up whatever
            // modifier keys are physically down right now, and Fn+Delete is Forward Delete on
            // macOS -- the opposite of what we want.
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(1_000)
        }
    }

    /// Simulate Cmd+V via CGEvent.  The caller checks the boolean before reporting a result;
    /// clipboard content is never inferred to indicate whether this event was consumed.
    private func simulateCmdV() -> Bool {
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else {
            owLog("[TextInjector] CGEvent creation failed!")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        usleep(80_000)
        keyUp.post(tap: .cghidEventTap)
        owLog("[TextInjector] CGEvent Cmd+V posted")
        return true
    }
}

private extension PasteOutcome {
    var logDescription: String {
        switch self {
        case .pastedVerified:
            return "pastedVerified"
        case .pastedUnverified:
            return "pastedUnverified"
        case .clipboardOnly(let reason):
            return "clipboardOnly(\(reason))"
        }
    }
}
