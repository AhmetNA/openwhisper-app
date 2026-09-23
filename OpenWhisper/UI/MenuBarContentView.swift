import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        LiquidGlassContainer(spacing: 14) {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 11, style: .continuous), tint: Color.accentColor.opacity(0.7), clear: true, interactive: true)

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
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous), tint: Color.accentColor.opacity(0.2), clear: true)
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
                        // Close the MenuBarExtra panel so it doesn't sit over what's being listened to.
                        NSApp.keyWindow?.close()
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
                    .liquidGlass(in: Capsule(), tint: systemAudioButtonColor, clear: true, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appState.systemAudioIsRecording ? "Kaydı bitir ve metni panoya kopyala" :
                    (appState.systemAudioEnabled ? "Bilgisayar sesini dinlemeyi kapat" : "Bilgisayar sesini dinlemeyi başlat"))
                .disabled(!appState.modelLoaded && !appState.systemAudioEnabled)
            }
            .padding(10)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)

            Divider()

            if let latest = appState.savedRecordings.first {
                Button {
                    appState.replayRecording(latest)
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .liquidGlass(in: RoundedRectangle(cornerRadius: 9, style: .continuous), tint: Color.accentColor.opacity(0.2), clear: true)

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
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
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
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Çıkış", systemImage: "power")
                }
                .glassButtonStyle()
                Spacer()
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    Label("Ayarlar…", systemImage: "gearshape")
                }
                .glassProminentButtonStyle()
                .keyboardShortcut(",", modifiers: .command)
            }
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
        if appState.systemAudioEnabled { return .clear }
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

// MARK: - Liquid Glass

/// Groups glass shapes so they blend/morph together on macOS 26+; plain stack otherwise.
private struct LiquidGlassContainer<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

private extension View {
    /// Liquid Glass on macOS 26+, falls back to a translucent material on older systems.
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, tint: Color? = nil, clear: Bool = false, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect((clear ? Glass.clear : Glass.regular).tint(tint).interactive(interactive), in: shape)
        } else {
            self
                .background((tint ?? .clear).opacity(0.85), in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}
