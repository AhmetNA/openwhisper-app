import AppKit
import CoreGraphics
import ApplicationServices

final class TextInjector: @unchecked Sendable {

    /// Copy text to the system clipboard
    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Paste text into the target app.
    /// - Parameter onPasted: called once the paste sequence (and its post-paste clipboard
    ///   sanity check) has finished. Callers use this to know it's now safe to overwrite the
    ///   clipboard with a backup copy without racing the Cmd+V itself.
    func pasteText(_ text: String, targetApp: NSRunningApplication? = nil, onPasted: (() -> Void)? = nil) {
        // Filter junk
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.hasPrefix("[BLANK") {
            owLog("[TextInjector] Skipping empty/junk text: \(cleaned)")
            return
        }

        owLog("[TextInjector] Starting paste (\(cleaned.count) chars)")

        // Always put text on clipboard first
        copyToClipboard(cleaned)

        // Activate the target app
        if let app = targetApp {
            owLog("[TextInjector] Activating: \(app.localizedName ?? "?") (pid \(app.processIdentifier))")
            app.activate()
        }

        // Wait for app to come to front, then paste via CGEvent
        let delay: TimeInterval = 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            // Log what's actually frontmost right now
            let frontmost = NSWorkspace.shared.frontmostApplication
            owLog("[TextInjector] Frontmost at paste time: \(frontmost?.localizedName ?? "none") (pid \(frontmost?.processIdentifier ?? 0))")
            owLog("[TextInjector] AXIsProcessTrusted: \(AXIsProcessTrusted())")

            // Method 1: CGEvent Cmd+V (works in terminals, editors, everywhere IF accessibility is granted)
            owLog("[TextInjector] Posting CGEvent Cmd+V...")
            self.simulateCmdV()

            // Method 2: After a short delay, also try AXUIElement for apps where CGEvent fails
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Check if clipboard still has our text (if it does, paste probably didn't work)
                let clipText = NSPasteboard.general.string(forType: .string)
                owLog("[TextInjector] Post-paste clipboard check: \(clipText == cleaned ? "unchanged (paste may have failed)" : "changed (paste likely worked)")")
                onPasted?()
            }
        }
    }

    /// Replace text previously injected at the cursor with a different version: deletes
    /// `oldText` via one Backspace CGEvent per Unicode character (composed grapheme cluster —
    /// `String.count`, so combined/multi-scalar characters count as one backspace each), then
    /// pastes `newText` through the same clipboard + Cmd+V path as `pasteText`.
    ///
    /// Backspace was chosen over select-backwards-then-paste (e.g. Shift+Left repeated, then
    /// paste-over-selection): plain Backspace is honored identically by terminals, code editors,
    /// and AX-unfriendly apps, whereas Shift+arrow selection semantics vary across apps (some
    /// don't extend a selection the way we'd expect, some treat repeated Shift+Left as
    /// word-based once modifiers double-fire) and a failed/partial selection would either leave
    /// stray characters behind or, worse, get overwritten incorrectly by the paste. Backspace
    /// has no such ambiguity: N keystrokes always remove exactly N characters immediately to the
    /// left of the caret.
    ///
    /// - Parameter onReplaced: called after the paste sequence completes, same timing guarantee
    ///   as `pasteText`'s `onPasted`.
    func replaceInjectedText(
        oldText: String,
        newText: String,
        targetApp: NSRunningApplication?,
        onReplaced: (() -> Void)? = nil
    ) {
        let charCount = oldText.count
        owLog("[TextInjector] Swap: deleting \(charCount) chars, injecting \(newText.count) chars")

        if let app = targetApp {
            app.activate()
        }

        // Brief pause for the app to (re)gain focus before we send keystrokes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            // Post the backspace burst off the main thread so a long transcript (hundreds of
            // characters) can't block the main run loop — which is also where our CGEventTap
            // lives, risking a macOS-forced tap disable (tapDisabledByTimeout) if it stalls.
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.sendBackspaces(count: charCount)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                    self.pasteText(newText, targetApp: nil, onPasted: onReplaced)
                }
            }
        }
    }

    private let backspaceKeyCode: CGKeyCode = 51

    private func sendBackspaces(count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: backspaceKeyCode, keyDown: false) else {
                continue
            }
            // Explicitly clear flags: a freshly-created CGEvent otherwise picks up whatever
            // modifier keys are physically down right now, and Fn+Delete is Forward Delete on
            // macOS — the opposite of what we want. Same reasoning as simulateCmdV pinning
            // .maskCommand below instead of leaving flags to chance.
            keyDown.flags = []
            keyUp.flags = []
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            usleep(1_000)
        }
    }

    /// Simulate Cmd+V via CGEvent
    private func simulateCmdV() {
        let vKeyCode: CGKeyCode = 9

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else {
            owLog("[TextInjector] CGEvent creation failed!")
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        usleep(80_000)
        keyUp.post(tap: .cghidEventTap)
        owLog("[TextInjector] CGEvent Cmd+V posted")
    }
}
