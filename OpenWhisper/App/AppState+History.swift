import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    /// Re-runs the selected saved audio through the current recognition and text settings.
    /// Replays never paste into another application or trigger voice commands.
    func replayRecording(_ recording: SavedRecording) {
        recordingPreviewTask?.cancel()
        guard replayingRecordingID == nil else { return }
        guard recordingState == .idle && pendingTranscriptionCount == 0 else {
            replayStatus = "Önce mevcut ses kaydının işlenmesini bekleyin."
            return
        }
        replayingRecordingID = recording.id
        replayStatus = "Kayıt yeniden analiz ediliyor…"
        Task { @MainActor in
            defer { replayingRecordingID = nil }
            let session = RecordingTranscriptionSession(
                id: 0,
                targetApp: nil,
                targetSpeakerEnabled: targetSpeakerFiltersTranscription,
                targetSpeakerProfile: targetSpeakerProfile,
                pasteContext: PasteContext.initial(targetApp: nil)
            )
            do {
                var frame: Int64 = 0
                while let (segment, nextFrame) = try await recordingHistoryStore.segment(id: recording.id, startingAt: frame) {
                    await transcribeStreamingSegment(segment, session: session)
                    frame = nextFrame
                }
                var output = AudioSegmentation.joinTranscripts(session.segmentTexts)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !output.isEmpty, !output.hasPrefix("[BLANK"), !output.hasPrefix("(BLANK") else {
                    replayStatus = "Bu kayıttan metin çıkarılamadı."
                    return
                }
                output = CorrectionEngine.applyCorrections(to: output, pairs: CorrectionStore.shared.activePairs).0
                output = PhoneticGlossaryCorrector.correct(output).0
                if laughterToRandomEnabled {
                    output = LaughterRandomizer.transform(output).text
                } else if llmCleanupEnabled && cleanupAvailable {
                    output = await llmCleanup?.cleanup(text: output) ?? output
                }
                output = output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !output.isEmpty else {
                    replayStatus = "Bu kayıttan metin çıkarılamadı."
                    return
                }
                textInjector?.copyToClipboard(output)
                replayStatus = "Yeniden analiz edildi ve panoya kopyalandı."
                do {
                    savedRecordings = try await recordingHistoryStore.updatePreview(id: recording.id, text: output)
                } catch {
                    owLog("[RecordingHistory] Replay preview save failed: \(error)")
                }
            } catch {
                replayStatus = "Kayıt açılamadı: \(error.localizedDescription)"
            }
        }
    }

    /// Older saved audio predates transcript previews. Fill those labels in the background
    /// when the menu is opened, without changing or deleting any recording.
    func prepareRecordingPreviews() {
        guard modelLoaded, recordingPreviewTask == nil,
              savedRecordings.contains(where: { $0.previewText == nil }) else { return }
        recordingPreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.recordingPreviewTask = nil }
            for recording in self.savedRecordings where recording.previewText == nil {
                guard !Task.isCancelled,
                      self.recordingState == .idle,
                      self.pendingTranscriptionCount == 0,
                      !self.systemAudioIsRecording,
                      !self.systemAudioIsTranscribing,
                      self.replayingRecordingID == nil else { return }
                let session = RecordingTranscriptionSession(
                    id: 0,
                    targetApp: nil,
                    targetSpeakerEnabled: self.targetSpeakerFiltersTranscription,
                    targetSpeakerProfile: self.targetSpeakerProfile,
                    pasteContext: PasteContext.initial(targetApp: nil)
                )
                do {
                    var frame: Int64 = 0
                    while !Task.isCancelled,
                          let (segment, nextFrame) = try await self.recordingHistoryStore.segment(id: recording.id, startingAt: frame) {
                        await self.transcribeStreamingSegment(segment, session: session)
                        frame = nextFrame
                    }
                    guard !Task.isCancelled else { return }
                    self.savedRecordings = try await self.recordingHistoryStore.updatePreview(
                        id: recording.id,
                        text: AudioSegmentation.joinTranscripts(session.segmentTexts)
                    )
                } catch {
                    owLog("[RecordingHistory] Preview could not be prepared: \(error)")
                }
            }
        }
    }
}
