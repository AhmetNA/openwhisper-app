import SwiftUI

struct FlowBarView: View {
    @Environment(AppState.self) var appState

    private var indicatorHeight: CGFloat {
        guard let caret = appState.caretPenRect else { return 26 }
        return CaretPenController.height(for: caret)
    }

    private var recordingWaveformWidth: CGFloat {
        guard appState.caretPenRect != nil, let field = appState.caretFieldRect else { return 67.5 }
        let controls: CGFloat = (appState.handsFreeActive ? 28 : 0) + (appState.screenModeActive ? 78 : 0)
        return min(67.5, max(20, field.width - 20 - controls))
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if appState.showsSystemAudioBar {
                    systemAudioContent
                } else if let message = appState.flowBarMessage,
                          appState.jarvisActivity != .speaking || appState.targetSpeakerAppendOfferActive {
                    if appState.targetSpeakerAppendOfferActive {
                        rejectedRecordingOfferContent(message: message)

                        if appState.shownRecordingState == .recording {
                            Divider()
                                .frame(height: 14)
                                .opacity(0.3)
                            recordingContent
                        } else if appState.shownRecordingState == .transcribing {
                            Divider()
                                .frame(height: 14)
                                .opacity(0.3)
                            transcribingContent
                        }
                    } else {
                        Text(message)
                            .font(.custom("Bradley Hand", size: 16).weight(.medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 26)
                    }
                } else {
                    switch appState.shownRecordingState {
                    case .idle:
                        if appState.jarvisActivity == .speaking { jarvisContent } else if appState.microphoneFlowNotice == nil { idleContent }
                    case .recording:
                        if appState.isTranscribing {
                            transcribingContent
                            Divider()
                                .frame(height: 14)
                                .opacity(0.3)
                            recordingContent
                        } else {
                            recordingContent
                        }
                    case .transcribing:
                        // The command already ran; while Jarvis answers, say so instead.
                        if appState.jarvisActivity == .speaking { jarvisContent } else { transcribingContent }
                    }
                }
            }
            if let notice = appState.microphoneFlowNotice {
                Label(loc(notice), systemImage: "mic.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, appState.caretPenRect == nil ? 16 : 8)
        .padding(.vertical, appState.caretPenRect == nil ? 6 : 2)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 17)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 17)
                    .fill(Color.black.opacity(0.35))
            }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .animation(.easeInOut(duration: 0.25), value: appState.targetSpeakerAppendOfferActive)
        .animation(.easeInOut(duration: 0.25), value: appState.microphoneFlowNotice)
        .animation(.easeInOut(duration: 0.25), value: appState.flowBarMessage)
        .animation(.easeInOut(duration: 0.25), value: appState.shownRecordingState)
        .animation(.easeInOut(duration: 0.15), value: appState.recordingInputReady)
        .animation(.easeInOut(duration: 0.25), value: appState.jarvisActivity)
        .animation(.easeInOut(duration: 0.25), value: appState.systemAudioIsRecording)
        .animation(.easeInOut(duration: 0.25), value: appState.systemAudioPendingCount)
        .animation(.easeInOut(duration: 0.25), value: appState.systemAudioResult)
    }

    // MARK: - System output recording

    @ViewBuilder
    private var systemAudioContent: some View {
        if appState.systemAudioEnabled {
            systemAudioRecordingContent
        } else if appState.systemAudioPendingCount > 0 {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(verbatim: loc(appState.systemAudioStatus))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(height: indicatorHeight)
        } else if let result = appState.systemAudioResult {
            HStack(spacing: 8) {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(result.succeeded ? Color.green : Color.orange)
                Text(verbatim: result.message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(height: indicatorHeight)
        }
    }

    private var systemAudioRecordingContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(appState.systemAudioIsRecording ? Color.red : Color.orange)
                .frame(width: 8, height: 8)

            Text(appState.systemAudioIsRecording ? "Bilgisayar sesi kaydediliyor" : "Bilgisayar sesi açılıyor")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)

            if let startedAt = appState.systemAudioStartedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(verbatim: SystemAudioReport.clock(context.date.timeIntervalSince(startedAt)))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
                // Up to 90:00, so the panel never has to grow while it records.
                .frame(width: 42, alignment: .leading)
            }

            Button {
                appState.stopSystemAudioListening()
            } label: {
                Text("Bitir ve kopyala")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.red))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Kaydı bitir ve metni panoya kopyala")
        }
        .frame(height: indicatorHeight)
    }

    // MARK: - Target-speaker confirmation offer

    /// The uncertain-speaker message plus a distinct tappable "Bu benim sesimdi" chip.
    /// Stays up for 8s (see `AppState.showTargetSpeakerAppendOffer`) rather than the normal 1.5s
    /// `flowBarMessage` dismiss -- long enough to actually read and tap. The panel is a
    /// borderless `.nonactivatingPanel` with `ignoresMouseEvents = false`, so tapping this chip
    /// does not steal keyboard focus from the app the user is dictating into. Tapping delivers the
    /// retained text and explicitly teaches the retained coherent candidate.
    private func rejectedRecordingOfferContent(message: String) -> some View {
        HStack(spacing: 8) {
            if !message.isEmpty {
                Text(message)
                    .font(.custom("Bradley Hand", size: 13.5).bold())
                    .foregroundStyle(.white.opacity(0.9))
            }

            Button {
                owLog("[TargetSpeaker] User tapped 'Bu benim sesimdi' chip in FlowBarView")
                appState.confirmRetainedRecordingWasTargetSpeaker()
            } label: {
                Text("Bu benim sesimdi")
                    .font(.custom("Bradley Hand", size: 13).bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.22)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .frame(height: indicatorHeight)
    }

    // MARK: - Idle

    private var idleContent: some View {
        IdleWaveformView()
    }

    // MARK: - Recording

    private var recordingContent: some View {
        HStack(spacing: 8) {
            // The mic stays open between steps on screen (`ScreenMode`).
            if appState.screenModeActive {
                Text("ekran modu")
                    .font(.custom("Bradley Hand", size: 14).weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if appState.recordingInputReady {
                AudioWaveformView(level: appState.audioLevel, height: indicatorHeight, width: recordingWaveformWidth)
            } else {
                // Bluetooth buds are still switching to call mode; speech now would be lost.
                Text("bağlanıyor")
                    .font(.custom("Bradley Hand", size: 16).weight(.medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 6)
                    .frame(height: indicatorHeight)
            }

            // Hands-free sessions have no key to release, so offer a click target. The panel is
            // non-activating: clicking it leaves focus in the app the text will be pasted into.
            if appState.handsFreeActive {
                Button {
                    appState.finishHandsFreeRecording()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.22)))
                }
                .buttonStyle(.plain)
                .help("Kaydı bitir ve yaz (Enter / Space)")
                .accessibilityLabel("Kaydı bitir ve metni yaz")
            }
        }
    }

    // MARK: - Transcribing

    private var transcribingContent: some View {
        ProcessingWaveformView(height: indicatorHeight)
    }

    // MARK: - Speaking

    private var jarvisContent: some View {
        Text("konuşuyor")
            .font(.custom("Bradley Hand", size: 16).weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)
            .frame(height: indicatorHeight)
    }
}
