import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenWhisper")
                        .font(.headline)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: appState.systemAudioEnabled ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(appState.systemAudioEnabled ? Color.accentColor : .secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bilgisayar sesini yazıya dök")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    Text(appState.systemAudioStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button {
                    if appState.systemAudioEnabled {
                        appState.stopSystemAudioListening()
                    } else {
                        appState.startSystemAudioListening()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: appState.systemAudioEnabled ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(appState.systemAudioIsRecording ? "Bitir" : (appState.systemAudioEnabled ? "Kapat" : "Başlat"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(appState.systemAudioEnabled && !appState.systemAudioIsRecording ? Color.primary : .white)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(systemAudioButtonColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appState.systemAudioIsRecording ? "Kaydı bitir ve metni panoya kopyala" :
                    (appState.systemAudioEnabled ? "Bilgisayar sesini dinlemeyi kapat" : "Bilgisayar sesini dinlemeyi başlat"))
                .disabled(!appState.modelLoaded && !appState.systemAudioEnabled)
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))

            Divider()

            if let latest = appState.savedRecordings.first {
                Button {
                    appState.replayRecording(latest)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Son kaydı yeniden analiz et")
                                .font(.subheadline.weight(.semibold))
                            Text("\(latest.durationLabel) · \(latest.previewLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                if appState.savedRecordings.count > 1 {
                    Menu {
                        ForEach(appState.savedRecordings.dropFirst()) { recording in
                            Button(recording.menuLabel) {
                                appState.replayRecording(recording)
                            }
                            .disabled(isBusy)
                        }
                    } label: {
                        HStack {
                            Label("Önceki kayıtlar", systemImage: "clock.arrow.circlepath")
                            Spacer()
                            Text("\(appState.savedRecordings.count - 1)")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "mic")
                        .foregroundStyle(.secondary)
                    Text("Kayıtlarınız burada görünecek")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 13)
            }

            if let replayStatus = appState.replayStatus {
                Text(replayStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Çıkış") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Label("Ayarlar…", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: 350)
        .task(id: appState.modelLoaded) {
            if appState.modelLoaded {
                appState.prepareRecordingPreviews()
            }
        }
    }

    private var isBusy: Bool {
        appState.replayingRecordingID != nil || appState.recordingState != .idle || appState.systemAudioIsTranscribing
    }

    private var systemAudioButtonColor: Color {
        if appState.systemAudioIsRecording { return .red }
        if appState.systemAudioEnabled { return Color.primary.opacity(0.12) }
        return .accentColor
    }

    private var statusText: String {
        if appState.modelLoading { return "Model yükleniyor" }
        switch appState.recordingState {
        case .recording: return "Kaydediliyor"
        case .transcribing: return "İşleniyor"
        case .idle:
            if appState.systemAudioIsRecording { return "Bilgisayar sesi kaydediliyor" }
            if appState.systemAudioIsTranscribing { return "Bilgisayar sesi işleniyor" }
            if appState.systemAudioEnabled { return "Bilgisayar sesi dinleniyor" }
            return appState.modelLoaded ? "Hazır" : "Model hazır değil"
        }
    }

    private var statusColor: Color {
        if appState.modelLoading { return .orange }
        switch appState.recordingState {
        case .recording: return .red
        case .transcribing: return .orange
        case .idle:
            if appState.systemAudioIsRecording { return .red }
            if appState.systemAudioIsTranscribing { return .orange }
            return appState.modelLoaded ? .green : .orange
        }
    }
}
