import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    /// Fired whenever Option+Z is pressed. Deletes the currently injected text at the cursor
    /// and replaces it with the other (Ollama öncesi raw ↔ Ollama sonrası cleaned) version.
    /// Repeatable toggle — each call erases the current text and pastes the alternate version.
    func commitSwap() {
        guard let pair = swapPair, !isSwapping else { return }
        isSwapping = true

        // The raw<->cleaned toggle is not a user "correction" — it's our own swap — so any
        // pending snapshot for the text about to be replaced must be dropped, not diffed.
        DictationSnapshot.shared.invalidateForSwap()

        let newIsCleaned = !lastInjectedIsCleaned
        let newText = newIsCleaned ? pair.cleaned : pair.raw
        let oldText = lastInjectedText
        let backupText = newIsCleaned ? pair.raw : pair.cleaned

        textInjector?.replaceInjectedText(
            oldText: oldText,
            newText: newText,
            targetApp: swapTargetApp,
            context: swapPasteContext
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.swapPasteContext = self.swapPasteContext?.contextAfterReplacingInjectedText(with: newText)
                self.textInjector?.copyToClipboard(backupText)
                self.isSwapping = false
            }
        }

        lastInjectedIsCleaned = newIsCleaned
        lastInjectedText = newText
        owLog("[OpenWhisper] Swap committed — toggle to \(newIsCleaned ? "Ollama sonrası (cleaned)" : "Ollama öncesi (raw)") text")
    }
}
