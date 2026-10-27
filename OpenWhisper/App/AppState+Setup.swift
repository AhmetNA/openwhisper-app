import SwiftUI
import Observation
import AVFoundation
import ApplicationServices
import ServiceManagement
import UserNotifications
import QuartzCore
import os

extension AppState {
    func applyVoiceProvider() {
        JarvisVoice.shared.reloadProvider()
        if voiceRepliesEnabled { Task { await JarvisVoice.shared.prepare() } }
    }

    func applyDecisionEngine() {
        guard decisionEngine.usesSetFit else {
            SetFitDecider.shared.stop()
            setFitStatus = SetFitDecider.shared.status
            return
        }
        setFitStatus = "Başlatılıyor…"
        Task {
            await SetFitDecider.shared.prepare()
            setFitStatus = SetFitDecider.shared.status
        }
    }

    func setup() async {
        owLog("[OpenWhisper] Setting up...")
        savedRecordings = await recordingHistoryStore.items()
        if launchAtLogin && SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
        audioEngine = AudioEngine()
        // Off the Fn-press path: DeepFilterNet's ~170ms model load happens once here instead of
        // on first use of that mode.
        let audioEngineForPrewarm = audioEngine
        DispatchQueue.global(qos: .utility).async {
            audioEngineForPrewarm?.prewarmDeepFilter()
        }
        llmCleanup = LLMCleanup(model: ollamaModel)
        if damgaEnabled && language == "tr" { Task { await DamgaNormalizer.shared.prepare() } }
        textInjector = TextInjector()
        flowBarController = FlowBarController(appState: self)
        typedRequestPanel = TypedRequestPanelController(appState: self)
        syncFlowBarVisibility()

        loadTargetSpeakerProfile()
        startTargetSpeakerDiarizationPreparation()
        // The local voice model takes ~15 s to load; do it now rather than on the first reply.
        if voiceRepliesEnabled { Task { await JarvisVoice.shared.prepare() } }
        // SetFit models load in ~5 s; start them with the app rather than on the first decision.
        if decisionEngine.usesSetFit { applyDecisionEngine() }

        // Request mic permission
        microphoneGranted = await audioEngine?.requestPermission() ?? false
        owLog("[OpenWhisper] Microphone permission: \(microphoneGranted)")

        // Keep Bluetooth buds out of call mode before anything opens the mic.
        DefaultInputGuard.shared.start()

        // Enumerate input devices for the picker + BT detection
        refreshInputDevices()
        owLog("[OpenWhisper] Input devices: \(availableInputDevices.map(\.name).joined(separator: ", ")), default-is-BT: \(systemDefaultInputIsBluetooth), priority: \(inputPriority.map(\.name).joined(separator: " > "))")
        InputDeviceWatcher.shared.start(onDefaultInputChange: { [weak self] in
            self?.systemInputDeviceChanged()
        }, onChange: { [weak self] in self?.refreshInputDevices() })

        // Check accessibility
        accessibilityGranted = GlobalHotkey.checkAccessibility(prompt: true)
        owLog("[OpenWhisper] Accessibility: \(accessibilityGranted)")

        // Manual correction review (Option+Shift+C) feedback: DictationSnapshot deliberately
        // has no AppState/AppKit dependency, so it reports outcomes through a plain closure
        // instead. Duration varies by message — the "nothing happened" messages are shorter
        // than the ones confirming something was actually learned or explicitly rejected.
        DictationSnapshot.shared.onManualReviewResult = { [weak self] message in
            let shortMessages: Set<String> = [
                "karşılaştırılacak dikte yok", "değişiklik yok", "uygun düzeltme bulunamadı", "metin okunamadı"
            ]
            let durationMs = shortMessages.contains(message) ? 2000 : 2500
            self?.showFlowBarMessage(message, durationMs: durationMs)
        }

        // Register global hotkey
        hotkey = GlobalHotkey(
            onPress: { [weak self] in
                let now = CACurrentMediaTime()
                let delayMs = (now - GlobalHotkey.lastFnPressUptime) * 1000
                owLog("[Perf] [HotkeyCallback] onPress callback triggered (+\(String(format: "%.2f", delayMs))ms from Fn press)")
                DispatchQueue.main.async {
                    let mainNow = CACurrentMediaTime()
                    let mainDelayMs = (mainNow - GlobalHotkey.lastFnPressUptime) * 1000
                    owLog("[Perf] [StartRecordingDispatch] startRecording scheduled on Main thread (+\(String(format: "%.2f", mainDelayMs))ms from Fn press)")
                    self?.startRecording()
                }
            },
            onRelease: { [weak self] in
                DispatchQueue.main.async { self?.stopRecordingWithTail() }
            },
            onSwapCommit: { [weak self] in
                DispatchQueue.main.async { self?.commitSwap() }
            },
            onCorrectionReview: { [weak self] in
                Task { @MainActor in
                    guard self != nil else { return }
                    DictationSnapshot.shared.reviewCurrentDifference()
                    owLog("[OpenWhisper] Manual correction review requested (⌥⇧C)")
                }
            }
        )
        hotkey?.onVoiceSessionRequest = { [weak self] in
            Task { @MainActor in
                owLog("[OpenWhisper] Voice session requested (Vocal Shortcut)")
                self?.startVoiceSession()
            }
        }
        hotkey?.jarvisKey = jarvisHotkey
        hotkey?.typedRequestKey = typedRequestHotkey
        hotkey?.onTypedRequestKey = { [weak self] in
            DispatchQueue.main.async { self?.toggleTypedRequestPanel() }
        }
        hotkey?.onSystemKeyDuringCapture = { [weak self] nxKeyType in
            DispatchQueue.main.async {
                guard let self else { return }
                self.jarvisCaptureSystemKey = .init(nxKeyType: nxKeyType,
                                                    sequence: (self.jarvisCaptureSystemKey?.sequence ?? 0) + 1)
            }
        }
        // Main queue, like onPress: a Fn hold's startRecording dispatch runs before this.
        hotkey?.onJarvisKey = { [weak self] cancelledFnHold in
            DispatchQueue.main.async { self?.handleJarvisKey(cancelledFnHold: cancelledFnHold) }
        }
        hotkey?.onHandsFreeChange = { [weak self] active in
            Task { @MainActor in
                guard let self else { return }
                self.handsFreeActive = active
                // Fn hold → Space: same recording, now hands-free.
                if active, let trigger = self.hotkey?.trigger, self.recordingState == .recording {
                    self.activeTranscriptionSession?.trigger = trigger
                }
            }
        }
        hotkey?.register()
        owLog("[OpenWhisper] Hotkey registered (Fn/Globe)")

        // Load Whisper model
        owLog("[OpenWhisper] Loading model: \(transcriptionModel)...")
        if transcriptionModelRegistry.provider(for: transcriptionModel) is WhisperKitTranscriptionProvider {
            whisperSuspendedForIdle = true
        } else {
            await loadModel()
        }
        startWhisperIdleMonitoring()
        owLog("[OpenWhisper] Model loaded: \(modelLoaded)")

        setupWakeWordListener()
        setupRemoteControl()

        // Check Ollama availability
        await refreshOllamaStatus()
        owLog("[OpenWhisper] Ollama available: \(ollamaAvailable)")
        owLog("[OpenWhisper] Selected cleanup available: \(cleanupAvailable)")

        // Setup reminders
        reminderManager = ReminderManager.shared
        let notifGranted = await reminderManager?.requestPermission() ?? false
        owLog("[OpenWhisper] Notification permission: \(notifGranted)")
        setupTimers()
        setupWhatsAppAnnouncements()
        owLog("[OpenWhisper] Ready!")
    }

