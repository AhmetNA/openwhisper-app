import AppKit
import ApplicationServices

extension AppState {
    /// The last dictation, while a spoken edit may still change it: pasted into `targetApp`.
    func editableDictation(in targetApp: NSRunningApplication?) -> String? {
        guard !lastInjectedText.isEmpty, let targetApp,
              swapTargetApp?.processIdentifier == targetApp.processIdentifier else { return nil }
        return lastInjectedText
    }

    /// Runs "sil", "son kelimeyi sil", "Ahmed'i Ahmet yap" or "enter'a bas". Only in the app in
    /// front, and only when the caret still sits right after the pasted text: an edit said a
    /// minute later, after the user typed or clicked elsewhere, must not erase their own text.
    /// Returns what happened, for the Flow bar.
    func runDictationEdit(_ edit: DictationEdit, targetApp: NSRunningApplication?) async -> (status: String, done: Bool) {
        guard let injector = textInjector as? TextInjector else { return ("Yapılamadı", false) }
        guard let targetApp, !targetApp.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp.processIdentifier else {
            owLog("[DictationEdit] \(edit): the target app is no longer in front")
            return ("Yazdığım uygulama önde değil", false)
        }
        if edit == .pressReturn {
            let pressed = injector.pressReturn(inPID: targetApp.processIdentifier)
            return pressed ? ("Enter", true) : ("Enter'a basılamadı", false)
        }

        guard let dictation = editableDictation(in: targetApp) else {
            return ("Düzeltecek bir yazı yok", false)
        }
        guard let edited = edit.applied(to: dictation) else {
            owLog("[DictationEdit] \(edit) changes nothing in '\(dictation)'")
            return ("Değişecek bir şey yok", false)
        }
        guard caretFollows(dictation, in: targetApp) else {
            return ("Son yazdığım yerinde değil; dokunmadım", false)
        }

        // A voice edit is not a correction the user typed: don't learn from it. Option+Z's
        // raw/cleaned pair no longer matches the field, and a pending cleanup must not
        // replace the old text (it checks `lastInjectedText`).
        DictationSnapshot.shared.invalidateForSwap()
        swapPair = nil
        swapPasteContext = nil
        hotkey?.setSwapAvailable(false)
        lastInjectedText = edited

        if dictation.hasPrefix(edited) {
            let tail = String(dictation.dropFirst(edited.count))
            owLog("[DictationEdit] \(edit): deleting '\(tail)'")
            let deleted = await withCheckedContinuation { continuation in
                injector.deleteInjectedText(tail, targetApp: targetApp, context: nil) { continuation.resume(returning: $0) }
            }
            guard deleted else {
                lastInjectedText = ""
                return ("Silinemedi", false)
            }
            return ("Silindi", true)
        }
        owLog("[DictationEdit] \(edit): '\(dictation)' → '\(edited)'")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            injector.replaceInjectedText(oldText: dictation, newText: edited, targetApp: targetApp, context: nil) {
                continuation.resume()
            }
        }
        return ("Düzeltildi", true)
    }

    /// Whether the focused field's text right before the caret is `dictation`, with nothing
    /// selected. A field AX can't read (some web and Electron editors) is trusted, as Option+Z does.
    private func caretFollows(_ dictation: String, in targetApp: NSRunningApplication) -> Bool {
        guard let element = AXTextAccess.focusedEditableElement(matchingPID: targetApp.processIdentifier) else {
            owLog("[DictationEdit] No editable field in front")
            return false
        }
        let state = AXTextAccess.readTextState(element)
        guard let value = state.value, let range = state.selectedRange else {
            owLog("[DictationEdit] Field unreadable; trusting the caret")
            return true
        }
        guard range.length == 0, range.location >= 0, range.location <= value.utf16.count,
              let beforeCaret = String(value.utf16.prefix(range.location)),
              beforeCaret.hasSuffix(dictation) else {
            owLog("[DictationEdit] The caret is not right after the last dictation; not editing")
            return false
        }
        return true
    }
}
