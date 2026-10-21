import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    /// Called only after routing, on text that will be pasted or copied. Keep command
    /// parsing and TTS's existing spokenForm independent of the ITN grammar.
    func formatTurkishDictation(_ text: String) async -> String {
        guard DamgaNormalizer.shouldNormalize(enabled: damgaEnabled, language: language, text: text) else { return text }
        let terms = Array(Set((GlossaryStore.terms() ?? []) + CorrectionStore.shared.activePairs.map(\.right)))
        let output = await DamgaNormalizer.shared.normalize(text, protectedTerms: terms)
        guard damgaEnabled, language == "tr" else { return text }
        return output
    }

    /// Words in `text` that are neither Turkish nor English, minus the user's own glossary
    /// terms and learned corrections, which are often not dictionary words either.
    func misheardWords(in text: String) -> [MisheardWordDetector.Word] {
        let locale = Locale(identifier: "tr_TR")
        var ignoring = Set((GlossaryStore.terms() ?? []).flatMap { MisheardWordDetector.words(in: $0) }
            .map { $0.lowercased(with: locale) })
        for pair in CorrectionStore.shared.activePairs {
            ignoring.formUnion(MisheardWordDetector.words(in: pair.right).map { $0.lowercased(with: locale) })
        }
        return MisheardWordDetector.find(in: text, ignoring: ignoring)
    }

    /// A correction may only act while nothing newer happened: no newer transcript and no
    /// recording in progress (a volume revert would also undo the recording's ducking).
    func correctionIsCurrent(_ generation: UInt64) -> Bool {
        correctionGeneration == generation && recordingState == .idle
    }

    /// A Spotify command ran on a transcript with misheard words. Corrects the transcript in
    /// the background; if it then asks for another command, the first one is undone and the
    /// corrected one runs (see `SpotifyManager.rerunIfCorrected`).
    func rerunCorrectedCommand(
        _ text: String,
        misheard: [MisheardWordDetector.Word],
        generation: UInt64,
        session: RecordingTranscriptionSession
    ) async {
        guard let llmCleanup else { return }
        let corrected = await llmCleanup.cleanup(text: text, misheard: misheard)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !LLMCleanup.sameWords(corrected, text) else {
            owLog("[Misheard] Command '\(text)' unchanged after correction")
            return
        }
        owLog("[Misheard] Command corrected: '\(text)' → '\(corrected)'")
        guard correctionIsCurrent(generation),
              await SpotifyManager.isSpotifyCommand(
                corrected, ollamaAvailable: ollamaAvailable, commandMode: session.acceptsCommands
              ),
              correctionIsCurrent(generation) else { return }
        if await SpotifyManager.shared.rerunIfCorrected(original: text, corrected: corrected, targetApp: session.targetApp) {
            showFlowBarMessage("fixed", durationMs: 1000)
        }
    }

    /// A dictation was pasted, and its correction turned out to be a Spotify command. Deletes
    /// the pasted text and runs the command. Returns false (the caller then pastes the
    /// correction as usual) if it isn't a command or the text couldn't be deleted safely.
    func runCorrectedDictationAsCommand(
        pasted: String,
        corrected: String,
        generation: UInt64,
        session: RecordingTranscriptionSession,
        targetApp: NSRunningApplication?
    ) async -> Bool {
        guard correctionIsCurrent(generation),
              let injector = textInjector as? TextInjector,
              await SpotifyManager.isSpotifyCommand(
                corrected, ollamaAvailable: ollamaAvailable, commandMode: session.acceptsCommands
              ),
              correctionIsCurrent(generation) else { return false }
        let deleted = await withCheckedContinuation { continuation in
            injector.deleteInjectedText(pasted, targetApp: targetApp, context: swapPasteContext) {
                continuation.resume(returning: $0)
            }
        }
        guard deleted else {
            owLog("[Misheard] '\(corrected)' is a command, but the pasted text couldn't be deleted; keeping it as text")
            return false
        }
        owLog("[Misheard] Dictation '\(pasted)' was the command '\(corrected)'")
        swapPair = nil
        swapPasteContext = nil
        hotkey?.setSwapAvailable(false)
        if await SpotifyManager.shared.handleCommand(text: corrected, targetApp: targetApp) {
            lastTranscription = corrected
            showFlowBarMessage("fixed", durationMs: 1000)
        }
        return true
    }
}
