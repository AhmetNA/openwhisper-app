import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppState.self) var appState

    @State private var spotifyClientID: String = ""
    @State private var spotifyClientSecret: String = ""
    @State private var spotifyTestState: SpotifyTestState = .idle
    @State private var spotifyHasStoredSecret: Bool = false
    @State private var spotifyConnected: Bool = false
    @State private var voiceAPIKeyStored: Bool = false
    @State private var sentenceTestState: SentenceTestState = .idle
    @State private var sentenceTestTask: Task<Void, Never>?

    private enum SentenceTestState: Equatable {
        case idle, preparing, done
        case playing(Int)
        case failure(String)
    }
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
        case general, dictation, corrections, jarvis, voice, accounts, permissions, advanced

        var id: Self { self }
        var title: String {
            switch self {
            case .general: "Genel"
            case .dictation: "Yazıya dökme"
            case .corrections: "Düzeltmeler"
            case .jarvis: "Jarvis"
            case .voice: "Sesim"
            case .accounts: "Hesaplar"
            case .permissions: "İzinler"
            case .advanced: "Gelişmiş"
            }
        }
        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .dictation: "waveform"
            case .corrections: "text.badge.checkmark"
            case .jarvis: "ear"
            case .voice: "person.wave.2"
            case .accounts: "key"
            case .permissions: "lock.shield"
            case .advanced: "gearshape.2"
            }
        }
        /// Sidebar heading shown above the first tab of each group.
        var group: String? {
            switch self {
            case .general: nil
            case .dictation, .corrections: "DİKTE"
            case .jarvis, .voice: "JARVIS"
            case .accounts, .permissions, .advanced: "SİSTEM"
            }
        }
    }

    @State private var selectedTab: Tab = .general

    // Read live by `WakeWordListener` / `TargetSpeakerFilter` on every score, so no restart needed.
    @AppStorage("wakeWordThreshold") private var wakeWordThreshold: Double = 0.25
    @AppStorage("wakeWordCandidateThreshold") private var wakeWordCandidateThreshold: Double = 0.12
    @AppStorage("wakeWordConfirmedScore") private var wakeWordConfirmedScore: Double = 0.5
    @AppStorage("targetSpeakerWakeThreshold") private var targetSpeakerWakeThreshold: Double = 0.40
    @AppStorage(DefaultInputGuard.defaultsKey) private var keepBuiltInMicAsDefault = true

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if selectedTab == .corrections {
                CorrectionsManagementView(settings: correctionsSection)
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
                if let group = tab.group, Tab.allCases.first(where: { $0.group == group }) == tab {
                    Text(group)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                }
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.symbol)
                            .frame(width: 18)
                        Text(tab.title)
                        Spacer(minLength: 0)
                        if tab == .corrections {
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
            languageSection
            Divider()
            inputDeviceSection
            Divider()
            audioProcessingSection
            Divider()
            audioDuckingSection
            if let error = appState.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        case .dictation:
            modelCategory("Konuşma tanıma")
            transcriptionModelSection
            if appState.modelLoading {
                ProgressView("Model yükleniyor…")
            } else if !appState.modelLoaded {
                Label("Model hazır değil", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            Divider()
            modelCategory("Metin temizleme")
            cleanupSection
        case .corrections:
            EmptyView()  // Full-height layout, drawn by `body`.
        case .jarvis:
            jarvisSection
            Divider()
            modelCategory("Sohbet (LLM)")
            chatModelSection
            Divider()
            modelCategory("Sesli cevap (TTS)")
            voiceRepliesSection
        case .voice:
            targetSpeakerSection
        case .accounts:
            APIKeysView { provider in
                guard provider.id == APIKeys.gemini.id else { return }
                refreshVoiceAPIKeyState()
                if provider.hasKey, appState.voiceRepliesEnabled { Task { await JarvisVoice.shared.prepare() } }
            }
            Divider()
            spotifySection
        case .permissions:
            PermissionsView()
        case .advanced:
            advancedSection
        }
    }

    private var languageSection: some View {
        @Bindable var appState = appState
        return HStack {
        Label("Dil", systemImage: "globe")
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
                Label("LLM ile temizleme", systemImage: "sparkles")
                Spacer()
                Toggle("", isOn: $appState.llmCleanupEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if appState.llmCleanupEnabled {
                HStack {
                    Text("Yerel model (Ollama)")
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
            Toggle("Türkçe sayı ve tarih biçimlendirme (Damga)", isOn: $appState.damgaEnabled)
            Text("“Yüz elli lira” → “150 TL”. Sayı, tarih, saat ve iletişim bilgilerini biçimlendirir.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if appState.damgaEnabled {
                Text(appState.language == "tr" ? DamgaNormalizer.shared.status : "Türkçe seçildiğinde çalışır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Gülmeyi random'a çevir", isOn: $appState.laughterToRandomEnabled)
            Text("“Ha ha ha” gibi gülmeleri “asdfghjk” gibi rastgele harflere çevirir.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Audio Processing Section

    private var audioProcessingSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 7) {
            Label("Ses işleme", systemImage: "waveform.and.mic")

            Picker("DeepFilter", selection: $appState.deepFilterSetting) {
                Text("Otomatik").tag(DeepFilterSetting.automatic)
                Text("Açık").tag(DeepFilterSetting.on)
                Text("Kapalı").tag(DeepFilterSetting.off)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(appState.recordingState != .idle)

            Text(appState.recordingState == .idle
                 ? deepFilterSettingDescription
                 : "Kayıt sürerken değiştirilemez.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var deepFilterSettingDescription: String {
        switch appState.deepFilterSetting {
        case .automatic: return "Ortam sessizse kapanır, gürültüde açılır."
        case .on: return "Gürültü her kayıtta temizlenir."
        case .off: return "Gürültü temizlenmez."
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
                .frame(width: 280)
                .disabled(switching)
            }

            Text("☁️ = seçince indirilir.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if !appState.pendingProviderApprovals().isEmpty {
                Label("Onay bekleyen konuşma sağlayıcısı var.", systemImage: "exclamationmark.shield")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Button("Gelişmiş'te incele") { selectedTab = .advanced }
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
    }

    /// User-installed speech providers: approval requests and granted approvals.
    @ViewBuilder
    private var providerApprovalSection: some View {
        let pendingApprovals = appState.pendingProviderApprovals()
        let approvedUserInstalledIDs = appState.approvedUserInstalledProviderIDs()
        if !pendingApprovals.isEmpty || !approvedUserInstalledIDs.isEmpty {
            Divider()
            modelCategory("Ek konuşma sağlayıcıları")
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
                        Text("Onaylarsanız bu yorumlayıcı Jarvis'in mikrofon ve erişilebilirlik izinleriyle çalışır.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Çalıştırmaya izin ver") {
                            appState.approveProvider(id: approval.id)
                            providerApprovalRefreshToken = UUID()
                        }
                        .font(.caption)
                    } else {
                        Text("Güvenlik kontrolünden geçemediği için çalıştırılamaz. Ayrıntı: /tmp/openwhisper.log")
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
                Label("Mikrofon", systemImage: "mic.and.signal.meter")
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

            Toggle("Sistem girişini Mac mikrofonunda tut", isOn: $keepBuiltInMicAsDefault)
                .font(.caption)
                .padding(.leading, 22)
                .onChange(of: keepBuiltInMicAsDefault) { _, on in
                    if on { DefaultInputGuard.shared.enforce() }
                    appState.refreshInputDevices()
                }
            Text("Bluetooth kulaklık bağlanınca da giriş Mac mikrofonunda kalır, kulaklık sesi yüksek kalitede çalar.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 22)

            if appState.resolvedInputIsBluetooth {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("Kulaklık mikrofonu kullanılırken kulaklık sesi düşük kaliteye geçer.")
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
            Text("Kayıt sırasında çalan müzik ve video duraklar, kayıt bitince devam eder.")
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
                if appState.wakeWordBlocked {
                    Label(appState.wakeWordStatus, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if appState.wakeWordStatus.contains("Mikrofon izni") {
                        Button("Mikrofon ayarlarını aç") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                } else {
                    Text(appState.wakeWordStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("“Jarvis”, “Hey Jarvis” ya da “Selam Jarvis” deyince dinler. İmleç bir yazı alanındaysa oraya yazar, değilse cevap verir. “Buraya yaz…” ya da “Bana cevap ver…” diyerek seçebilirsiniz.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            JarvisHotkeyRecorder()

            HStack(spacing: 6) {
                Image(systemName: jarvisSpeakerCheckOn ? "checkmark.circle.fill" : "person.wave.2")
                    .foregroundStyle(jarvisSpeakerCheckOn ? .green : .secondary)
                Text(jarvisSpeakerCheckOn ? "Yalnızca sizin sesinizle uyanır." : "Herkesin sesiyle uyanır.")
                Button("Sesim'de değiştir") { selectedTab = .voice }
                    .buttonStyle(.link)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Advanced Section

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            modelCategory("Jarvis uyanma hassasiyeti")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
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
                             help: "Bu puanın üstünde hemen başlar; “Jarvis” doğrulanmazsa kayıt iptal edilir.")
                jarvisSlider("Aday", value: $wakeWordCandidateThreshold, range: 0.05...0.50,
                             help: "Bu puanın üstündeki sesler önce doğrulanır, sonra uyanır.")
                if wakeWordCandidateThreshold >= wakeWordThreshold {
                    Label("Aday eşiği doğrudan uyanma eşiğinden düşük olmalı.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                jarvisSlider("Ses benzerliği", value: $targetSpeakerWakeThreshold, range: 0.20...0.80,
                             help: "Sesiniz tanınmıyorsa düşürün, başkası uyandırıyorsa yükseltin.")
                    .disabled(!jarvisSpeakerCheckOn)
            }

            Divider()
            modelCategory("Karar modelleri")
            decisionSection

            Divider()
            modelCategory("Düzeltmeler")
            correctionCheckpointsSection

            providerApprovalSection
        }
    }

    // MARK: Sesli cevaplar

    private var voiceProvider: SpeechProviderDescriptor {
        SpeechProviders.descriptor(for: appState.voiceProviderID)
    }

    private func modelCategory(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var chatModelSection: some View {
        CloudChatSettingsView(ollamaModel: appState.ollamaModel) { selectedTab = .accounts }
    }

    private var decisionSection: some View {
        @Bindable var appState = appState
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Karar motoru")
                Spacer()
                Picker("", selection: $appState.decisionEngine) {
                    ForEach(SetFitDecider.Engine.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }
            Text("Jarvis çağrısı, Spotify komutları ve onaylar için karar verir.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if appState.decisionEngine.usesSetFit {
                Text("SetFit: \(appState.setFitStatus)")
                    .font(.caption)
                    .foregroundStyle(appState.setFitStatus.hasPrefix("Hazır") ? Color.secondary : Color.orange)
            }
        }
    }

    private var voiceRepliesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Sesli cevap", systemImage: "speaker.wave.2")
                Spacer()
                Toggle("", isOn: Binding(get: { appState.voiceRepliesEnabled },
                                         set: { appState.voiceRepliesEnabled = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text("Komutlara kısa sesli cevap verir, ör. “Saat 14:05, patron.”")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Ses sağlayıcı")
                Spacer()
                Picker("", selection: Binding(get: { appState.voiceProviderID },
                                              set: { appState.voiceProviderID = $0 })) {
                    ForEach(SpeechProviders.all) { provider in
                        Text(provider.title).tag(provider.id)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            if voiceProvider.models.count > 1 {
                HStack {
                    Text("Model")
                    Spacer()
                    Picker("", selection: Binding(get: { appState.voiceModelID },
                                                  set: { appState.voiceModelID = $0 })) {
                        ForEach(voiceProvider.models) { model in
                            Text(model.title).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
                Text(voiceProvider.model(id: appState.voiceModelID).detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if !voiceProvider.voices.isEmpty {
                HStack {
                    Text("Ses")
                    Spacer()
                    Picker("", selection: Binding(get: { appState.voiceID },
                                                  set: { appState.voiceID = $0 })) {
                        ForEach(voiceProvider.voices) { voice in
                            Text("\(voice.id) — \(voice.trait)").tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }
            Label(voiceProvider.summary, systemImage: voiceProvider.needsAPIKey ? "network" : "desktopcomputer")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if voiceProvider.needsAPIKey && !voiceAPIKeyStored {
                HStack {
                    Label("API anahtarı yok. Anahtar girilene kadar Jarvis sessiz kalır.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Ekle") { selectedTab = .accounts }
                        .controlSize(.small)
                }
            }
            sentenceTestRow
        }
        .onAppear(perform: refreshVoiceAPIKeyState)
        .onChange(of: appState.voiceProviderID) { _, _ in refreshVoiceAPIKeyState(); stopSentenceTest() }
    }

    /// Reads `JarvisVoice.testSentences` with the chosen provider/model/voice, so voices can be
    /// compared by ear without speaking. Works for local providers too (waits for the server).
    private var sentenceTestRow: some View {
        HStack(spacing: 8) {
            if sentenceTestTask == nil {
                Button("Test cümlelerini oku", action: startSentenceTest)
                    .disabled(voiceProvider.needsAPIKey && !voiceAPIKeyStored)
            } else {
                Button("Durdur", action: stopSentenceTest)
            }
            switch sentenceTestState {
            case .idle:
                EmptyView()
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Ses hazırlanıyor…").foregroundStyle(.secondary)
            case .playing(let index):
                Label("Cümle \(index)/\(JarvisVoice.testSentences.count)", systemImage: "speaker.wave.2.fill")
            case .done:
                Label("Bitti", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        .font(.caption2)
    }

    private func startSentenceTest() {
        sentenceTestState = .preparing
        sentenceTestTask = Task {
            let error = await JarvisVoice.shared.speakTestSentences { index in
                sentenceTestState = .playing(index)
            }
            switch error {
            case nil: sentenceTestState = .done
            case .cancelled?: sentenceTestState = .idle
            case .notReady?:
                sentenceTestState = .failure(voiceProvider.needsAPIKey
                    ? "API anahtarı yok."
                    : "Yerel ses sunucusu açılamadı. Kurulumu kontrol edin.")
            case let error?: sentenceTestState = .failure(error.userMessage)
            }
            sentenceTestTask = nil
        }
    }

    private func stopSentenceTest() {
        guard let task = sentenceTestTask else { return }
        task.cancel()
        JarvisVoice.shared.stop()
        sentenceTestTask = nil
        sentenceTestState = .idle
    }

    private func refreshVoiceAPIKeyState() {
        voiceAPIKeyStored = SpeechSettingsStore.standard.hasAPIKey(for: voiceProvider.id)
    }

    private var jarvisSpeakerCheckOn: Bool {
        appState.targetSpeakerEnabled && appState.targetSpeakerScope.coversWakeWord
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
                Text((appState.targetSpeakerEnrollmentMic == .buds ? "Kulaklık — " : "")
                     + (appState.targetSpeakerEnrollmentIsRecording
                     ? "Kayıt \(appState.targetSpeakerEnrollmentStep + 1)/2: \(Int(appState.recordingDuration))/30 sn — \(appState.targetSpeakerEnrollmentPrompt)"
                     : appState.targetSpeakerEnrollmentStatus))
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
                Button(appState.targetSpeakerEnrollmentIsRecording && appState.targetSpeakerEnrollmentMic == .mac
                       ? "Kaydı bitir" : "Sesimi kaydet") {
                    if appState.targetSpeakerEnrollmentIsRecording {
                        owLog("[TargetSpeaker] User clicked 'Kaydı bitir' in SettingsView")
                        appState.stopTargetSpeakerEnrollmentRecording()
                    } else {
                        owLog("[TargetSpeaker] User clicked 'Sesimi kaydet' in SettingsView")
                        if !appState.targetSpeakerEnrollmentActive {
                            appState.beginTargetSpeakerEnrollment(for: .mac)
                        }
                        appState.startTargetSpeakerEnrollmentRecording()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.targetSpeakerEnrollmentIsProcessing
                          || appState.targetSpeakerSampleIsRecording
                          || appState.targetSpeakerSampleIsProcessing
                          || (appState.targetSpeakerEnrollmentActive && appState.targetSpeakerEnrollmentMic == .buds))

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
                        appState.replaceTargetSpeakerProfile(for: .mac)
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

            budsSpeakerProfileRow
        }
    }

    /// The buds keep their own profile: their call-mode mic doesn't match the Mac one, and
    /// without it buds recordings go unfiltered.
    private var budsSpeakerProfileRow: some View {
        let budsConnected = appState.availableInputDevices.contains { $0.isBluetooth }
        let enrollingBuds = appState.targetSpeakerEnrollmentActive && appState.targetSpeakerEnrollmentMic == .buds
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: appState.hasBudsTargetSpeakerProfile ? "checkmark.circle.fill" : "airpodspro")
                    .foregroundStyle(appState.hasBudsTargetSpeakerProfile ? .green : .secondary)
                Text("Kulaklık profili: \(appState.budsTargetSpeakerProfileStatus)"
                     + (appState.hasStoredBudsTargetSpeakerProfile
                        ? " · \(appState.budsTargetSpeakerProfile?.embeddings.count ?? 0) örnek" : ""))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
            Text(appState.hasBudsTargetSpeakerProfile
                 ? "Kulaklık takılıyken başkalarının konuşması bu profille ayıklanır."
                 : "Kulaklık için ayrı profil gerekir; kulaklığı bağlayıp sesinizi kaydedin.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(enrollingBuds && appState.targetSpeakerEnrollmentIsRecording
                       ? "Kaydı bitir"
                       : appState.hasStoredBudsTargetSpeakerProfile && !enrollingBuds ? "Kulaklıkla yeniden kaydet" : "Kulaklıkla kaydet") {
                    if enrollingBuds && appState.targetSpeakerEnrollmentIsRecording {
                        owLog("[TargetSpeaker] User clicked 'Kaydı bitir' (buds) in SettingsView")
                        appState.stopTargetSpeakerEnrollmentRecording()
                    } else {
                        owLog("[TargetSpeaker] User clicked 'Kulaklıkla kaydet' in SettingsView")
                        if !enrollingBuds {
                            appState.beginTargetSpeakerEnrollment(for: .buds)
                        }
                        appState.startTargetSpeakerEnrollmentRecording()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!budsConnected
                          || appState.targetSpeakerEnrollmentIsProcessing
                          || appState.targetSpeakerSampleIsRecording
                          || appState.targetSpeakerSampleIsProcessing
                          || (appState.targetSpeakerEnrollmentActive && !enrollingBuds))

                if !budsConnected {
                    Text("Kulaklık bağlı değil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if appState.hasStoredBudsTargetSpeakerProfile {
                    Button("Sil") {
                        owLog("[TargetSpeaker] User clicked 'Sil' buds profile in SettingsView")
                        appState.deleteBudsTargetSpeakerProfile()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .disabled(appState.targetSpeakerEnrollmentIsProcessing)
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
                Text("Düzeltmeleri öğren")
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
                Text("Düzenledikten sonra ⌥⇧C ile düzeltmeleri hemen onaya gönderin.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var correctionCheckpointsSection: some View {
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

            Text("Yapıştırdıktan sonra düzeltmelerinize bakılan saniyeler.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if let warning = checkpointsWarning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            checkpointsInput = DictationSnapshot.shared.checkpointsString
        }
    }
}

// MARK: - Corrections tab (settings + approvals)

struct CorrectionsManagementView<Settings: View>: View {
    /// Learning switch and checkpoints, shown above the list.
    let settings: Settings
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
                .padding(.bottom, 14)

            settings
                .padding(.horizontal, 24)
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
                Text("Düzeltmeler")
                    .font(.title2.weight(.semibold))
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
