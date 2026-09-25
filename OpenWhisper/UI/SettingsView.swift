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

    /// Provider approval state lives in UserDefaults, not an @Observable stored property, so
    /// approve/revoke actions bump this to force `transcriptionModelSection` to recompute its
    /// pending/approved provider lists.
    @State private var providerApprovalRefreshToken = UUID()

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

    enum Tab: String, CaseIterable, Identifiable {
        case general, models, jarvis, voice, recordings, spotify, corrections, approvals, permissions

        var id: Self { self }
        var title: String {
            switch self {
            case .general: "Genel"
            case .models: "Modeller"
            case .jarvis: "Jarvis"
            case .voice: "Sesim"
            case .recordings: "Kayıtlar"
            case .spotify: "Spotify"
            case .corrections: "Düzeltmeler"
            case .approvals: "Onaylar"
            case .permissions: "İzinler"
            }
        }
        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .models: "waveform"
            case .jarvis: "ear"
            case .voice: "person.wave.2"
            case .recordings: "waveform.badge.mic"
            case .spotify: "music.note"
            case .corrections: "text.badge.checkmark"
            case .approvals: "checkmark.seal"
            case .permissions: "lock.shield"
            }
        }
    }

    @State private var selectedTab: Tab = .general

    // Read live by `WakeWordListener` / `TargetSpeakerFilter` on every score, so no restart needed.
    @AppStorage("wakeWordThreshold") private var wakeWordThreshold: Double = 0.25
    @AppStorage("wakeWordCandidateThreshold") private var wakeWordCandidateThreshold: Double = 0.12
    @AppStorage("wakeWordConfirmedScore") private var wakeWordConfirmedScore: Double = 0.5
    @AppStorage("targetSpeakerWakeThreshold") private var targetSpeakerWakeThreshold: Double = 0.40

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if selectedTab == .approvals {
                CorrectionsManagementView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(selectedTab.title)
                            .font(.title2.weight(.semibold))
                        tabContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .onAppear { appState.refreshPermissions() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OPENWHISPER")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            ForEach(Tab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.symbol)
                            .frame(width: 18)
                        Text(tab.title)
                        Spacer(minLength: 0)
                        if tab == .approvals {
                            let count = CorrectionStore.shared.records.filter { $0.status == .candidate }.count
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .background(selectedTab == tab ? Color.accentColor.opacity(0.13) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityValue(selectedTab == tab ? "Seçili" : "")
            }
            Spacer()
            Text("v1.0.0")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
        }
        .padding(12)
        .frame(width: 185)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .general:
            audioProcessingSection
            Divider()
            inputDeviceSection
            Divider()
            audioDuckingSection
            Divider()
            languageSection
            if let error = appState.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        case .models:
            transcriptionModelSection
            Divider()
            cleanupSection
            if appState.modelLoading {
                ProgressView("Model yükleniyor…")
            } else if !appState.modelLoaded {
                Label("Model hazır değil", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        case .jarvis:
            jarvisSection
        case .voice:
            targetSpeakerSection
        case .recordings:
            recordingsSection
        case .spotify:
            spotifySection
        case .corrections:
            correctionsSection
        case .approvals:
            EmptyView()
        case .permissions:
            PermissionsView()
        }
    }

    private var languageSection: some View {
        @Bindable var appState = appState
        return HStack {
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
    }

    private var cleanupSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("LLM Cleanup", systemImage: "sparkles")
                Spacer()
                Toggle("", isOn: $appState.llmCleanupEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if appState.llmCleanupEnabled {
                HStack {
                    Text("AI Model")
                    Spacer()
                    Picker("", selection: $appState.ollamaModel) {
                        ForEach(LLMCleanup.supportedModels, id: \.tag) { option in
                            Text(option.label).tag(option.tag)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
                if !appState.cleanupAvailable {
                    Text("Seçili model kurulu değil — terminalde: ollama pull \(appState.ollamaModel)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Divider()
            Toggle("Gülmeyi random'a çevir", isOn: $appState.laughterToRandomEnabled)
            Text("Ha ha ha, haha ve kahkaha gibi ifadeleri klavye satırından üretilen 8–10 harflik random'a dönüştürür.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Son 7 ses kaydı bu Mac'te saklanır. Bir kaydı seçince yeniden analiz edilir ve metin panoya kopyalanır.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if appState.savedRecordings.isEmpty {
                ContentUnavailableView("Henüz kayıt yok", systemImage: "waveform", description: Text("İlk dikteniz burada görünecek."))
            } else {
                ForEach(appState.savedRecordings) { recording in
                    Button {
                        appState.replayRecording(recording)
                    } label: {
                        HStack {
                            Image(systemName: "waveform")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recording.previewLabel)
                                    .fontWeight(.medium)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(recording.previewText == nil ? .secondary : .primary)
                                Text("\(Int(recording.duration.rounded())) sn · \(recording.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let stats = recording.stats {
                                    Text([recording.trigger?.title, stats.label].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .help(stats.logLines.joined(separator: "\n"))
                                }
                            }
                            Spacer()
                            if appState.replayingRecordingID == recording.id {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                    }
                    .buttonStyle(.bordered)
                    .disabled(appState.replayingRecordingID != nil || appState.recordingState != .idle)
                }
            }
            if let status = appState.replayStatus {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: appState.modelLoaded) {
            if appState.modelLoaded {
                appState.prepareRecordingPreviews()
            }
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

    private var transcriptionModelSection: some View {
        @Bindable var appState = appState
        let switching = appState.modelLoading || appState.recordingState != .idle
        let downloaded = Set(appState.downloadedTranscriptionModelNames())
        let catalog = appState.transcriptionModelCatalog()
        let extraDownloaded = downloaded
            .subtracting(catalog.map(\.name))
            .sorted()
        let pendingApprovals = appState.pendingProviderApprovals()
        let approvedUserInstalledIDs = appState.approvedUserInstalledProviderIDs()

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Konuşma modeli", systemImage: "waveform")
                Spacer()
                Picker("", selection: Binding(
                    get: { appState.transcriptionModel },
                    set: { newValue in
                        guard newValue != appState.transcriptionModel else { return }
                        appState.transcriptionModel = newValue
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

            if !pendingApprovals.isEmpty {
                providerApprovalRows(pendingApprovals)
                    .id(providerApprovalRefreshToken)
            }

            if !approvedUserInstalledIDs.isEmpty {
                approvedProviderRevokeRows(approvedUserInstalledIDs)
                    .id(providerApprovalRefreshToken)
            }
        }
    }

    /// One row per user-installed provider awaiting explicit approval. `manifestPath` is always
    /// shown -- the row itself must never disappear, even for a manifest whose bridge/python
    /// failed the security checks in `ExternalSTTProvider.resolveRuntime()` (that's the most
    /// suspicious case, and the one most important to surface). When the interpreter or bridge
    /// couldn't be resolved, that field reads "çözümlenemedi / reddedildi" and no approve button
    /// is offered -- there is nothing to approve (`approve()` would silently no-op since it can't
    /// compute a fingerprint), so we show a rejection notice pointing at the log instead.
    private func providerApprovalRows(_ approvals: [PendingProviderApproval]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(approvals) { approval in
                let isResolved = approval.pythonPath != nil && approval.bridgePath != nil

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: isResolved ? "exclamationmark.shield" : "xmark.shield")
                            .foregroundStyle(isResolved ? .orange : .red)
                        Text(isResolved
                             ? "\(approval.displayName) onay bekliyor"
                             : "\(approval.displayName) reddedildi")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }

                    Group {
                        Text("Manifest: \(approval.manifestPath)")
                        Text("Yorumlayıcı: \(approval.pythonPath ?? "çözümlenemedi / reddedildi")")
                        Text("Bridge: \(approval.bridgePath ?? "çözümlenemedi / reddedildi")")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                    if isResolved {
                        Text("Bu, kullanıcı dizininden keşfedilen bir sağlayıcı. Onaylarsanız yukarıdaki yorumlayıcı, Jarvis'in mikrofon ve Accessibility izinlerini miras alarak çalıştırılır.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Çalıştırmaya izin ver") {
                            appState.approveProvider(id: approval.id)
                            providerApprovalRefreshToken = UUID()
                        }
                        .font(.caption)
                    } else {
                        Text("Bu sağlayıcı güvenlik kontrolünden geçemediği için çalıştırılamaz; onaylanacak bir şey yok. Ayrıntı için /tmp/openwhisper.log dosyasına bakın.")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill((isResolved ? Color.orange : Color.red).opacity(0.10)))
            }
        }
    }

    /// Lets the user revoke a previously granted approval for a user-installed provider.
    private func approvedProviderRevokeRows(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ids, id: \.self) { id in
                HStack {
                    Text("\(id): çalıştırılmasına izin verildi")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("İzni kaldır") {
                        appState.revokeProviderApproval(id: id)
                        providerApprovalRefreshToken = UUID()
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.red)
                }
            }
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

    // MARK: - Audio Ducking Section

    private var audioDuckingSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Kayıtta medyayı duraklat", systemImage: "pause.circle")
                Spacer()
                Toggle("", isOn: $appState.audioDuckingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text("Safari, Spotify ve macOS medya denetimini destekleyen oynatıcılar kayıt sırasında duraklatılır. Kayıt bitince aynı içerik devam eder; ses seviyesi değişmez.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Jarvis Section

    private var jarvisSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("“Jarvis” ile sesle başlat", systemImage: "ear")
                    Spacer()
                    Toggle("", isOn: Binding(get: { appState.wakeWordEnabled },
                                             set: { appState.wakeWordEnabled = $0 }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                Text(appState.wakeWordStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("“Jarvis” veya “Hey Jarvis” dediğinizde kayıt başlar; susunca kendiliğinden biter ve komut (Spotify, hatırlatıcı…) ya da yazı olarak işlenir.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Hassasiyet", systemImage: "dial.medium")
                    Spacer()
                    Button("Varsayılanlar") {
                        for key in ["wakeWordThreshold", "wakeWordCandidateThreshold", "wakeWordConfirmedScore"] {
                            UserDefaults.standard.removeObject(forKey: key)
                        }
                        wakeWordThreshold = 0.25
                        wakeWordCandidateThreshold = 0.12
                        wakeWordConfirmedScore = 0.5
                    }
                    .controlSize(.small)
                }
                jarvisSlider("Doğrudan uyanma", value: $wakeWordThreshold, range: 0.10...0.90,
                             help: "Bu puanın üstünde hemen uyanır. Düşürürseniz daha az kaçırır ama yanlış uyanma artar.")
                jarvisSlider("Emin olmadan uyanma", value: $wakeWordConfirmedScore, range: 0.10...0.95,
                             help: "Doğrudan uyanma ile bu puan arası hemen başlar; Whisper arkada “Jarvis” duymazsa kayıt iptal edilir.")
                jarvisSlider("Aday", value: $wakeWordCandidateThreshold, range: 0.05...0.50,
                             help: "Bu puandan doğrudan uyanmaya kadar olan sesler önce Whisper ve Ollama ile kontrol edilir.")
                if wakeWordCandidateThreshold >= wakeWordThreshold {
                    Label("Aday eşiği doğrudan uyanma eşiğinden düşük olmalı.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Yalnızca benim sesimle uyan", systemImage: "person.wave.2")
                    Spacer()
                    Toggle("", isOn: Binding(get: { jarvisSpeakerCheckOn }, set: setJarvisSpeakerCheck))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!appState.hasTargetSpeakerProfile && !jarvisSpeakerCheckOn)
                }
                if appState.hasTargetSpeakerProfile {
                    jarvisSlider("Ses benzerliği", value: $targetSpeakerWakeThreshold, range: 0.20...0.80,
                                 help: "Log'da kendi sesinizin puanı bunun altında kalıyorsa düşürün.")
                        .disabled(!jarvisSpeakerCheckOn)
                } else {
                    HStack(spacing: 6) {
                        Text("Önce ses profili gerekli.")
                        Button("Sesim sekmesine git") { selectedTab = .voice }
                            .buttonStyle(.link)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var jarvisSpeakerCheckOn: Bool {
        appState.targetSpeakerEnabled && appState.targetSpeakerScope.coversWakeWord
    }

    /// Maps the Jarvis switch onto the shared "Yalnızca Benim Sesim" switch + scope, keeping the
    /// dictation half as it was.
    private func setJarvisSpeakerCheck(_ on: Bool) {
        let transcription = appState.targetSpeakerEnabled && appState.targetSpeakerScope.coversTranscription
        switch (on, transcription) {
        case (true, true): appState.targetSpeakerScope = .always
        case (true, false): appState.targetSpeakerScope = .wakeWordOnly
        case (false, true): appState.targetSpeakerScope = .transcriptionOnly
        case (false, false): break
        }
        appState.targetSpeakerEnabled = on || transcription
    }

    private func jarvisSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Slider(value: value, in: range, step: 0.01)
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            Text(help)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

            Picker("Nerede geçerli", selection: $appState.targetSpeakerScope) {
                ForEach(TargetSpeakerScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!appState.targetSpeakerEnabled)
            Text(appState.targetSpeakerScope.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            if appState.targetSpeakerSampleIsRecording
                || appState.targetSpeakerSampleIsProcessing
                || !appState.targetSpeakerSampleStatus.isEmpty {
                Text(appState.targetSpeakerSampleIsRecording
                     ? "Ses örneği: \(Int(appState.recordingDuration))/30 sn — \(appState.targetSpeakerSampleStatus)"
                     : appState.targetSpeakerSampleStatus)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if appState.targetSpeakerSampleIsProcessing {
                    ProgressView()
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
                .disabled(appState.targetSpeakerEnrollmentIsProcessing
                          || appState.targetSpeakerSampleIsRecording
                          || appState.targetSpeakerSampleIsProcessing)

                // Adding one sample to an existing profile, available any time rather than only
                // through the short-lived offer that follows a rejected dictation.
                if appState.hasStoredTargetSpeakerProfile && !appState.targetSpeakerEnrollmentActive {
                    Button(appState.targetSpeakerSampleIsRecording ? "Örneği bitir" : "Ses örneği ekle") {
                        if appState.targetSpeakerSampleIsRecording {
                            owLog("[TargetSpeaker] User clicked 'Örneği bitir' in SettingsView")
                            appState.stopTargetSpeakerSampleRecording()
                        } else {
                            owLog("[TargetSpeaker] User clicked 'Ses örneği ekle' in SettingsView")
                            appState.startTargetSpeakerSampleRecording()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.targetSpeakerSampleIsRecording
                              && !appState.canCaptureTargetSpeakerSample)
                }

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

    /// Authentication opens the system browser. The task remains active in the
    /// dedicated settings window; a notification also reports the outcome if it closes.
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
                    selectedTab = .approvals
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

// MARK: - Corrections and approvals tab

struct CorrectionsManagementView: View {
    @State private var newWrong = ""
    @State private var newRight = ""
    @State private var filter: Filter = .candidate
    @State private var pendingDeleteID: String?

    enum Filter: String, CaseIterable, Identifiable {
        case candidate, all, active, disabled
        var id: Self { self }

        var title: String {
            switch self {
            case .candidate: "Bekleyen"
            case .all: "Tümü"
            case .active: "Aktif"
            case .disabled: "Reddedilen"
            }
        }

        var symbol: String {
            switch self {
            case .candidate: "clock.badge.exclamationmark"
            case .all: "square.stack.3d.up"
            case .active: "checkmark.circle"
            case .disabled: "xmark.circle"
            }
        }

        var tint: Color {
            switch self {
            case .candidate: .orange
            case .all: .accentColor
            case .active: .green
            case .disabled: .secondary
            }
        }
    }

    private var records: [CorrectionStore.Record] { CorrectionStore.shared.records }
    private var pendingCount: Int { records.filter { $0.status == .candidate }.count }

    private var filteredRecords: [CorrectionStore.Record] {
        records.filter { record in
            switch filter {
            case .candidate: record.status == .candidate
            case .all: true
            case .active: record.status == .active
            case .disabled: record.status == .disabled
            }
        }
        .sorted { left, right in
            let leftPriority = statusPriority(left.status)
            let rightPriority = statusPriority(right.status)
            return leftPriority == rightPriority ? left.lastSeen > right.lastSeen : leftPriority < rightPriority
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 18)

            HStack(spacing: 8) {
                ForEach(Filter.allCases) { option in
                    filterCard(option)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)

            Divider()

            if filteredRecords.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredRecords) { record in
                            correctionCard(record)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()
            manualAddSection
                .padding(20)
        }
        .frame(minWidth: 520, minHeight: 540)
        .confirmationDialog(
            "Düzeltme silinsin mi?",
            isPresented: Binding(
                get: { pendingDeleteID != nil },
                set: { if !$0 { pendingDeleteID = nil } }
            )
        ) {
            Button("Düzeltmeyi sil", role: .destructive) {
                if let id = pendingDeleteID { CorrectionStore.shared.delete(id: id) }
                pendingDeleteID = nil
            }
        } message: {
            Text("Bu düzeltme kayıtlı listeden kaldırılacak.")
        }
        .onAppear {
            filter = pendingCount > 0 ? .candidate : .all
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Onaylar")
                    .font(.title2.weight(.semibold))
                Text("Öğrenilen düzeltmeleri inceleyin ve kullanılacak olanları seçin.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Label(pendingCount == 0 ? "Bekleyen yok" : "\(pendingCount) bekliyor",
                  systemImage: pendingCount == 0 ? "checkmark.circle" : "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(pendingCount == 0 ? Color.green : Color.orange)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((pendingCount == 0 ? Color.green : Color.orange).opacity(0.10), in: Capsule())
        }
    }

    private func filterCard(_ option: Filter) -> some View {
        let count: Int = {
            switch option {
            case .candidate: pendingCount
            case .all: records.count
            case .active: records.filter { $0.status == .active }.count
            case .disabled: records.filter { $0.status == .disabled }.count
            }
        }()
        let isSelected = filter == option
        return Button {
            filter = option
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: option.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(option.tint)
                Text("\(count)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(option.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(isSelected ? option.tint.opacity(0.09) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? option.tint.opacity(0.55) : Color.primary.opacity(0.06))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title): \(count)")
        .accessibilityValue(isSelected ? "Seçili" : "")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .candidate ? "checkmark.seal" : "tray")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.headline)
            Text(filter == .candidate
                 ? "Yeni bir düzeltme önerildiğinde burada görünecek."
                 : "Bu durumda kayıtlı bir düzeltme bulunmuyor.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
    }

    private var emptyTitle: String {
        switch filter {
        case .candidate: "Onay bekleyen düzeltme yok"
        case .all: "Henüz düzeltme yok"
        case .active: "Aktif düzeltme yok"
        case .disabled: "Reddedilen düzeltme yok"
        }
    }

    private func correctionCard(_ record: CorrectionStore.Record) -> some View {
        let store = CorrectionStore.shared
        return VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(record.wrong)
                        .foregroundStyle(.secondary)
                        .strikethrough()
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(record.right)
                        .fontWeight(.semibold)
                }
                .font(.system(size: 16))
                .lineLimit(2)
                .help("\(record.wrong) → \(record.right)")
                Spacer(minLength: 4)
                Label(statusText(record.status), systemImage: statusSymbol(record.status))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(record.status))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(statusColor(record.status).opacity(0.10), in: Capsule())
            }

            HStack(spacing: 8) {
                Text("\(record.count) kez görüldü")
                Text("·")
                Text(record.appliedCount == 0 ? "Henüz uygulanmadı" : "\(record.appliedCount) kez uygulandı")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                switch record.status {
                case .candidate:
                    Button("Onayla") { store.approve(id: record.id) }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    Button("Reddet") { store.reject(id: record.id) }
                        .buttonStyle(.bordered)
                        .help("Bu düzeltmeyi kapalı tutar; yeniden otomatik etkinleşmez.")
                    Spacer()
                    Button("Önemsiz") { store.discard(id: record.id) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Bu öneriyi listeden kaldırır.")
                case .active, .disabled:
                    Toggle("Aktif", isOn: Binding(
                        get: { store.records.first(where: { $0.id == record.id })?.status == .active },
                        set: { store.setDisabled(id: record.id, disabled: !$0) }
                    ))
                    .toggleStyle(.switch)
                    Spacer()
                    Button {
                        pendingDeleteID = record.id
                    } label: {
                        Label("Sil", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Bu düzeltmeyi sil")
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.06))
        }
    }

    private var manualAddSection: some View {
        let store = CorrectionStore.shared
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Elle düzeltme ekle", systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Onaylanmış olarak eklenir")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 9) {
                TextField("Yanlış duyulan", text: $newWrong)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Yanlış duyulan metin")
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                TextField("Doğru yazım", text: $newRight)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Doğru yazım")
                Button("Ekle") {
                    store.addManual(wrong: newWrong, right: newRight)
                    newWrong = ""
                    newRight = ""
                    filter = .active
                }
                .buttonStyle(.borderedProminent)
                .disabled(newWrong.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || newRight.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func statusPriority(_ status: CorrectionStore.Status) -> Int {
        switch status {
        case .candidate: 0
        case .active: 1
        case .disabled: 2
        }
    }

    private func statusText(_ status: CorrectionStore.Status) -> String {
        switch status {
        case .candidate: "Onay bekliyor"
        case .active: "Aktif"
        case .disabled: "Kapalı"
        }
    }

    private func statusSymbol(_ status: CorrectionStore.Status) -> String {
        switch status {
        case .candidate: "clock"
        case .active: "checkmark.circle"
        case .disabled: "xmark.circle"
        }
    }

    private func statusColor(_ status: CorrectionStore.Status) -> Color {
        switch status {
        case .candidate: .orange
        case .active: .green
        case .disabled: .secondary
        }
    }
}
