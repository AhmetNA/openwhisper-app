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
        guard modelLoaded || whisperSuspendedForIdle else {
            systemAudioStatus = "Önce konuşma modeli yüklensin."
            return
        }
        if whisperSuspendedForIdle { Task { await resumeIdleWhisperIfNeeded() } }
        systemAudioGeneration &+= 1
        let generation = systemAudioGeneration
        let capture = SystemAudioCapture()
        systemAudioCapture = capture
        systemAudioResultTask?.cancel()
        systemAudioResult = nil
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
                self.systemAudioStartedAt = Date()
                self.systemAudioIsRecording = true
                self.systemAudioStatus = "Kaydediliyor · Bitir'e basınca yazıya dökülür"
            } catch {
                guard let self, self.systemAudioGeneration == generation else { return }
                let message = String(format: loc("Bilgisayar sesi açılamadı: %@"), error.localizedDescription)
                self.lastError = message
                self.stopSystemAudioListening(tail: 0)
                self.showSystemAudioResult(message, succeeded: false)
            }
        }
    }

    func stopSystemAudioListening(tail: TimeInterval = 0.7) {
        guard systemAudioEnabled || systemAudioCapture != nil else { return }
        systemAudioGeneration &+= 1
        let wasRecording = systemAudioIsRecording
        let startedAt = systemAudioStartedAt
        systemAudioStartedAt = nil
        let capture = systemAudioCapture
        systemAudioCapture = nil
        systemAudioStatus = wasRecording ? L("Kayıt bitiriliyor…", "Finishing the recording…") : "Kapalı"
        if capture != nil { systemAudioPendingCount += 1 }
        systemAudioIsRecording = false
        systemAudioEnabled = false
        guard let capture else { return }
        Task { @MainActor [weak self] in
            let recording = await capture.stop(tail: wasRecording ? tail : 0)
            guard let self else { return }
            if let recording {
                self.enqueueSystemAudioRecording(recording)
                return
            }
            self.systemAudioPendingCount -= 1
            guard wasRecording else { return }
            owLog("[Result] System audio: nothing audible was recorded")
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.showSystemAudioResult(SystemAudioReport.nothingHeard(elapsed: elapsed), succeeded: false)
        }
    }

    func enqueueSystemAudioRecording(_ recording: SystemAudioRecording) {
        guard recording.samples.count >= 6_400 else {
            systemAudioPendingCount -= 1
            showSystemAudioResult(SystemAudioReport.tooShort(elapsed: recording.elapsed), succeeded: false)
            return
        }
        let previous = systemAudioTranscriptionTail
        systemAudioTranscriptionTail = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            await self.transcribeSystemAudioClip(recording)
        }
    }

    func transcribeSystemAudioClip(_ recording: SystemAudioRecording) async {
        let samples = recording.samples
        let audioSeconds = Double(samples.count) / 16_000
        systemAudioIsTranscribing = true
        defer {
            systemAudioIsTranscribing = false
            systemAudioPendingCount -= 1
        }
        nextTranscriptionID &+= 1
        let session = RecordingTranscriptionSession(
            id: nextTranscriptionID,
            targetApp: nil,
            targetSpeakerEnabled: false,
            targetSpeakerProfile: nil,
            pasteContext: PasteContext.initial(targetApp: nil)
        )
        var saveFailed = false
        var decodeFailed = false
        var spokenSeconds = 0.0
        var doneSeconds = 0.0
        for part in AudioSegmentation.makeSegments(from: samples) {
            setSystemAudioProgress(SystemAudioReport.progress(done: doneSeconds, total: audioSeconds))
            let segment = CompletedAudioSegment(samples: Array(part.samples), overlapSampleCount: part.overlapSampleCount)
            session.queuedSampleCount += segment.samples.count - segment.overlapSampleCount
            do {
                try await recordingHistoryStore.append(segment, sessionID: session.id, startedAt: recording.startedAt)
            } catch {
                saveFailed = true
                owLog("[SystemAudio] History save failed: \(error)")
            }
            do {
                let decode = try await decodeSystemAudio(segment)
                spokenSeconds += decode.spokenSeconds
                owLog(String(format: "[SystemAudio] Part: %.1f s of text in %.1f s of audio",
                             decode.spokenSeconds, Double(segment.samples.count) / 16_000))
                if !decode.text.isEmpty {
                    session.allSegmentTexts.append(decode.text)
                    session.segmentTexts.append(decode.text)
                }
            } catch {
                decodeFailed = true
                owLog("[SystemAudio] Decode failed: \(error)")
                lastError = error.localizedDescription
            }
            doneSeconds += Double(segment.samples.count - segment.overlapSampleCount) / 16_000
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
            lastError = String(format: loc("Bilgisayar sesi geçmişe kaydedilemedi: %@"), error.localizedDescription)
        }
        let traceID = recordingID.flatMap { id in savedRecordings.contains { $0.id == id } ? id : nil }
        if let traceID {
            VoiceEventLog.shared.begin(traceID, header: [
                "Recording \(traceID.uuidString)",
                "Started: \(recording.startedAt.formatted(date: .numeric, time: .standard))",
                "Source: system audio",
                String(format: "Duration: %.1f s recorded, %.1f s kept (long pauses shortened), %.1f s of it has text",
                       recording.elapsed, audioSeconds, spokenSeconds),
                "Whisper segments: \(session.allSegmentTexts)",
            ] + (savedRecordings.first { $0.id == traceID }?.stats?.logLines ?? [])
              + ["Speakers: not split (system audio)"])
        }
        let spoken = min(spokenSeconds, audioSeconds)
        await VoiceTrace.$current.withValue(traceID) {
            await finishSystemAudioClip(session, elapsed: recording.elapsed, audioSeconds: audioSeconds,
                                        spokenSeconds: spoken, decodeFailed: decodeFailed)
        }
    }

    private func decodeSystemAudio(_ segment: CompletedAudioSegment) async throws -> SystemAudioDecode {
        lastWhisperActivity = Date()
        if whisperSuspendedForIdle { await resumeIdleWhisperIfNeeded() }
        guard modelLoaded, let transcriber = activeTranscriptionService else {
            throw TranscriberError.modelNotLoaded
        }
        return try await transcriber.transcribeSystemAudio(audioData: segment.samples, language: language)
    }

    func finishSystemAudioClip(
        _ session: RecordingTranscriptionSession,
        elapsed: TimeInterval,
        audioSeconds: Double,
        spokenSeconds: Double,
        decodeFailed: Bool
    ) async {
        var output = AudioSegmentation.joinTranscripts(session.segmentTexts)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if output.hasPrefix("[BLANK") || output.hasPrefix("(BLANK") { output = "" }
        if !output.isEmpty {
            output = CorrectionEngine.applyCorrections(to: output, pairs: CorrectionStore.shared.activePairs).0
            output = PhoneticGlossaryCorrector.correct(output).0
            if laughterToRandomEnabled {
                output = LaughterRandomizer.transform(output).text
            } else if llmCleanupEnabled && cleanupAvailable {
                output = await llmCleanup?.cleanup(text: output) ?? output
            }
            output = await formatTurkishDictation(output)
            output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !output.isEmpty else {
            owLog("[Result] System audio: no text")
            showSystemAudioResult(SystemAudioReport.noText(elapsed: elapsed, audioSeconds: audioSeconds, decodeFailed: decodeFailed),
                                  succeeded: false)
            return
        }
        lastTranscription = output
        textInjector?.copyToClipboard(output)
        let copied = NSPasteboard.general.string(forType: .string) == output
        owLog("[Result] System audio \(copied ? "copied to clipboard" : "NOT copied to clipboard"): '\(output)'")
        showSystemAudioResult(
            SystemAudioReport.finished(
                elapsed: elapsed, audioSeconds: audioSeconds, spokenSeconds: spokenSeconds,
                wordCount: output.split(whereSeparator: \.isWhitespace).count, copied: copied
            ),
            succeeded: copied
        )
    }

    private func setSystemAudioProgress(_ status: String) {
        guard !systemAudioEnabled else { return }
        systemAudioStatus = status
        syncFlowBarVisibility()
    }

    /// Stays on the bar long enough to read; the menu row keeps it until the next recording.
    func showSystemAudioResult(_ message: String, succeeded: Bool) {
        if !systemAudioEnabled { systemAudioStatus = message }
        systemAudioResult = SystemAudioResult(message: message, succeeded: succeeded)
        systemAudioResultTask?.cancel()
        systemAudioResultTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.systemAudioResult = nil
        }
    }
}

