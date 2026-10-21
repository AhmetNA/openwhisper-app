import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    /// Records the mixed Mac output from Başlat until Bitir as one recording; the whole
    /// session is transcribed once and copied to the clipboard. The mic/Fn path is separate.
    func startSystemAudioListening() {
        guard !systemAudioEnabled else { return }
        recordingPreviewTask?.cancel()
        guard modelLoaded else {
            systemAudioStatus = "Önce konuşma modeli yüklensin."
            return
        }
        systemAudioGeneration &+= 1
        let generation = systemAudioGeneration
        let capture = SystemAudioCapture()
        systemAudioCapture = capture
        systemAudioEnabled = true
        systemAudioStatus = "Bilgisayar sesi açılıyor…"
        capture.onLimitReached = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.systemAudioGeneration == generation else { return }
                owLog("[SystemAudio] 90-minute limit reached; finishing the recording")
                self.stopSystemAudioListening(tail: 0)
            }
        }
        capture.onError = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.systemAudioGeneration == generation else { return }
                // What was captured before the error is still transcribed.
                self.lastError = message
                self.stopSystemAudioListening(tail: 0)
            }
        }
        Task { @MainActor [weak self] in
            do {
                try await capture.start()
                guard let self, self.systemAudioGeneration == generation, self.systemAudioEnabled else {
                    _ = await capture.stop(tail: 0)
                    return
                }
                self.systemAudioIsRecording = true
                self.systemAudioStatus = "Kaydediliyor · Bitir'e basınca yazıya dökülür"
            } catch {
                guard let self, self.systemAudioGeneration == generation else { return }
                let message = "Bilgisayar sesi açılamadı: \(error.localizedDescription)"
                self.lastError = message
                self.stopSystemAudioListening(tail: 0)
                self.systemAudioStatus = message
            }
        }
    }

    func stopSystemAudioListening(tail: TimeInterval = 0.7) {
        guard systemAudioEnabled || systemAudioCapture != nil else { return }
        systemAudioGeneration &+= 1
        let generation = systemAudioGeneration
        let wasRecording = systemAudioIsRecording
        systemAudioEnabled = false
        systemAudioIsRecording = false
        systemAudioStatus = wasRecording ? "Kayıt bitiriliyor…" : "Kapalı"
        let capture = systemAudioCapture
        systemAudioCapture = nil
        guard let capture else { return }
        Task { @MainActor [weak self] in
            let recording = await capture.stop(tail: wasRecording ? tail : 0)
            guard let self else { return }
            if let recording {
                self.enqueueSystemAudioRecording(recording)
            } else if wasRecording, self.systemAudioGeneration == generation {
                owLog("[Result] System audio: nothing audible was recorded")
                self.systemAudioStatus = "Kayıtta ses duyulmadı"
            }
        }
    }

    func enqueueSystemAudioRecording(_ recording: SystemAudioRecording) {
        guard recording.samples.count >= 6_400 else { return }
        let previous = systemAudioTranscriptionTail
        systemAudioTranscriptionTail = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            await self.transcribeSystemAudioClip(recording)
        }
    }

    func transcribeSystemAudioClip(_ recording: SystemAudioRecording) async {
        let samples = recording.samples
        systemAudioIsTranscribing = true
        defer { systemAudioIsTranscribing = false }
        if !systemAudioEnabled { systemAudioStatus = "Bilgisayar sesi yazıya dökülüyor…" }
        nextTranscriptionID &+= 1
        let session = RecordingTranscriptionSession(
            id: nextTranscriptionID,
            targetApp: nil,
            targetSpeakerEnabled: false,
            targetSpeakerProfile: nil,
            pasteContext: PasteContext.initial(targetApp: nil)
        )
        var saveFailed = false
        for part in AudioSegmentation.makeSegments(from: samples) {
            let segment = CompletedAudioSegment(samples: Array(part.samples), overlapSampleCount: part.overlapSampleCount)
            session.queuedSampleCount += segment.samples.count - segment.overlapSampleCount
            do {
                try await recordingHistoryStore.append(segment, sessionID: session.id, startedAt: recording.startedAt)
            } catch {
                saveFailed = true
                owLog("[SystemAudio] History save failed: \(error)")
            }
            await transcribeStreamingSegment(segment, session: session)
        }
        let recordingID = await recordingHistoryStore.activeRecordingID(sessionID: session.id)
        do {
            savedRecordings = try await recordingHistoryStore.finish(
                sessionID: session.id,
                keep: !saveFailed,
                previewText: AudioSegmentation.joinTranscripts(session.segmentTexts),
                whisperSegments: session.allSegmentTexts.count
            )
        } catch {
            owLog("[SystemAudio] History finish failed: \(error)")
            lastError = "Bilgisayar sesi geçmişe kaydedilemedi: \(error.localizedDescription)"
        }
        let traceID = recordingID.flatMap { id in savedRecordings.contains { $0.id == id } ? id : nil }
        if let traceID {
            VoiceEventLog.shared.begin(traceID, header: [
                "Recording \(traceID.uuidString)",
                "Started: \(recording.startedAt.formatted(date: .numeric, time: .standard))",
                "Source: system audio",
                String(format: "Duration: %.1f s recorded, %.1f s kept (long pauses shortened)",
                       recording.elapsed, Double(samples.count) / 16_000),
                "Whisper segments: \(session.allSegmentTexts)",
            ] + (savedRecordings.first { $0.id == traceID }?.stats?.logLines ?? [])
              + ["Speakers: not split (system audio)"])
        }
        await VoiceTrace.$current.withValue(traceID) {
            await finishSystemAudioClip(session)
        }
    }

    func finishSystemAudioClip(_ session: RecordingTranscriptionSession) async {
        var output = AudioSegmentation.joinTranscripts(session.segmentTexts)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty, !output.hasPrefix("[BLANK"), !output.hasPrefix("(BLANK") else {
            owLog("[Result] System audio: no text")
            if !systemAudioEnabled { systemAudioStatus = "Metin çıkarılamadı" }
            return
        }
        output = CorrectionEngine.applyCorrections(to: output, pairs: CorrectionStore.shared.activePairs).0
        output = PhoneticGlossaryCorrector.correct(output).0
        if laughterToRandomEnabled {
            output = LaughterRandomizer.transform(output).text
        } else if llmCleanupEnabled && cleanupAvailable {
            output = await llmCleanup?.cleanup(text: output) ?? output
        }
        output = await formatTurkishDictation(output)
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return }
        lastTranscription = output
        textInjector?.copyToClipboard(output)
        if !systemAudioEnabled { systemAudioStatus = "Metin panoya kopyalandı" }
        owLog("[SystemAudio] Transcript copied to clipboard")
        owLog("[Result] System audio copied to clipboard: '\(output)'")
    }
}