    func downloadedTranscriptionModelNames() -> [String] {
        transcriptionModelRegistry.providers.values
            .filter(\.isDownloaded)
            .map { $0.descriptor.id }
            .sorted()
    }

    func transcriptionModelCatalog() -> [(name: String, label: String)] {
        transcriptionModelRegistry.availableProviders.map {
            (name: $0.descriptor.id, label: $0.descriptor.displayName)
        }
    }

    /// User-installed providers (manifest discovered from the user-writable STTProviders
    /// directory) that are not yet approved to run. `.bundled` providers never appear here --
    /// they're trusted like the rest of the app and have no gate to clear. See
    /// `ExternalSTTProvider`'s approval gate for why this exists.
    func pendingProviderApprovals() -> [PendingProviderApproval] {
        transcriptionModelRegistry.providers.values
            .compactMap { $0 as? ExternalSTTProvider }
            .filter { $0.trust == .userInstalled && !$0.isApproved() }
            .map { provider -> PendingProviderApproval in
                // manifestPath is always present; pythonPath/bridgePath are nil when
                // resolveRuntime() rejected the provider (e.g. bridge escapes the manifest
                // directory, or no allowlisted interpreter matched). We deliberately do NOT drop
                // those providers here -- the most suspicious manifest is exactly the one that
                // failed resolution, and it must still show up in Settings instead of vanishing
                // with only a log line as the trace.
                let paths = provider.approvalDisplayPaths
                return PendingProviderApproval(
                    id: provider.descriptor.id,
                    displayName: provider.descriptor.displayName,
                    manifestPath: paths.manifestPath,
                    pythonPath: paths.pythonPath,
                    bridgePath: paths.bridgePath
                )
            }
            .sorted { $0.displayName < $1.displayName }
    }