struct SystemAudioResult: Equatable {
    let message: String
    let succeeded: Bool
}

/// What the flow bar and the menu row say about a system audio recording.
enum SystemAudioReport {
    /// Below this share of the audio having text, part of a spoken recording may be missing.
    private static let completeShare = 0.7

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded()), 0)
        if total < 60 { return L("\(total) sn", "\(total) s") }
        let (minutes, rest) = (total / 60, total % 60)
        if rest == 0 { return L("\(minutes) dk", "\(minutes) min") }
        return L("\(minutes) dk \(rest) sn", "\(minutes) min \(rest) s")
    }

    static func progress(done: Double, total: Double) -> String {
        guard done > 0 else {
            return L("\(duration(total)) ses çevriliyor…", "Transcribing \(duration(total)) of audio…")
        }
        return L("Çevriliyor · \(duration(done)) / \(duration(total))", "Transcribing · \(duration(done)) / \(duration(total))")
    }

    static func nothingHeard(elapsed: TimeInterval) -> String {
        L("Kayıt \(duration(elapsed)) · Ses duyulmadı", "Recorded \(duration(elapsed)) · No sound heard")
    }

    static func tooShort(elapsed: TimeInterval) -> String {
        L("Kayıt \(duration(elapsed)) · Çevirmek için çok az ses var", "Recorded \(duration(elapsed)) · Too little sound to transcribe")
    }

    static func noText(elapsed: TimeInterval, audioSeconds: Double, decodeFailed: Bool) -> String {
        let length = lengths(elapsed: elapsed, audioSeconds: audioSeconds)
        return decodeFailed
            ? L("\(length) · Çeviri başarısız", "\(length) · Transcription failed")
            : L("\(length) · Konuşma bulunamadı", "\(length) · No speech found")
    }

    static func finished(
        elapsed: TimeInterval, audioSeconds: Double, spokenSeconds: Double, wordCount: Int, copied: Bool
    ) -> String {
        var parts = [
            lengths(elapsed: elapsed, audioSeconds: audioSeconds),
            L("Çevrilen \(duration(spokenSeconds))", "Transcribed \(duration(spokenSeconds))"),
            L("\(wordCount) kelime", "\(wordCount) words"),
        ]
        if audioSeconds > 0, spokenSeconds / audioSeconds < completeShare {
            parts.append(L("Eksik olabilir", "May be incomplete"))
        }
        parts.append(copied ? L("Panoya kopyalandı", "Copied") : L("Panoya kopyalanamadı", "Couldn't copy"))
        return parts.joined(separator: " · ")
    }

    /// Silence is cut from the audio, so the recording's own length is shown only when it differs.
    private static func lengths(elapsed: TimeInterval, audioSeconds: Double) -> String {
        let audio = L("Ses \(duration(audioSeconds))", "Audio \(duration(audioSeconds))")
        guard elapsed - audioSeconds >= 5 else { return audio }
        return L("Kayıt \(duration(elapsed)) · \(audio)", "Recorded \(duration(elapsed)) · \(audio)")
    }
}
