import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    /// Loads the persisted profile while keeping incompatible profiles available for
    /// replacement/deletion but never active for filtering.
    func loadTargetSpeakerProfile() {
        do {
            targetSpeakerProfile = try targetSpeakerProfileStore.load()
            hasStoredTargetSpeakerProfile = targetSpeakerProfile != nil
            if let profile = targetSpeakerProfile {
                if profile.isCompatible(with: targetSpeakerModel.modelIdentifier, audioProcessingMode: audioProcessingMode) {
                    targetSpeakerProfileStatus = "Kayıtlı profil hazır"
                    owLog("[TargetSpeaker] loadTargetSpeakerProfile: loaded valid profile (embeddings=\(profile.embeddings.count), schema=\(profile.schemaVersion), model=\(profile.modelIdentifier))")
                } else {
                    targetSpeakerProfile = nil
                    targetSpeakerEnabled = false
                    // Same schema/model, only the audio pipeline changed -- give the user the
                    // specific reason instead of the generic model-version message.
                    let modelAndSchemaMatch = profile.schemaVersion == TargetSpeakerProfile.currentSchemaVersion
                        && profile.modelIdentifier == targetSpeakerModel.modelIdentifier
                    if modelAndSchemaMatch && profile.audioProcessingMode != audioProcessingMode {
                        targetSpeakerProfileStatus = "Ses işleme modu değişti — yeniden kayıt gerekli"
                        owLog("[TargetSpeaker] loadTargetSpeakerProfile: profile audio processing mode mismatch (profile=\(profile.audioProcessingMode), current=\(audioProcessingMode))")
                    } else {
                        targetSpeakerProfileStatus = "Model sürümü değişti — yeniden kayıt gerekli"
                        owLog("[TargetSpeaker] loadTargetSpeakerProfile: profile incompatible with model '\(targetSpeakerModel.modelIdentifier)'")
                    }
                }
            } else {
                targetSpeakerEnabled = false
                owLog("[TargetSpeaker] loadTargetSpeakerProfile: no saved profile found")
            }
        } catch {
            targetSpeakerProfile = nil
            hasStoredTargetSpeakerProfile = false
            targetSpeakerEnabled = false
            targetSpeakerProfileStatus = "Profil okunamadı — yeniden kayıt gerekli"
            lastError = error.localizedDescription
            owLog("[TargetSpeaker] loadTargetSpeakerProfile error: \(error)")
        }
        refreshTargetSpeakerProfileCoherence()
        loadMicTargetSpeakerProfile(.buds)
        loadMicTargetSpeakerProfile(.external)
    }

    /// Like `loadTargetSpeakerProfile` for the buds or external-mic profile, except that a missing
    /// or stale one leaves the filter switch alone: it only turns filtering off for that mic.
    func loadMicTargetSpeakerProfile(_ mic: TargetSpeakerMic) {
        guard mic != .mac else { return }
        do {
            let profile = try targetSpeakerProfileStore(for: mic).load()
            guard let profile else {
                setMicTargetSpeakerProfile(mic, profile: nil, stored: false, status: "Henüz kayıt yok")
                return
            }
            if profile.isCompatible(with: targetSpeakerModel.modelIdentifier, audioProcessingMode: audioProcessingMode) {
                setMicTargetSpeakerProfile(mic, profile: profile, stored: true, status: "Kayıtlı profil hazır")
                owLog("[TargetSpeaker] \(mic) profile loaded (embeddings=\(profile.embeddings.count))")
            } else {
                setMicTargetSpeakerProfile(mic, profile: nil, stored: true, status: profile.audioProcessingMode != audioProcessingMode
                    ? "Ses işleme modu değişti — yeniden kayıt gerekli"
                    : "Model sürümü değişti — yeniden kayıt gerekli")
                owLog("[TargetSpeaker] \(mic) profile incompatible (mode=\(profile.audioProcessingMode), current=\(audioProcessingMode))")
            }
        } catch {
            setMicTargetSpeakerProfile(mic, profile: nil, stored: false, status: "Profil okunamadı — yeniden kayıt gerekli")
            owLog("[TargetSpeaker] \(mic) profile load error: \(error)")
        }
    }

    /// The buds and external-mic profile state; the Mac profile has its own bookkeeping.
    func setMicTargetSpeakerProfile(_ mic: TargetSpeakerMic, profile: TargetSpeakerProfile?, stored: Bool, status: String) {
        switch mic {
        case .mac:
            return
        case .buds:
            budsTargetSpeakerProfile = profile
            hasStoredBudsTargetSpeakerProfile = stored
            budsTargetSpeakerProfileStatus = status
        case .external:
            externalTargetSpeakerProfile = profile
            hasStoredExternalTargetSpeakerProfile = stored
            externalTargetSpeakerProfileStatus = status
        }
    }

    func targetSpeakerProfile(for mic: TargetSpeakerMic) -> TargetSpeakerProfile? {
        switch mic {
        case .mac: return targetSpeakerProfile
        case .buds: return budsTargetSpeakerProfile
        case .external: return externalTargetSpeakerProfile
        }
    }

    func targetSpeakerProfileStore(for mic: TargetSpeakerMic) -> TargetSpeakerProfileStore {
        switch mic {
        case .mac: return targetSpeakerProfileStore
        case .buds: return budsTargetSpeakerProfileStore
        case .external: return externalTargetSpeakerProfileStore
        }
    }

    /// Makes `profile` the active one for `mic` after an enrollment, append or undo saved it.
    func adoptTargetSpeakerProfile(_ profile: TargetSpeakerProfile, for mic: TargetSpeakerMic, status: String = "Kayıtlı profil hazır") {
        guard mic == .mac else {
            setMicTargetSpeakerProfile(mic, profile: profile, stored: true, status: status)
            return
        }
        targetSpeakerProfile = profile
        refreshTargetSpeakerProfileCoherence()
        hasStoredTargetSpeakerProfile = true
        targetSpeakerProfileStatus = status
    }

    /// The mic the wake listener hears through, so the wake clip is scored against its profile.
    var wakeTargetSpeakerMic: TargetSpeakerMic {
        TargetSpeakerMic(device: WakeWordListener.listeningDevice(
            priority: inputPriorityUIDs, devices: AudioEngine.availableInputDevices()))
    }

    var wakeTargetSpeakerProfile: TargetSpeakerProfile? {
        targetSpeakerProfile(for: wakeTargetSpeakerMic)
    }

    /// The connected external mic: the highest-ranked one, else the first one plugged in.
    static func connectedExternalInput(priority: [String], devices: [AudioInputDevice]) -> AudioInputDevice? {
        let isExternal = { (device: AudioInputDevice) in TargetSpeakerMic(device: device) == .external }
        return MicPriority.top(priority, devices: devices, where: isExternal) ?? devices.first(where: isExternal)
    }

    /// The input an enrollment or sample for `mic` records from: the connected buds, the
    /// external mic, or the Mac's own mic even while another one ranks higher or is the default (that
    /// would put another mic's audio into the Mac profile).
    func targetSpeakerEnrollmentInputUID(for mic: TargetSpeakerMic) -> String? {
        let devices = AudioEngine.availableInputDevices()
        switch mic {
        case .buds:
            return AudioEngine.connectedBluetoothInput()?.uid
        case .external:
            return Self.connectedExternalInput(priority: inputPriorityUIDs, devices: devices)?.uid
        case .mac:
            return devices.first { $0.isBuiltIn }?.uid
        }
    }

    /// Starts the capture for an enrollment or sample. The buds mic hears music played into the
    /// ear and an external mic hears the Mac's speakers without echo cancellation, so media
    /// pauses for them whatever the ducking switch says.
    func startTargetSpeakerCapture(for mic: TargetSpeakerMic, audioEngine: AudioEngine) {
        if mic != .mac {
            recordingMedia.begin(immediately: true)
        } else if audioDuckingEnabled {
            recordingMedia.begin()
        }
        audioEngine.startRecording(
            deviceUID: targetSpeakerEnrollmentInputUID(for: mic),
            audioProcessingMode: audioProcessingMode,
            waitsForLinkAudio: mic == .buds,
            levelCallback: { [weak self] rawLevel in
                let target = AudioSignalProcessor.displayLevel(forRawRMS: rawLevel)
                Task { @MainActor in
                    guard let self else { return }
                    self.audioLevel = target
                }
            }
        )
    }

    /// Recomputes `targetSpeakerProfileCoherence` from the currently active profile. Called
    /// exactly at the points where `targetSpeakerProfile` itself changes (load, enrollment
    /// success and delete) -- never from a view body -- because the underlying
    /// computation is O(n^2) in embedding count. Existing profiles predate this check entirely and
    /// are never retroactively invalidated by a low score here; this is purely informational.
    func refreshTargetSpeakerProfileCoherence() {
        targetSpeakerProfileCoherence = targetSpeakerProfile.map { TargetSpeakerFilter.recordingCoherence($0.embeddings) }
        if let coherence = targetSpeakerProfileCoherence {
            owLog("[TargetSpeaker] Profile coherence refreshed: \(String(format: "%.3f", coherence))")
        }
    }

    /// Starts the optional overlap stack in the background. Normal dictation never awaits this
    /// task: if a download/preparation is still running, the target-speaker filter remains the
    /// conservative path for the current recording and a later recording can use diarization once
    /// preparation has completed.
    func startTargetSpeakerDiarizationPreparation() {
        guard targetSpeakerFiltersTranscription,
              targetSpeakerProfile != nil,
              !targetSpeakerDiarizationReady,
              targetSpeakerDiarizationPreparationTask == nil else {
            owLog("[TargetSpeaker] startTargetSpeakerDiarizationPreparation skipped (enabled=\(targetSpeakerEnabled), profile=\(targetSpeakerProfile != nil), ready=\(targetSpeakerDiarizationReady), taskInFlight=\(targetSpeakerDiarizationPreparationTask != nil))")
            return
        }

        owLog("[TargetSpeaker] startTargetSpeakerDiarizationPreparation starting task...")
        let progressHandler: TargetSpeakerDiarizationProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, !self.targetSpeakerEnrollmentActive else { return }
                self.targetSpeakerPreparationProgress = progress.fractionCompleted
                self.targetSpeakerPreparationMessage = progress.message
                owLog("[TargetSpeaker] Diarization prep progress: phase=\(progress.phase), msg='\(progress.message)'")
            }
        }
        targetSpeakerDiarizationPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.targetSpeakerDiarizationPreparationTask = nil
                if !self.targetSpeakerEnrollmentActive {
                    self.targetSpeakerPreparationProgress = nil
                    self.targetSpeakerPreparationMessage = ""
                }
            }
            do {
                try await self.targetSpeakerDiarization.prepare(progressHandler: progressHandler)
                guard !Task.isCancelled else { return }
                self.targetSpeakerDiarizationReady = true
                owLog("[TargetSpeaker] Diarization preparation ready")
            } catch {
                self.targetSpeakerDiarizationReady = false
                self.lastError = "Ses ayrıştırma modeli hazırlanamadı: \(error.localizedDescription)"
                owLog("[TargetSpeaker] Diarization preparation failed: \(error)")
            }
        }
    }

    /// Shows the "bu benim sesimdi" confirmation offer. Deliberately separate from `showFlowBarMessage`: that
    /// helper's 1.5s auto-dismiss is shared by other callers and must not change, whereas a
    /// clickable control needs enough time (8s) to actually be read and tapped. Cancels any
    /// pending `flowBarMessageTask` so a stray 1.5s timer can't yank the message out from under
    /// the offer.
    func showTargetSpeakerAppendOffer(message: String) {
        owLog("[TargetSpeaker] showTargetSpeakerAppendOffer: message='\(message)'")
        flowBarMessageTask?.cancel()
        flowBarMessageTask = nil
        flowBarMessage = message
        targetSpeakerAppendOfferActive = true
        syncFlowBarVisibility()

        targetSpeakerAppendOfferTask?.cancel()
        targetSpeakerAppendOfferTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            owLog("[TargetSpeaker] Target speaker offer timed out after 8s")
            self.dismissTargetSpeakerAppendOffer()
            self.flowBarMessage = nil
            self.syncFlowBarVisibility()
        }
    }

    /// Tears down the offer's own state (task, active flag, retained audio + text) without
    /// necessarily touching `flowBarMessage` -- callers that are about to show their own message
    /// right after (e.g. `confirmRetainedRecordingWasTargetSpeaker`) clear that separately.
    /// Internal (not `private`) so tests can simulate the 8s offer timeout firing without an
    /// actual 8-second sleep -- see `AppStateTargetSpeakerIntegrationTests`.
    func dismissTargetSpeakerAppendOffer() {
        owLog("[TargetSpeaker] dismissTargetSpeakerAppendOffer")
        targetSpeakerAppendOfferTask?.cancel()
        targetSpeakerAppendOfferTask = nil
        targetSpeakerAppendOfferActive = false
        retainedConfirmationCandidate = nil
        retainedConfirmationText = nil
        retainedConfirmationPasteContext = nil
        retainedConfirmationTargetApp = nil
        retainedConfirmationMic = .mac
    }

    /// Stores the candidate, transcript, and destination context as one retained confirmation
    /// unit so they can never drift to different recordings.
    func retainConfirmation(
        candidate: TargetSpeakerConfirmationCandidate,
        text: String,
        pasteContext: PasteContext?,
        targetApp: NSRunningApplication?,
        mic: TargetSpeakerMic = .mac
    ) {
        guard !candidate.samples.isEmpty, !text.isEmpty else {
            owLog("[TargetSpeaker] retainConfirmation rejected empty candidate or text")
            dismissTargetSpeakerAppendOffer()
            return
        }
        owLog("[TargetSpeaker] retainConfirmation stored candidate with \(candidate.samples.count) samples and text length \(text.count)")
        retainedConfirmationCandidate = candidate
        retainedConfirmationText = text
        retainedConfirmationPasteContext = pasteContext
        retainedConfirmationTargetApp = targetApp
        retainedConfirmationMic = mic
    }

    /// Fired by the flow bar's "Bu benim sesimdi" tap. It delivers the retained transcript once
    /// and then explicitly appends the retained coherent candidate to the active profile.
    func confirmRetainedRecordingWasTargetSpeaker() {
        owLog("[TargetSpeaker] confirmRetainedRecordingWasTargetSpeaker called: offerActive=\(targetSpeakerAppendOfferActive), inFlight=\(isConfirmationInFlight), hasCandidate=\(retainedConfirmationCandidate != nil), textLength=\(retainedConfirmationText?.count ?? 0)")
        guard !isConfirmationInFlight,
              targetSpeakerAppendOfferActive,
              let candidate = retainedConfirmationCandidate,
              let textToPaste = retainedConfirmationText,
              let profile = targetSpeakerProfile(for: retainedConfirmationMic) else {
            owLog("[TargetSpeaker] confirmRetainedRecordingWasTargetSpeaker guard failed")
            return
        }

        let pasteContext = retainedConfirmationPasteContext
        let targetApp = retainedConfirmationTargetApp
        let mic = retainedConfirmationMic
        confirmationOperationID &+= 1
        let operationID = confirmationOperationID
        isConfirmationInFlight = true
        confirmationPasteOutcome = nil
        confirmationPasteCompleted = false
        confirmationAppendCompleted = false
        confirmationAppendSucceeded = false
        confirmationAppendError = nil
        confirmationTextBeingDelivered = textToPaste

        // Deactivate the chip before starting either asynchronous operation. Keep the retained
        // triple alive until both delivery and append complete; the in-flight flag prevents a
        // second tap, while a timeout or new recording still clears it atomically.
        targetSpeakerAppendOfferTask?.cancel()
        targetSpeakerAppendOfferTask = nil
        targetSpeakerAppendOfferActive = false
        flowBarMessage = "Onay işleniyor…"
        syncFlowBarVisibility()

        // Start delivery before the profile append, using the exact retained PasteContext.
        owLog("[TargetSpeaker] Starting paste delivery and profile append for confirmed candidate...")
        textInjector?.pasteTextResult(
            textToPaste,
            targetApp: targetApp,
            context: pasteContext
        ) { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.confirmationOperationID == operationID else { return }
                owLog("[TargetSpeaker] Confirmed candidate paste outcome: \(outcome)")
                self.confirmationPasteOutcome = outcome
                self.confirmationPasteCompleted = true
                self.finishConfirmationOperationIfReady(operationID: operationID)
            }
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let receipt = try await self.targetSpeakerFilter.appendConfirmedCandidateWithReceipt(
                    candidate,
                    to: profile,
                    store: self.targetSpeakerProfileStore(for: mic),
                    audioProcessingMode: self.audioProcessingMode
                )
                guard self.confirmationOperationID == operationID else { return }
                self.adoptTargetSpeakerProfile(receipt.appendedProfile, for: mic)
                self.lastConfirmedAppendReceipt = receipt
                self.lastConfirmedAppendMic = mic
                self.confirmationAppendSucceeded = true
                self.confirmationAppendError = nil
                owLog("[TargetSpeaker] Confirmed candidate appended successfully to profile: new count=\(receipt.appendedProfile.embeddings.count)")
            } catch {
                guard self.confirmationOperationID == operationID else { return }
                self.confirmationAppendSucceeded = false
                self.confirmationAppendError = error.localizedDescription
                self.lastError = error.localizedDescription
                owLog("[TargetSpeaker] Confirmed candidate append failed: \(error)")
            }
            guard self.confirmationOperationID == operationID else { return }
            self.confirmationAppendCompleted = true
            self.finishConfirmationOperationIfReady(operationID: operationID)
        }
    }

    func finishConfirmationOperationIfReady(operationID: UInt64) {
        guard isConfirmationInFlight,
              confirmationOperationID == operationID,
              confirmationPasteCompleted,
              confirmationAppendCompleted else { return }

        let pasteOutcome = confirmationPasteOutcome ?? .clipboardOnly(.targetApplicationUnavailable)
        let appendSucceeded = confirmationAppendSucceeded
        let appendError = confirmationAppendError
        isConfirmationInFlight = false
        if !appendSucceeded, let appendError {
            lastError = appendError
        }

        owLog("[TargetSpeaker] finishConfirmationOperationIfReady: pasteOutcome=\(pasteOutcome), appendSucceeded=\(appendSucceeded), appendError=\(appendError ?? "none")")

        switch (pasteOutcome, appendSucceeded) {
        case (.pastedVerified, true), (.pastedUnverified, true):
            swapPair = nil
            swapPasteContext = nil
            hotkey?.setSwapAvailable(false)
            lastInjectedIsCleaned = true
            lastInjectedText = confirmationTextBeingDelivered
            showFlowBarMessage("Ses profiline eklendi")
        case (.clipboardOnly(_), true):
            showFlowBarMessage("Metin panoda, ses profiline eklendi")
        case (.pastedVerified, false), (.pastedUnverified, false):
            dismissFlowBarMessage()
        case (.clipboardOnly(let reason), false):
            showFlowBarMessage(clipboardOnlyMessage(for: reason))
        }

        confirmationPasteOutcome = nil
        confirmationPasteCompleted = false
        confirmationAppendCompleted = false
        confirmationAppendSucceeded = false
        confirmationAppendError = nil
        confirmationTextBeingDelivered = ""
        dismissTargetSpeakerAppendOffer()
    }

    func invalidateTargetSpeakerEnrollmentWork() {
        targetSpeakerEnrollmentGeneration &+= 1
        targetSpeakerEnrollmentTask?.cancel()
        targetSpeakerEnrollmentTask = nil
    }

    @discardableResult
    func teardownTargetSpeakerEnrollmentRecording() -> [Float] {
        let wasRecording = targetSpeakerEnrollmentIsRecording
        defer { if wasRecording { recordingMedia.end() } }
        recordingTimer?.invalidate()
        recordingTimer = nil
        let samples: [Float]
        if targetSpeakerEnrollmentIsRecording {
            samples = (audioEngine?.stopRecording() ?? []).flatMap(\.samples)
        } else {
            samples = []
        }
        targetSpeakerEnrollmentIsRecording = false
        if recordingState == .recording {
            recordingState = .idle
        }
        recordingDuration = 0
        audioLevel = 0
        return samples
    }

    func isCurrentTargetSpeakerEnrollment(_ generation: UInt64) -> Bool {
        generation == targetSpeakerEnrollmentGeneration && !Task.isCancelled
    }

    func startTargetSpeakerSampleRecording() {
        owLog("[TargetSpeaker] startTargetSpeakerSampleRecording called")
        // Buds or an external mic in use and its own profile to grow: the sample goes there.
        let inUse = TargetSpeakerMic(device: AudioEngine.availableInputDevices().first { $0.uid == resolvedInputDeviceUID(for: .fnHold) })
        let mic: TargetSpeakerMic = targetSpeakerProfile(for: inUse) != nil ? inUse : .mac
        guard recordingState == .idle,
              canCaptureTargetSpeakerSample,
              targetSpeakerProfile(for: mic) != nil,
              let audioEngine else {
            owLog("[TargetSpeaker] startTargetSpeakerSampleRecording skipped (state=\(recordingState), canCapture=\(canCaptureTargetSpeakerSample), mic=\(mic), hasProfile=\(targetSpeakerProfile(for: mic) != nil))")
            return
        }

        clearFlowBarMessage()
        targetSpeakerSampleMic = mic

        targetSpeakerSampleIsRecording = true
        targetSpeakerSampleStatus = "Kaydediliyor — tanınmadığın koşulda konuş (en fazla 30 sn)."
        recordingState = .recording
        recordingDuration = 0
        audioLevel = 0
        lastError = nil
        startTargetSpeakerCapture(for: mic, audioEngine: audioEngine)
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.targetSpeakerSampleIsRecording else { return }
                self.recordingDuration = min(
                    self.recordingDuration + 0.25,
                    TargetSpeakerFilterConfiguration.maximumEnrollmentDuration
                )
                if self.recordingDuration >= TargetSpeakerFilterConfiguration.maximumEnrollmentDuration {
                    owLog("[TargetSpeaker] Sample recording reached max duration 30s")
                    self.stopTargetSpeakerSampleRecording()
                }
            }
        }
    }

    func stopTargetSpeakerSampleRecording() {
        owLog("[TargetSpeaker] stopTargetSpeakerSampleRecording called")
        guard targetSpeakerSampleIsRecording else { return }
        let samples = teardownTargetSpeakerSampleRecording()

        guard !samples.isEmpty else {
            targetSpeakerSampleStatus = "Kayıt alınamadı; tekrar deneyin."
            owLog("[TargetSpeaker] Sample recording returned 0 samples")
            return
        }
        guard let profile = targetSpeakerProfile(for: targetSpeakerSampleMic) else {
            targetSpeakerSampleStatus = "Önce \"Sesimi kaydet\" ile profil oluşturmalısın."
            return
        }

        owLog("[TargetSpeaker] Sample recording stopped: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count)/16000.0))s)")
        appendTargetSpeakerSample(samples, to: profile)
    }

    /// Shared append boundary so the capture path and deterministic state tests agree.
    func appendTargetSpeakerSample(_ samples: [Float], to profile: TargetSpeakerProfile) {
        let mic = targetSpeakerSampleMic
        targetSpeakerSampleIsProcessing = true
        targetSpeakerSampleStatus = "Örnek doğrulanıyor…"
        // The profile records the processing chain it was built under and `appendConfirmedCandidate`
        // rejects a mismatch outright, so pass the mode actually in use rather than the parameter
        // default — otherwise every append fails with a confusing incompatibility error.
        let mode = audioProcessingMode
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.targetSpeakerSampleIsProcessing = false }
            do {
                let receipt = try await self.targetSpeakerFilter.appendConfirmedCandidateWithReceipt(
                    samples,
                    to: profile,
                    store: self.targetSpeakerProfileStore(for: mic),
                    audioProcessingMode: mode
                )
                let added = receipt.appendedProfile.embeddings.count - receipt.previousProfile.embeddings.count
                self.adoptTargetSpeakerProfile(receipt.appendedProfile, for: mic)
                self.lastConfirmedAppendReceipt = receipt
                self.lastConfirmedAppendMic = mic
                self.targetSpeakerSampleStatus =
                    "\(added) örnek eklendi — \(mic == .buds ? "kulaklık profilinde" : mic == .external ? "harici mikrofon profilinde" : "profilde") toplam \(receipt.appendedProfile.embeddings.count)."
                owLog("[TargetSpeaker] On-demand sample appended (\(mic)): +\(added), new count=\(receipt.appendedProfile.embeddings.count)")
            } catch {
                self.targetSpeakerSampleStatus = error.localizedDescription
                self.lastError = error.localizedDescription
                owLog("[TargetSpeaker] On-demand sample append failed: \(error)")
            }
        }
    }

    func teardownTargetSpeakerSampleRecording() -> [Float] {
        let wasRecording = targetSpeakerSampleIsRecording
        defer { if wasRecording { recordingMedia.end() } }
        recordingTimer?.invalidate()
        recordingTimer = nil
        let samples: [Float]
        if targetSpeakerSampleIsRecording {
            samples = (audioEngine?.stopRecording() ?? []).flatMap(\.samples)
        } else {
            samples = []
        }
        targetSpeakerSampleIsRecording = false
        if recordingState == .recording {
            recordingState = .idle
        }
        recordingDuration = 0
        audioLevel = 0
        return samples
    }

    func beginTargetSpeakerEnrollment(for mic: TargetSpeakerMic = .mac) {
        owLog("[TargetSpeaker] beginTargetSpeakerEnrollment called (mic=\(mic))")
        guard recordingState == .idle, !targetSpeakerEnrollmentIsProcessing else {
            owLog("[TargetSpeaker] beginTargetSpeakerEnrollment skipped (state=\(recordingState), processing=\(targetSpeakerEnrollmentIsProcessing))")
            return
        }
        invalidateTargetSpeakerEnrollmentWork()
        _ = teardownTargetSpeakerEnrollmentRecording()
        targetSpeakerEnrollmentMic = mic
        targetSpeakerEnrollmentActive = true
        targetSpeakerPreparationProgress = nil
        targetSpeakerPreparationMessage = ""
        targetSpeakerEnrollmentStep = 0
        targetSpeakerEnrollmentRecordings = []
        targetSpeakerRejectedEnrollment = nil
        targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentConditionPrompts[0]
        targetSpeakerEnrollmentStatus = "İki farklı pozisyonda kayıt gerekli; ideal süre her kayıt için 10–15 saniye, maksimum 30 saniye."
    }

    func startTargetSpeakerEnrollmentRecording() {
        owLog("[TargetSpeaker] startTargetSpeakerEnrollmentRecording step=\(targetSpeakerEnrollmentStep + 1)/\(TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount)")
        guard recordingState == .idle,
              !targetSpeakerEnrollmentIsProcessing,
              targetSpeakerEnrollmentStep < TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount,
              let audioEngine else {
            owLog("[TargetSpeaker] startTargetSpeakerEnrollmentRecording skipped (state=\(recordingState), processing=\(targetSpeakerEnrollmentIsProcessing), step=\(targetSpeakerEnrollmentStep))")
            return
        }

        clearFlowBarMessage()

        targetSpeakerRejectedEnrollment = nil
        targetSpeakerEnrollmentIsRecording = true
        recordingState = .recording
        recordingDuration = 0
        audioLevel = 0
        targetSpeakerPreparationProgress = nil
        targetSpeakerPreparationMessage = ""
        lastError = nil
        startTargetSpeakerCapture(for: targetSpeakerEnrollmentMic, audioEngine: audioEngine)
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.targetSpeakerEnrollmentIsRecording else { return }
                self.recordingDuration = min(
                    self.recordingDuration + 0.25,
                    TargetSpeakerFilterConfiguration.maximumEnrollmentDuration
                )
                if self.recordingDuration >= TargetSpeakerFilterConfiguration.maximumEnrollmentDuration {
                    owLog("[TargetSpeaker] Enrollment recording step \(self.targetSpeakerEnrollmentStep + 1) reached max duration 30s")
                    self.stopTargetSpeakerEnrollmentRecording()
                }
            }
        }
    }

    func stopTargetSpeakerEnrollmentRecording() {
        owLog("[TargetSpeaker] stopTargetSpeakerEnrollmentRecording called")
        guard targetSpeakerEnrollmentIsRecording else { return }
        let samples = teardownTargetSpeakerEnrollmentRecording()

        guard !samples.isEmpty else {
            targetSpeakerEnrollmentStatus = "Kayıt alınamadı; tekrar deneyin."
            owLog("[TargetSpeaker] Enrollment recording returned 0 samples")
            return
        }

        owLog("[TargetSpeaker] Enrollment recording step \(targetSpeakerEnrollmentStep + 1) stopped: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count)/16000.0))s)")
        processTargetSpeakerEnrollmentSamples(samples)
    }

    /// Shared enrollment boundary used by the audio path and deterministic state tests.
    func processTargetSpeakerEnrollmentSamples(_ samples: [Float]) {
        owLog("[TargetSpeaker] processTargetSpeakerEnrollmentSamples: step=\(targetSpeakerEnrollmentStep + 1), samples=\(samples.count)")
        guard targetSpeakerEnrollmentActive,
              !targetSpeakerEnrollmentIsProcessing,
              targetSpeakerEnrollmentStep < TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount,
              !samples.isEmpty else {
            owLog("[TargetSpeaker] processTargetSpeakerEnrollmentSamples skipped (active=\(targetSpeakerEnrollmentActive), processing=\(targetSpeakerEnrollmentIsProcessing), step=\(targetSpeakerEnrollmentStep))")
            return
        }

        targetSpeakerEnrollmentIsProcessing = true
        targetSpeakerEnrollmentStatus = "Kayıt doğrulanıyor…"
        let generation = targetSpeakerEnrollmentGeneration
        let progressHandler: TargetSpeakerProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                self.targetSpeakerPreparationProgress = progress.fractionCompleted
                self.targetSpeakerPreparationMessage = progress.message
            }
        }
        let maximumSamples = Int(
            TargetSpeakerFilterConfiguration.maximumEnrollmentDuration
                * Double(TargetSpeakerFilterConfiguration.sampleRate)
        )
        let recording = Array(samples.prefix(maximumSamples))
        let sampleIndex = targetSpeakerEnrollmentStep
        targetSpeakerEnrollmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.targetSpeakerEnrollmentGeneration == generation {
                    self.targetSpeakerEnrollmentIsProcessing = false
                    self.targetSpeakerPreparationProgress = nil
                    self.targetSpeakerPreparationMessage = ""
                    self.targetSpeakerEnrollmentTask = nil
                }
            }
            do {
                owLog("[TargetSpeaker] Validating enrollment sample \(sampleIndex + 1)...")
                let result = try await self.targetSpeakerFilter.validateEnrollmentSample(
                    recording,
                    progressHandler: progressHandler
                )
                guard self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                guard result.isValid else {
                    self.targetSpeakerEnrollmentStatus = "Bu kayıt en az 10 saniye net konuşma içermiyor veya çok kırpılmış; aynı pozisyonda yeniden kaydedin."
                    owLog("[TargetSpeaker] Enrollment sample \(sampleIndex + 1) invalid: voicedDuration=\(result.voicedDuration)s, clippedRatio=\(result.clippedSampleRatio)")
                    return
                }

                guard sampleIndex == self.targetSpeakerEnrollmentRecordings.count else {
                    self.targetSpeakerEnrollmentStatus = "Kayıt sırası değişti; lütfen yeniden başlayın."
                    owLog("[TargetSpeaker] Sample index mismatch: sampleIndex=\(sampleIndex), count=\(self.targetSpeakerEnrollmentRecordings.count)")
                    return
                }
                self.targetSpeakerEnrollmentRecordings.append(recording)
                owLog("[TargetSpeaker] Enrollment sample \(sampleIndex + 1) validated and stored (\(recording.count) samples)")

                if self.targetSpeakerEnrollmentRecordings.count < TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount {
                    self.targetSpeakerEnrollmentStep += 1
                    self.targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentConditionPrompts[1]
                    self.targetSpeakerEnrollmentStatus = "İlk kayıt tamamlandı. Duruşunu değiştir ve ikinci kaydı başlat."
                    owLog("[TargetSpeaker] First enrollment sample completed. Prompting for second sample.")
                    return
                }

                self.targetSpeakerEnrollmentStep = TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount
                self.targetSpeakerEnrollmentStatus = "İki kayıt doğrulandı; profil çıkarılıyor…"
                owLog("[TargetSpeaker] Both enrollment samples validated. Creating profile...")
                await self.createTargetSpeakerEnrollmentProfile(
                    generation: generation, progressHandler: progressHandler, fallbackFailedIndex: sampleIndex)
            } catch {
                guard self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                self.targetSpeakerEnrollmentStatus = error.localizedDescription
                owLog("[TargetSpeaker] Enrollment sample validation failed with error: \(error)")
            }
        }
    }

    /// Builds the profile from both enrollment recordings. A quality-check rejection steps back to
    /// the failed recording but keeps both, so the user can re-record it or accept the profile as
    /// is (`acceptRejectedTargetSpeakerEnrollment`); `acceptedScore` marks such a profile.
    func createTargetSpeakerEnrollmentProfile(
        generation: UInt64, progressHandler: @escaping TargetSpeakerProgressHandler,
        fallbackFailedIndex: Int, acceptedScore: Float? = nil
    ) async {
        let mic = targetSpeakerEnrollmentMic
        let tuning = TargetSpeakerTuning.resolved()
        do {
            let profile = try await targetSpeakerFilter.createProfile(
                from: targetSpeakerEnrollmentRecordings,
                store: targetSpeakerProfileStore(for: mic),
                progressHandler: progressHandler,
                tuning: acceptedScore == nil ? tuning : tuning.withoutEnrollmentFloors,
                audioProcessingMode: audioProcessingMode
            )
            guard isCurrentTargetSpeakerEnrollment(generation) else { return }
            adoptTargetSpeakerProfile(profile, for: mic)
            targetSpeakerLowScores[mic.rawValue] = acceptedScore.map(Double.init)
            targetSpeakerRejectedEnrollment = nil
            lastConfirmedAppendReceipt = nil
            // A buds profile alone filters nothing on the Mac mic: the switch stays the user's.
            if mic == .mac {
                targetSpeakerEnabled = true
                startTargetSpeakerDiarizationPreparation()
            }
            targetSpeakerEnrollmentStatus = "Profil hazır; farklı pozisyonlardaki sesin de işlenecek."
            targetSpeakerEnrollmentActive = false
            targetSpeakerPreparationProgress = nil
            owLog("[TargetSpeaker] Profile created and saved successfully (\(mic))! Total embeddings=\(profile.embeddings.count)"
                  + (acceptedScore.map { " — accepted below the quality check at \(String(format: "%.2f", $0))" } ?? ""))
        } catch {
            guard isCurrentTargetSpeakerEnrollment(generation) else { return }
            var failedIndex = fallbackFailedIndex
            var score: Float?
            switch error {
            case TargetSpeakerEnrollmentError.lowRecordingCoherence(let index, let measured, _):
                failedIndex = index
                score = measured
            case TargetSpeakerEnrollmentError.crossRecordingMismatch(let measured, _):
                score = measured
            default:
                break
            }
            targetSpeakerRejectedEnrollment = score.map {
                TargetSpeakerRejectedEnrollment(recordings: targetSpeakerEnrollmentRecordings, score: $0)
            }
            targetSpeakerEnrollmentStep = failedIndex
            targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentConditionPrompts[failedIndex]
            targetSpeakerEnrollmentRecordings.removeSubrange(failedIndex...)
            targetSpeakerEnrollmentStatus = error.localizedDescription
            lastError = error.localizedDescription
            owLog("[TargetSpeaker] Profile creation failed: \(error.localizedDescription) (failedIndex=\(failedIndex))")
        }
    }

    /// Saves the profile the quality check turned down, as the user asked.
    func acceptRejectedTargetSpeakerEnrollment() {
        guard let rejected = targetSpeakerRejectedEnrollment, targetSpeakerEnrollmentActive,
              !targetSpeakerEnrollmentIsProcessing, !targetSpeakerEnrollmentIsRecording else { return }
        owLog("[TargetSpeaker] User accepted the enrollment as is (score \(String(format: "%.2f", rejected.score)), mic=\(targetSpeakerEnrollmentMic))")
        targetSpeakerEnrollmentRecordings = rejected.recordings
        targetSpeakerEnrollmentStep = TargetSpeakerFilterConfiguration.requiredEnrollmentSampleCount
        targetSpeakerEnrollmentIsProcessing = true
        targetSpeakerEnrollmentStatus = "Profil olduğu gibi kaydediliyor…"
        lastError = nil
        let generation = targetSpeakerEnrollmentGeneration
        let progressHandler: TargetSpeakerProgressHandler = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.isCurrentTargetSpeakerEnrollment(generation) else { return }
                self.targetSpeakerPreparationProgress = progress.fractionCompleted
                self.targetSpeakerPreparationMessage = progress.message
            }
        }
        targetSpeakerEnrollmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.targetSpeakerEnrollmentGeneration == generation {
                    self.targetSpeakerEnrollmentIsProcessing = false
                    self.targetSpeakerPreparationProgress = nil
                    self.targetSpeakerPreparationMessage = ""
                    self.targetSpeakerEnrollmentTask = nil
                }
            }
            await self.createTargetSpeakerEnrollmentProfile(
                generation: generation, progressHandler: progressHandler,
                fallbackFailedIndex: rejected.recordings.count - 1, acceptedScore: rejected.score)
        }
    }

    func cancelTargetSpeakerEnrollment() {
        owLog("[TargetSpeaker] cancelTargetSpeakerEnrollment called")
        invalidateTargetSpeakerEnrollmentWork()
        _ = teardownTargetSpeakerEnrollmentRecording()
        targetSpeakerEnrollmentActive = false
        targetSpeakerEnrollmentIsProcessing = false
        targetSpeakerEnrollmentStep = 0
        targetSpeakerEnrollmentRecordings = []
        targetSpeakerRejectedEnrollment = nil
        targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentPromptText
        targetSpeakerPreparationProgress = nil
        targetSpeakerPreparationMessage = ""
        targetSpeakerEnrollmentStatus = ""
    }

    /// Deletes the buds or external-mic profile; the Mac one goes through `deleteTargetSpeakerProfile`.
    func deleteMicTargetSpeakerProfile(_ mic: TargetSpeakerMic) {
        owLog("[TargetSpeaker] deleteMicTargetSpeakerProfile called (mic=\(mic))")
        guard mic != .mac else { return }
        if targetSpeakerEnrollmentActive && targetSpeakerEnrollmentMic == mic { cancelTargetSpeakerEnrollment() }
        do {
            try targetSpeakerProfileStore(for: mic).delete()
            setMicTargetSpeakerProfile(mic, profile: nil, stored: false, status: "Henüz kayıt yok")
            targetSpeakerLowScores[mic.rawValue] = nil
            if lastConfirmedAppendMic == mic { lastConfirmedAppendReceipt = nil }
            owLog("[TargetSpeaker] \(mic) profile deleted")
        } catch {
            lastError = error.localizedDescription
            owLog("[TargetSpeaker] Delete \(mic) profile failed: \(error)")
        }
    }

    func deleteTargetSpeakerProfile() {
        owLog("[TargetSpeaker] deleteTargetSpeakerProfile called")
        invalidateTargetSpeakerEnrollmentWork()
        _ = teardownTargetSpeakerEnrollmentRecording()
        do {
            try targetSpeakerProfileStore.delete()
            targetSpeakerProfile = nil
            refreshTargetSpeakerProfileCoherence()
            hasStoredTargetSpeakerProfile = false
            targetSpeakerLowScores[TargetSpeakerMic.mac.rawValue] = nil
            if lastConfirmedAppendMic == .mac { lastConfirmedAppendReceipt = nil }
            targetSpeakerEnabled = false
            targetSpeakerProfileStatus = "Henüz kayıt yok"
            targetSpeakerEnrollmentStatus = "Ses profili silindi."
            targetSpeakerEnrollmentActive = false
            targetSpeakerEnrollmentIsProcessing = false
            targetSpeakerEnrollmentStep = 0
            targetSpeakerEnrollmentRecordings = []
            targetSpeakerEnrollmentPrompt = Self.targetSpeakerEnrollmentPromptText
            targetSpeakerPreparationProgress = nil
            targetSpeakerPreparationMessage = ""
            lastError = nil
            owLog("[TargetSpeaker] Target speaker profile deleted")
        } catch {
            lastError = error.localizedDescription
            owLog("[TargetSpeaker] Delete target speaker profile failed: \(error)")
        }
    }

    func undoLastConfirmedTargetSpeakerAppend() {
        owLog("[TargetSpeaker] undoLastConfirmedTargetSpeakerAppend called")
        guard let receipt = lastConfirmedAppendReceipt else {
            owLog("[TargetSpeaker] undoLastConfirmedTargetSpeakerAppend: no receipt available")
            return
        }
        do {
            try targetSpeakerFilter.undoConfirmedAppend(receipt, store: targetSpeakerProfileStore(for: lastConfirmedAppendMic))
            adoptTargetSpeakerProfile(receipt.previousProfile, for: lastConfirmedAppendMic, status: "Son ekleme geri alındı")
            lastConfirmedAppendReceipt = nil
            lastError = nil
            owLog("[TargetSpeaker] Last confirmed append undone successfully; restored embeddings count=\(receipt.previousProfile.embeddings.count)")
        } catch {
            lastError = error.localizedDescription
            owLog("[TargetSpeaker] Undo last confirmed append failed: \(error)")
        }
    }

    func replaceTargetSpeakerProfile(for mic: TargetSpeakerMic = .mac) {
        owLog("[TargetSpeaker] replaceTargetSpeakerProfile called (mic=\(mic))")
        guard !targetSpeakerEnrollmentIsProcessing else { return }
        if targetSpeakerEnrollmentIsRecording {
            _ = teardownTargetSpeakerEnrollmentRecording()
        }
        beginTargetSpeakerEnrollment(for: mic)
    }
}

/// An enrollment the quality check turned down: both recordings and the score it measured.
struct TargetSpeakerRejectedEnrollment {
    let recordings: [[Float]]
    let score: Float
}
