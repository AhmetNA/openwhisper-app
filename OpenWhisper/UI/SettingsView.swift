import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppState.self) var appState

    @State private var spotifyClientID: String = ""
    @State private var spotifyClientSecret: String = ""
    @State private var spotifyTestState: SpotifyTestState = .idle
    @State private var spotifyHasStoredSecret: Bool = false
    @State private var spotifyConnected: Bool = false
    @State private var spotifyConnectState: SpotifyConnectState = .idle

    @State private var checkpointsInput: String = DictationSnapshot.shared.checkpointsString
    @State private var checkpointsWarning: String? = nil
    @State private var spotifyConnectTask: Task<Void, Never>?

    enum SpotifyTestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    enum SpotifyConnectState: Equatable {
        case idle
        case connecting
        case failure(String)
    }

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 14) {
            audioProcessingSection

            Divider()

            whisperModelSection

            Divider()

            // Language
            HStack {
                Label("Language", systemImage: "globe")
                Spacer()
                Picker("", selection: $appState.language) {
                    Text("Auto-detect").tag("")
                    Text("English").tag("en")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Hindi").tag("hi")
                    Text("Telugu").tag("te")
                    Text("Tamil").tag("ta")
                    Text("Kannada").tag("kn")
                    Text("Malayalam").tag("ml")
                    Text("Bengali").tag("bn")
                    Text("Marathi").tag("mr")
                    Text("Gujarati").tag("gu")
                    Text("Urdu").tag("ur")
                    Text("Punjabi").tag("pa")
                    Text("Japanese").tag("ja")
                    Text("Chinese").tag("zh")
                    Text("Korean").tag("ko")
                    Text("Russian").tag("ru")
                    Text("Portuguese").tag("pt")
                    Text("Arabic").tag("ar")
                    Text("Italian").tag("it")
                    Text("Dutch").tag("nl")
                    Text("Turkish").tag("tr")
                    Text("Polish").tag("pl")
                    Text("Thai").tag("th")
                    Text("Vietnamese").tag("vi")
                    Text("Indonesian").tag("id")
                    Text("Ukrainian").tag("uk")
                    Text("Swedish").tag("sv")
                }
                .labelsHidden()
                .frame(width: 150)
            }

            // Input device
            inputDeviceSection

            Divider()

            targetSpeakerSection

            Divider()

            // LLM Cleanup
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("LLM Cleanup", systemImage: "sparkles")
                    Spacer()
                    if appState.llmCleanupEnabled {
                        Circle()
                            .fill(appState.ollamaAvailable ? .green : .red)
                            .frame(width: 6, height: 6)
                            .help(appState.ollamaAvailable ? "Ollama connected" : "Ollama not running")
                    }
                    Toggle("", isOn: $appState.llmCleanupEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }

                if appState.llmCleanupEnabled {
                    HStack {
                        Text("AI Model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $appState.ollamaModel) {
                            Text("⚡ Aşırı Hızlı (Llama 3.2 3B)").tag("llama3.2:3b")
                            Text("🧠 Yüksek Zekalı (Qwen 3 8B)").tag("qwen3:8b")
                        }
                        .labelsHidden()
                        .frame(width: 195)
                    }
                }
            }

            Divider()

            // Spotify
            spotifySection

            Divider()

            // Learned Corrections
            correctionsSection

            Divider()

            // Model loading status
            if appState.modelLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.modelLoadProgress > 0
                         ? (appState.modelIsDownloading
                            ? "Downloading \(appState.whisperModel) model — \(Int(appState.modelLoadProgress * 100))%"
                            : "Switching to \(appState.whisperModel) model...")
                         : "Loading \(appState.whisperModel) model...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if !appState.modelLoaded {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                    Text("Model not loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Last error
            if let error = appState.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()

            // Footer
            HStack {
                Text("v1.0.0")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit OpenWhisper") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .font(.callout)
            }
        }
        .padding(16)
        .frame(width: 330)
        .onAppear {
            appState.refreshPermissions()
        }
    }

    // MARK: - Audio Processing Section

    private var audioProcessingSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 7) {
            Label("Ses işleme", systemImage: "waveform.and.mic")

            Picker("Ses işleme modu", selection: $appState.audioProcessingMode) {
                Text("Engelsiz").tag(AudioProcessingMode.off)
                Text("DeepFilter").tag(AudioProcessingMode.deepFilterNet)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .disabled(appState.recordingState != .idle)

            Text(appState.recordingState == .idle
                 ? audioProcessingModeDescription
                 : "Kayıt sürerken değiştirilemez; sonraki kayda uygulanır.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var audioProcessingModeDescription: String {
        switch appState.audioProcessingMode {
        case .off:
            return "Gürültü engelleme yok, en hızlı başlangıç. Seçim bir sonraki kayıtta uygulanır."
        case .deepFilterNet:
            return "Yerel bir sinir ağı (DeepFilterNet 3) gürültüyü temizler; başlangıç gecikmesi eklemez. Seçim bir sonraki kayıtta uygulanır."
        case .appleVoiceProcessing:
            return "Apple'ın gürültü engelleme + otomatik kazanç sistemi. Fn'e basıldıktan sonra mikrofonun açılmasını ~1 saniye geciktirir (ölçülen: ~900ms-1.1sn). Seçim bir sonraki kayıtta uygulanır."
        }
    }

    // MARK: - Whisper Model Section

    /// Known variant names paired with a friendly Turkish label. Entries not yet downloaded stay
    /// selectable so the picker doubles as the way to kick off a first-time download of a new
    /// model; a cloud glyph marks which ones that applies to.
    private static let whisperModelCatalog: [(name: String, label: String)] = [
        ("large-v3-v20240930_turbo", "Turbo (Hızlı)"),
        ("large-v3_turbo", "Large v3 Turbo (Argmax)"),
        ("large-v3", "Large v3 (Tam, en yavaş)"),
    ]

    private var whisperModelSection: some View {
        @Bindable var appState = appState
        let switching = appState.modelLoading || appState.recordingState != .idle
        let downloaded = Set(appState.downloadedWhisperModelNames())
        let catalog = Self.whisperModelCatalog
        let extraDownloaded = downloaded
            .subtracting(catalog.map(\.name))
            .sorted()

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Whisper modeli", systemImage: "waveform")
                Spacer()
                Picker("", selection: Binding(
                    get: { appState.whisperModel },
                    set: { newValue in
                        guard newValue != appState.whisperModel else { return }
                        appState.whisperModel = newValue
                        Task { await appState.loadModel() }
                    }
                )) {
                    ForEach(catalog, id: \.name) { entry in
                        Text(downloaded.contains(entry.name) ? entry.label : "☁️ \(entry.label)")
                            .tag(entry.name)
                    }
                    ForEach(extraDownloaded, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .disabled(switching)
            }

            Text(downloaded.isEmpty
                 ? "☁️ = henüz inmedi, seçince indirilir."
                 : "İnmiş modeller: \(downloaded.sorted().joined(separator: ", ")). ☁️ = henüz inmedi, seçince indirilir.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Input Device Section

    private var inputDeviceSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Input", systemImage: "mic.and.signal.meter")
                Spacer()
                Picker("", selection: Binding(
                    get: { appState.inputDeviceUID ?? "" },
                    set: { appState.inputDeviceUID = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Otomatik (Kulaklık → Mac)").tag("")
                    if let builtIn = appState.builtInInputDevice {
                        Text("Mac Mikrofonu").tag(builtIn.uid)
                    }
                    if let headset = appState.externalHeadsetDevice {
                        Text(headset.isBluetooth ? "🔵 \(headset.name)" : headset.name).tag(headset.uid)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            if appState.resolvedInputIsBluetooth {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("Bluetooth kulaklıklar dikte sırasında düşük kaliteli görüşme moduna geçer; en iyi ses kalitesi için Mac mikrofonunu seçebilirsiniz.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 22)
            }
        }
        .onAppear {
            appState.refreshInputDevices()
        }
    }

    // MARK: - Target Speaker Section

    private var targetSpeakerSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Yalnızca Benim Sesim", systemImage: "person.wave.2")
                Spacer()
                Toggle("", isOn: $appState.targetSpeakerEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(!appState.hasTargetSpeakerProfile && !appState.targetSpeakerEnabled)
            }

            HStack(spacing: 8) {
                Image(systemName: appState.hasTargetSpeakerProfile
                      ? "checkmark.circle.fill" : "info.circle")
                    .foregroundStyle(appState.hasTargetSpeakerProfile ? .green : .orange)
                Text(appState.targetSpeakerProfileStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }

            if appState.hasStoredTargetSpeakerProfile {
                HStack(spacing: 12) {
                    Text("Örnek sayısı: \(appState.targetSpeakerEmbeddingCount)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let coherence = appState.targetSpeakerProfileCoherence {
                        Text("Profil tutarlılığı: \(String(format: "%.2f", coherence))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if appState.canUndoTargetSpeakerAppend {
                        Spacer()
                        Button("Son eklemeyi geri al") {
                            owLog("[TargetSpeaker] User clicked 'Son eklemeyi geri al' in SettingsView")
                            appState.undoLastConfirmedTargetSpeakerAppend()
                        }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    }
                }
            }

            if appState.targetSpeakerEnrollmentActive {
                Text(appState.targetSpeakerEnrollmentIsRecording
                     ? "Kayıt \(appState.targetSpeakerEnrollmentStep + 1)/2: \(Int(appState.recordingDuration))/30 sn — \(appState.targetSpeakerEnrollmentPrompt)"
                     : appState.targetSpeakerEnrollmentStatus)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let progress = appState.targetSpeakerPreparationProgress {
                    ProgressView(value: progress)
                } else if appState.targetSpeakerEnrollmentIsProcessing {
                    ProgressView()
                }
                if !appState.targetSpeakerPreparationMessage.isEmpty {
                    Text(appState.targetSpeakerPreparationMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(appState.targetSpeakerEnrollmentIsRecording ? "Kaydı bitir" : "Sesimi kaydet") {
                    if appState.targetSpeakerEnrollmentIsRecording {
                        owLog("[TargetSpeaker] User clicked 'Kaydı bitir' in SettingsView")
                        appState.stopTargetSpeakerEnrollmentRecording()
                    } else {
                        owLog("[TargetSpeaker] User clicked 'Sesimi kaydet' in SettingsView")
                        if !appState.targetSpeakerEnrollmentActive {
                            appState.beginTargetSpeakerEnrollment()
                        }
                        appState.startTargetSpeakerEnrollmentRecording()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.targetSpeakerEnrollmentIsProcessing)

                if appState.targetSpeakerEnrollmentActive {
                    Button("İptal") {
                        owLog("[TargetSpeaker] User clicked 'İptal' enrollment in SettingsView")
                        appState.cancelTargetSpeakerEnrollment()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }

                if appState.hasTargetSpeakerProfile || appState.hasStoredTargetSpeakerProfile {
                    Button("Yenile") {
                        owLog("[TargetSpeaker] User clicked 'Yenile' profile in SettingsView")
                        appState.replaceTargetSpeakerProfile()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .disabled(appState.targetSpeakerEnrollmentIsProcessing)
                    Button("Sil") {
                        owLog("[TargetSpeaker] User clicked 'Sil' profile in SettingsView")
                        appState.deleteTargetSpeakerProfile()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.caption)
                }

            }
        }
    }

    // MARK: - Spotify Section

    private var spotifySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spotify")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text("Client ID")
                    .font(.caption)
                    .frame(width: 90, alignment: .leading)
                TextField("", text: $spotifyClientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .autocorrectionDisabled()
            }

            HStack {
                Text("Client Secret")
                    .font(.caption)
                    .frame(width: 90, alignment: .leading)
                SecureField(spotifyHasStoredSecret ? "••••••••" : "", text: $spotifyClientSecret)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                Button("Kaydet") {
                    saveSpotifyCredentials()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Bağlantıyı test et") {
                    testSpotifyConnection()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(spotifyTestState == .testing)

                Spacer()

                spotifyTestStatusView
            }

            Divider()

            Text("Beğenilen Şarkılar")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack {
                Text("Redirect URI")
                    .font(.caption)
                    .frame(width: 90, alignment: .leading)
                Text(SpotifyWebAPI.redirectURI)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(SpotifyWebAPI.redirectURI, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Kopyala")
            }

            HStack(spacing: 8) {
                if spotifyConnected {
                    Label("Bağlı", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Bağlantıyı kaldır") {
                        disconnectSpotifyAccount()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.caption)
                } else if spotifyConnectState == .connecting {
                    Button("İptal") {
                        cancelSpotifyConnect()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    spotifyConnectStatusView
                } else {
                    Button("Spotify hesabını bağla") {
                        connectSpotifyAccount()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    spotifyConnectStatusView
                }
            }
        }
        .onAppear {
            spotifyClientID = SpotifyCredentialsStore.loadClientID()
            spotifyHasStoredSecret = SpotifyCredentialsStore.hasClientSecret()
            spotifyConnected = SpotifyCredentialsStore.hasRefreshToken()
        }
    }

    @ViewBuilder
    private var spotifyConnectStatusView: some View {
        switch spotifyConnectState {
        case .idle:
            EmptyView()
        case .connecting:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Tarayıcıda Spotify girişini tamamlayın...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var spotifyTestStatusView: some View {
        switch spotifyTestState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView()
                .controlSize(.small)
        case .success:
            Label("Bağlandı", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    private func saveSpotifyCredentials() {
        let id = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = spotifyClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        // An empty secret field means "keep the existing stored secret" (SecureField never
        // pre-fills with the real value, so re-saving after just editing the Client ID
        // would otherwise wipe the secret). Only overwrite the secret when the user typed
        // a new one.
        var didSave = true
        if secret.isEmpty {
            if !id.isEmpty {
                let existing = SpotifyCredentialsStore.load()
                didSave = SpotifyCredentialsStore.save(clientID: id, clientSecret: existing?.clientSecret ?? "")
            }
        } else {
            didSave = SpotifyCredentialsStore.save(clientID: id, clientSecret: secret)
        }

        spotifyHasStoredSecret = SpotifyCredentialsStore.hasClientSecret()
        spotifyClientSecret = ""

        // Surface a Keychain write failure rather than silently pretending it worked —
        // otherwise every later command fails with a confusing "missing credentials"
        // message instead of the real cause.
        spotifyTestState = didSave ? .idle : .failure("Keychain'e kaydedilemedi")
    }

    private func testSpotifyConnection() {
        spotifyTestState = .testing
        Task {
            // Drop any cached token first: if the user just replaced the credentials, a
            // still-valid old token would make this button report "Bağlandı" without
            // actually checking the new ones.
            await SpotifyWebAPI.shared.invalidateAllCaches()
            do {
                try await SpotifyWebAPI.shared.testConnection()
                await MainActor.run { spotifyTestState = .success }
            } catch let error as SpotifyWebAPI.SpotifyAPIError {
                await MainActor.run { spotifyTestState = .failure(error.userMessage) }
            } catch {
                await MainActor.run { spotifyTestState = .failure("Bilinmeyen hata") }
            }
        }
    }

    /// This whole flow runs behind a MenuBarExtra popover (`.menuBarExtraStyle(.window)`):
    /// `SpotifyWebAPI.connectUserAccount()` opens the system browser via
    /// `NSWorkspace.shared.open`, which steals focus and — being a `.window`-style
    /// popover, not a persistent panel — closes it immediately, tearing down this view's
    /// `@State` (including the "İptal" button and whatever `spotifyConnectState` would
    /// have shown). The `Task` below isn't cancelled by that (it's a plain `Task {}`, not
    /// a `.task {}` view modifier), so it keeps running and its state writes are still
    /// safe — they just won't be visible if the user doesn't reopen the popover at the
    /// right moment. A system notification is the only outcome-reporting path guaranteed
    /// to reach the user regardless of popover state, so post one on every branch.
    private func connectSpotifyAccount() {
        spotifyConnectState = .connecting
        spotifyConnectTask = Task {
            do {
                try await SpotifyWebAPI.shared.connectUserAccount()
                await MainActor.run {
                    spotifyConnected = true
                    spotifyConnectState = .idle
                }
                postSpotifyConnectNotification(body: "Spotify hesabı bağlandı — beğenilen şarkılar artık aramalarda önceliklendirilecek.")
            } catch is CancellationError {
                // User-initiated via the "İptal" button — not an error to surface.
                await MainActor.run {
                    spotifyConnected = SpotifyCredentialsStore.hasRefreshToken()
                    spotifyConnectState = .idle
                }
            } catch let error as SpotifyWebAPI.SpotifyAPIError {
                await MainActor.run {
                    spotifyConnected = SpotifyCredentialsStore.hasRefreshToken()
                    spotifyConnectState = .failure(error.userMessage)
                }
                postSpotifyConnectNotification(body: "Spotify bağlantısı başarısız: \(error.userMessage)")
            } catch {
                await MainActor.run {
                    spotifyConnected = SpotifyCredentialsStore.hasRefreshToken()
                    spotifyConnectState = .failure("Bilinmeyen hata")
                }
                postSpotifyConnectNotification(body: "Spotify bağlantısı başarısız: bilinmeyen hata")
            }
            spotifyConnectTask = nil
        }
    }

    private func cancelSpotifyConnect() {
        spotifyConnectTask?.cancel()
    }

    private func postSpotifyConnectNotification(body: String) {
        let isError = body.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains("başarısız")
        OpenWhisperNotification.post(title: "🎵 Spotify", body: body, isError: isError, identifierPrefix: "spotify-connect")
    }

    private func disconnectSpotifyAccount() {
        Task {
            await SpotifyWebAPI.shared.disconnectUserAccount()
            await MainActor.run {
                spotifyConnected = false
                spotifyConnectState = .idle
            }
        }
    }

    // MARK: - Learned Corrections Section

    private var correctionsSection: some View {
        let store = CorrectionStore.shared
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Öğrenilen Düzeltmeler")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.learningEnabled },
                    set: { store.learningEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }

            if store.learningEnabled {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Kontrol noktaları (sn)")
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Spacer()
                        TextField("5, 10, 40", text: Binding(
                            get: { checkpointsInput },
                            set: { newValue in
                                checkpointsInput = newValue
                                if let _ = CorrectionEngine.parseCheckpoints(newValue) {
                                    DictationSnapshot.shared.checkpointsString = newValue
                                    checkpointsWarning = nil
                                } else {
                                    checkpointsWarning = "Geçersiz girdi. En fazla 60 adet, 1-300 saniye arası virgülle ayrılmış sayı girin (örn: 1, 2, 3... 30)."
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 110)
                    }

                    Text("Yapıştırılan metni elle düzeltmen için tanınan kontrol anları.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let warning = checkpointsWarning {
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)

                Divider()

                let pendingCount = store.records.filter { $0.status == .candidate }.count
                let totalCount = store.records.count

                Button {
                    CorrectionsWindowController.shared.show()
                } label: {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(pendingCount > 0 ? .orange : .blue)
                        Text("Onaylar")
                            .font(.caption.weight(.bold))
                        Spacer()
                        if pendingCount > 0 {
                            Text("\(pendingCount) Onay Bekliyor")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.orange))
                                .foregroundStyle(.white)
                        } else {
                            Text("Bekleyen Yok (\(totalCount) Kayıtlı)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Düzenlemeyi bitirince ⌥⇧C ile farkları hemen onaya gönder.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            checkpointsInput = DictationSnapshot.shared.checkpointsString
        }
    }

    private func openSystemSettings(_ url: String) {
        if let url = URL(string: url) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Dedicated Corrections Management Window

@MainActor
final class CorrectionsWindowController: NSObject, NSWindowDelegate {
    static let shared = CorrectionsWindowController()
    private var window: NSWindow?

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = CorrectionsManagementView(onClose: { [weak self] in
            self?.close()
        })

        let hostingController = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Öğrenilen Düzeltmeler & Onaylar"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("CorrectionsManagementWindow")
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct CorrectionsManagementView: View {
    var onClose: (() -> Void)?
    @State private var newWrong: String = ""
    @State private var newRight: String = ""
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all = "Tümü"
        case candidate = "Onay Bekleyenler"
        case active = "Aktif"
        case disabled = "Reddedilenler"
    }

    private func statusPriority(_ status: CorrectionStore.Status) -> Int {
        switch status {
        case .candidate: return 0
        case .active: return 1
        case .disabled: return 2
        }
    }

    var body: some View {
        let store = CorrectionStore.shared
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Label("Öğrenilen Düzeltmeler & Onaylar", systemImage: "wand.and.stars")
                    .font(.title2.weight(.bold))
                Spacer()
                if let onClose = onClose {
                    Button("Kapat") {
                        onClose()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }

            Text("Metin alanlarında elle yaptığın düzeltmeler burada listelenir. Bekleyen adayları onaylayarak otomatik aktifleştirebilir, önemsiz olanları listeden kaldırabilirsin.")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Segmented Picker Filter
            Picker("", selection: $filter) {
                let pendingCount = store.records.filter { $0.status == .candidate }.count
                let activeCount = store.records.filter { $0.status == .active }.count
                let disabledCount = store.records.filter { $0.status == .disabled }.count
                Text("Tümü (\(store.records.count))").tag(Filter.all)
                Text("Onay Bekleyenler (\(pendingCount))").tag(Filter.candidate)
                Text("Aktif (\(activeCount))").tag(Filter.active)
                Text("Reddedilenler (\(disabledCount))").tag(Filter.disabled)
            }
            .pickerStyle(.segmented)

            // Records List
            let filteredRecords = store.records.filter { record in
                switch filter {
                case .all: return true
                case .candidate: return record.status == .candidate
                case .active: return record.status == .active
                case .disabled: return record.status == .disabled
                }
            }.sorted { r1, r2 in
                let p1 = statusPriority(r1.status)
                let p2 = statusPriority(r2.status)
                if p1 != p2 {
                    return p1 < p2
                }
                return r1.lastSeen > r2.lastSeen
            }

            if filteredRecords.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 40))
                        .foregroundStyle(.quaternary)
                    Text(filter == .candidate ? "Onay bekleyen düzeltme yok" : "Henüz kayıtlı düzeltme yok")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredRecords) { record in
                        correctionRow(record)
                    }
                }
                .listStyle(.inset)
            }

            Divider()

            // Manual Add Form
            HStack(spacing: 8) {
                Text("Manuel Ekle:")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("yanlış (örn: cloud)", text: $newWrong)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("doğru (örn: claude)", text: $newRight)
                    .textFieldStyle(.roundedBorder)
                Button("Ekle") {
                    store.addManual(wrong: newWrong, right: newRight)
                    newWrong = ""
                    newRight = ""
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(newWrong.trimmingCharacters(in: .whitespaces).isEmpty || newRight.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 540)
    }

    @ViewBuilder
    private func correctionRow(_ record: CorrectionStore.Record) -> some View {
        let store = CorrectionStore.shared
        // An active record that has never actually fired is effectively dead weight — flag it
        // with the same orange accent already used for "needs attention" elsewhere in this
        // section (see the pending-approvals badge above) so it's easy to spot in the list.
        let neverApplied = record.status == .active && record.appliedCount == 0
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(record.wrong)
                        .font(.title3)
                        .strikethrough()
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text(record.right)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                }
                Text("\(record.count) kez görüldü • \(record.appliedCount) kez uygulandı • \(statusText(record.status))")
                    .font(.caption)
                    // `.orange` is a Color and `.tertiary` is a HierarchicalShapeStyle — the two
                    // ternary branches don't unify under plain `some ShapeStyle` inference, so
                    // both sides must be type-erased to the same AnyShapeStyle.
                    .foregroundStyle(neverApplied ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
            }

            Spacer()

            switch record.status {
            case .candidate:
                HStack(spacing: 8) {
                    Button("Onayla") {
                        store.approve(id: record.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.regular)

                    Button("Önemsiz") {
                        store.discard(id: record.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .controlSize(.regular)

                    Button("Reddet") {
                        store.reject(id: record.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.regular)
                }
            case .active:
                HStack(spacing: 12) {
                    Toggle("Aktif", isOn: Binding(
                        get: { true },
                        set: { store.setDisabled(id: record.id, disabled: !$0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.regular)

                    Button {
                        store.delete(id: record.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            case .disabled:
                HStack(spacing: 12) {
                    Toggle("Aktif", isOn: Binding(
                        get: { false },
                        set: { store.setDisabled(id: record.id, disabled: !$0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.regular)

                    Button {
                        store.delete(id: record.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statusText(_ status: CorrectionStore.Status) -> String {
        switch status {
        case .candidate: return "Onay Bekliyor"
        case .active: return "Aktif"
        case .disabled: return "Kapalı"
        }
    }
}
