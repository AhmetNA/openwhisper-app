import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    /// The flow bar is invisible while idle and only appears for the duration of an active
    /// dictation (recording through transcribing/pasting), so the app runs invisibly in the
    /// background otherwise — the menu bar icon remains the only always-visible element.
    func syncFlowBarVisibility() {
        // Keep a reachable finish control onscreen while the system output is being heard,
        // even if the normal microphone flow bar is disabled in Settings.
        if systemAudioEnabled {
            flowBarController?.show()
            return
        }
        guard flowBarEnabled else {
            flowBarController?.hide()
            return
        }
        if recordingState == .idle && flowBarMessage == nil && microphoneFlowNotice == nil && jarvisActivity == .none {
            flowBarController?.hide()
        } else {
            flowBarController?.show()
        }
    }

    func showFlowBarMessage(_ message: String, durationMs: Int = 1500) {
        flowBarMessageTask?.cancel()
        flowBarMessage = message
        syncFlowBarVisibility()
        flowBarMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(durationMs))
            guard !Task.isCancelled, let self else { return }
            self.flowBarMessage = nil
            self.syncFlowBarVisibility()
        }
    }

    /// Removes a transient flow-bar message without leaving the bar visible after a successful
    /// paste. Successful delivery is intentionally silent; only actionable outcomes remain.
    func dismissFlowBarMessage() {
        flowBarMessageTask?.cancel()
        flowBarMessageTask = nil
        flowBarMessage = nil
        syncFlowBarVisibility()
    }

    func clearFlowBarMessage() {
        flowBarMessageTask?.cancel()
        flowBarMessageTask = nil
        confirmationOperationID &+= 1
        isConfirmationInFlight = false
        confirmationPasteOutcome = nil
        confirmationPasteCompleted = false
        confirmationAppendCompleted = false
        confirmationAppendSucceeded = false
        confirmationAppendError = nil
        confirmationTextBeingDelivered = ""
        dismissTargetSpeakerAppendOffer()
        if flowBarMessage != nil {
            flowBarMessage = nil
            syncFlowBarVisibility()
        }
    }

    func clipboardOnlyMessage(for reason: ClipboardOnlyReason) -> String {
        switch reason {
        case .accessibilityUnavailable:
            return "Yapıştırılamadı — erişim izni gerekli (metin panoda)"
        case .targetApplicationUnavailable, .targetApplicationTerminated, .targetApplicationChanged:
            return "Yapıştırılamadı — hedef uygulama kullanılamıyor (metin panoda)"
        case .noSafeEditableDestination:
            return "Yapıştırılamadı — düzenlenebilir alan bulunamadı (metin panoda)"
        case .targetFieldChanged:
            return "Yapıştırılamadı — hedef alan değişmiş (metin panoda)"
        case .activationTimedOut:
            return "Yapıştırılamadı — hedef uygulama etkinleştirilemedi (metin panoda)"
        case .clipboardWriteFailed:
            return "Yapıştırılamadı — pano yazılamadı"
        case .emptyText:
            return "Yapıştırılamadı — metin yok"
        case .pasteEventUnavailable:
            return "Yapıştırılamadı — metin panoda"
        }
    }
}