    /// Records the user's explicit approval, fingerprinted to the provider's current
    /// manifest+bridge bytes so a later file change silently revokes it again.
    func approveProvider(id: String) {
        guard let provider = transcriptionModelRegistry.provider(for: id) as? ExternalSTTProvider else { return }
        provider.approve()
    }

    func revokeProviderApproval(id: String) {
        guard let provider = transcriptionModelRegistry.provider(for: id) as? ExternalSTTProvider else { return }
        provider.revokeApproval()
    }

    /// User-installed providers currently approved to run, so Settings can offer a revoke action.
    func approvedUserInstalledProviderIDs() -> [String] {
        transcriptionModelRegistry.providers.values
            .compactMap { $0 as? ExternalSTTProvider }
            .filter { $0.trust == .userInstalled && $0.isApproved() }
            .map(\.descriptor.id)
            .sorted()
    }

    func loadModel() async {
        // A record request can arrive while the idle release is still finishing.
        if let unload = whisperUnloadTask { await unload.value }
        if let loading = transcriptionModelLoadTask {
            await loading.value
            return
        }
        let loading = Task { await performTranscriptionModelLoad() }
        transcriptionModelLoadTask = loading
        await loading.value
        transcriptionModelLoadTask = nil
    }

    private func performTranscriptionModelLoad() async {
        modelLoaded = false
        modelLoading = true
        modelLoadProgress = 0
        // A saved choice that is no longer offered (e.g. the removed Qwen3-ASR options) falls
        // back to the default instead of leaving dictation without a model.
        if transcriptionModelRegistry.provider(for: transcriptionModel) == nil,
           transcriptionModel != TranscriptionModelRegistry.defaultModelID {
            owLog("[OpenWhisper] Model \(transcriptionModel) no longer offered; using \(TranscriptionModelRegistry.defaultModelID)")
            transcriptionModel = TranscriptionModelRegistry.defaultModelID
        }
        guard let provider = transcriptionModelRegistry.provider(for: transcriptionModel) else {
            modelLoading = false
            lastError = "Seçili konuşma modeli bulunamadı: \(transcriptionModel)"
            owLog("[OpenWhisper] Model provider not found: \(transcriptionModel)")
            return
        }
        // Only one speech model stays in memory: Qwen runs in its own server, Whisper in-process.
        if LocalQwenASRProvider.isQwen(provider.descriptor.id) {
            await transcriptionModelRegistry.unloadWhisperKit()
        } else {
            await QwenASRServer.shared.stop()
        }
        modelIsDownloading = !provider.isDownloaded
        owLog("[OpenWhisper] Loading model: \(provider.descriptor.id) (download needed: \(modelIsDownloading))...")
        do {
            try await provider.loadModel { [weak self] progress in
                Task { @MainActor in
                    self?.modelLoadProgress = progress
                }
            }
            lastWhisperActivity = Date()
            modelLoaded = true
            whisperSuspendedForIdle = false
            modelLoading = false
            owLog("[OpenWhisper] Model loaded: \(modelLoaded)")
        } catch {
            modelLoading = false
            lastError = "Failed to load model: \(error.localizedDescription)"
            owLog("[OpenWhisper] Model load failed: \(error)")
        }
    }

    /// Handles openwhisper://start | stop | toggle, used by Siri Vocal Shortcuts / Shortcuts.
    func handleExternalURL(_ url: URL) {
        guard url.scheme?.lowercased() == "openwhisper" else { return }
        if url.host?.lowercased() == "voicetest" {
            VoiceTestInjector.shared.handle(url)
            return
        }
        let action = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let hotkey else {
            owLog("[OpenWhisper] URL trigger '\(action)' ignored — setup not finished yet")
            return
        }
        owLog("[OpenWhisper] URL trigger: \(action)")
        switch action {
        case "start": startVoiceSession()
        case "stop": hotkey.externalStopHandsFree()
        case "toggle", "":
            armVoiceAutoStopForNextRecording = hotkey.isIdle
            hotkey.externalToggleHandsFree()
        default: owLog("[OpenWhisper] Unknown URL action: \(action)")
        }
    }

    /// Cleanup counts as available only when the selected model is actually installed, not
    /// merely when Ollama is running. When it is, the model is loaded in the background so the
    /// first dictation doesn't wait on the cold load.
    func refreshOllamaStatus() async {
        ollamaAvailable = await LLMCleanup.checkAvailability()
        let model = ollamaModel
        cleanupAvailable = ollamaAvailable ? await LLMCleanup.isModelInstalled(model) : false
        if cleanupAvailable && llmCleanupEnabled {
            Task.detached(priority: .utility) { await LLMCleanup.warmUp(model: model) }
        }
    }
}
