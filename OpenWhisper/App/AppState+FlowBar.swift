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
        if recordingState == .idle {
            caretPenRect = nil
            caretFieldRect = nil
            caretPenSessionID = nil
            caretPenDuration = 0
            caretLookupPending = false
            followUpLiveText = nil
        }
        flowBarController?.fieldRect = caretFieldRect
        flowBarController?.caretRect = systemAudioEnabled ? nil : caretPenRect
        // Wait briefly for the destination before the first display, avoiding a bottom-to-caret jump.
        if caretLookupPending, flowBarEnabled, !systemAudioEnabled, shownRecordingState != .idle {
            caretPenController?.hide()
            flowBarController?.hide()
            return
        }
        // A dictation being processed is drawn at its caret instead, when the app said where.
        if shownRecordingState == .transcribing, let caretPenRect, flowBarEnabled, !systemAudioEnabled, flowBarMessage == nil, microphoneFlowNotice == nil,
           jarvisActivity == .none, !targetSpeakerAppendOfferActive,
           caretPenController?.show(at: caretPenRect, duration: caretPenDuration, field: caretFieldRect) == true {
            flowBarController?.hide()
            return
        }
        caretPenController?.hide()
        // Keep a reachable finish control and the outcome onscreen for the system output,
        // even if the normal microphone flow bar is disabled in Settings.
        if systemAudioEnabled || showsSystemAudioBar {
            flowBarController?.show()
            return
        }
        guard flowBarEnabled else {
            flowBarController?.hide()
            return
        }
        if shownRecordingState == .idle && flowBarMessage == nil && microphoneFlowNotice == nil && jarvisActivity == .none {
            flowBarController?.hide()
        } else {
            flowBarController?.show()
        }
    }

    func showFlowBarMessage(_ message: String, durationMs: Int = 1500) {
        flowBarMessageTask?.cancel()
        // Jarvis's acks are kept in Turkish for the voice's table; shown, they are English too.
        flowBarMessage = CommandLanguage.isEnglish ? ReplyTranslator.fixedEnglish(message) ?? message : message
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
            return L("Yapıştırılamadı — erişim izni gerekli (metin panoda)", "Couldn't paste — Accessibility permission needed (text on the clipboard)")
        case .targetApplicationUnavailable, .targetApplicationTerminated, .targetApplicationChanged:
            return L("Yapıştırılamadı — hedef uygulama kullanılamıyor (metin panoda)", "Couldn't paste — the target app is unavailable (text on the clipboard)")
        case .noSafeEditableDestination:
            return L("Yapıştırılamadı — düzenlenebilir alan bulunamadı (metin panoda)", "Couldn't paste — no editable field found (text on the clipboard)")
        case .targetFieldChanged:
            return L("Yapıştırılamadı — hedef alan değişmiş (metin panoda)", "Couldn't paste — the target field changed (text on the clipboard)")
        case .activationTimedOut:
            return L("Yapıştırılamadı — hedef uygulama etkinleştirilemedi (metin panoda)", "Couldn't paste — couldn't activate the target app (text on the clipboard)")
        case .clipboardWriteFailed:
            return L("Yapıştırılamadı — pano yazılamadı", "Couldn't paste — couldn't write the clipboard")
        case .emptyText:
            return L("Yapıştırılamadı — metin yok", "Couldn't paste — no text")
        case .pasteEventUnavailable:
            return L("Yapıştırılamadı — metin panoda", "Couldn't paste — text on the clipboard")
        }
    }
}
