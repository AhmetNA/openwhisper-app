import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        LiquidGlassContainer(spacing: 14) {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            wakeWordRow

            systemAudioRow

            TimersSection()

            recordingsSection

            if let replayStatus = appState.replayStatus {
                Text(loc(replayStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            footer
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

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 11, style: .continuous), tint: Color.accentColor.opacity(0.7), clear: true, interactive: true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Jarvis")
                    .font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(loc(statusText))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var wakeWordRow: some View {
        HStack(spacing: 10) {
            Image(systemName: appState.wakeWordBlocked ? "ear.trianglebadge.exclamationmark" : appState.wakeWordListening ? "ear.fill" : "ear")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(appState.wakeWordBlocked ? Color.orange : appState.wakeWordListening ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous), tint: Color.accentColor.opacity(0.2), clear: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sesle başlat")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if appState.wakeWordBlocked {
                    Text(loc(appState.wakeWordStatus))
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { appState.wakeWordEnabled }, set: { appState.wakeWordEnabled = $0 }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .accessibilityLabel("“Jarvis” sözcüğünü dinle")
                .help(loc(appState.wakeWordStatus))
        }
        .padding(10)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
    }

    private var systemAudioRow: some View {
        HStack(spacing: 10) {
            Image(systemName: appState.systemAudioEnabled ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(appState.systemAudioEnabled ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 8, style: .continuous), tint: Color.accentColor.opacity(0.2), clear: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bilgisayar sesi")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                if appState.systemAudioStatus != "Kapalı" {
                    Text(loc(appState.systemAudioIsRecording ? "Kaydediliyor" : appState.systemAudioStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(loc(appState.systemAudioStatus))
                }
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
                    Text(appState.systemAudioEnabled ? "Bitir" : "Başlat")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .liquidGlass(in: Capsule(), tint: systemAudioButtonColor, clear: true, interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appState.systemAudioEnabled ? "Kaydı bitir ve metni panoya kopyala" : "Bilgisayar sesini kaydetmeye başla")
            .disabled(!appState.modelLoaded && !appState.whisperSuspendedForIdle && !appState.systemAudioEnabled)
        }
        .padding(10)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
    }

    @ViewBuilder
    private var recordingsSection: some View {
        if let latest = appState.savedRecordings.first {
            Divider()

            Button {
                appState.copyRecordingTranscript(latest)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .liquidGlass(in: RoundedRectangle(cornerRadius: 9, style: .continuous), tint: Color.accentColor.opacity(0.2), clear: true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Son kayıt")
                            .font(.subheadline.weight(.semibold))
                        let previewWords = loc(latest.previewLabel).split(whereSeparator: \.isWhitespace)
                        Text(previewWords.prefix(6).joined(separator: " ") + (previewWords.count > 6 ? "…" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .multilineTextAlignment(.leading)
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
            .disabled(latest.transcript?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            .help(loc("Metni kopyala"))

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
        }
    }

    private var footer: some View {
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

    private var isBusy: Bool {
        appState.replayingRecordingID != nil || appState.recordingState != .idle || appState.systemAudioIsTranscribing
    }

    private var systemAudioButtonColor: Color {
        appState.systemAudioEnabled ? .red : .accentColor
    }

    private var statusText: String {
        if appState.modelLoading { return "Model yükleniyor" }
        switch appState.recordingState {
        case .recording: return "Kaydediliyor"
        case .transcribing: return "İşleniyor"
        case .idle:
            if appState.systemAudioIsRecording { return "Bilgisayar sesi kaydediliyor" }
            if appState.systemAudioIsTranscribing { return "Bilgisayar sesi işleniyor" }
            if appState.systemAudioEnabled { return "Bilgisayar sesi açılıyor" }
            return (appState.whisperSuspendedForIdle || appState.modelLoaded) ? "Hazır" : "Model hazır değil"
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
            return (appState.modelLoaded || appState.whisperSuspendedForIdle) ? .green : .orange
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

/// Running timers and alarms, with the time left; hidden when there are none.
private struct TimersSection: View {
    private var manager: TimerManager { TimerManager.shared }

    var body: some View {
        if manager.ringing != nil || !manager.timers.isEmpty {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    if let ringing = manager.ringing {
                        row(icon: "alarm.waves.left.and.right.fill", title: ringing.label ?? "Alarm çalıyor",
                            detail: "Şimdi", tint: .orange, action: "Kapat") { manager.stopRinging() }
                    }
                    ForEach(manager.timers) { timer in
                        row(icon: timer.seconds == nil ? "alarm" : "timer",
                            title: timer.label ?? (timer.seconds.map { "\(SpokenDuration.spoken($0)) zamanlayıcı" } ?? "Alarm"),
                            detail: "\(TimerManager.clock(timer.fireDate, sayDay: false)) · \(TimerManager.spokenLeft(timer.fireDate.timeIntervalSince(context.date))) kaldı",
                            tint: .accentColor, action: "İptal") { manager.cancel(timer) }
                    }
                }
                .padding(10)
                .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous), interactive: true)
            }
        }
    }

    private func row(icon: String, title: String, detail: String, tint: Color, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(loc(action), action: perform)
                .controlSize(.small)
        }
    }
}
