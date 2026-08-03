import SwiftUI

struct FlowBarView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        HStack(spacing: 0) {
            if let message = appState.flowBarMessage {
                if appState.targetSpeakerAppendOfferActive {
                    rejectedRecordingOfferContent(message: message)
                } else {
                    Text(message)
                        .font(.custom("Bradley Hand", size: 13.5).bold())
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                }
            } else {
                switch appState.recordingState {
                case .idle:
                    idleContent
                case .recording:
                    recordingContent
                case .transcribing:
                    transcribingContent
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.35))
            }
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
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
            Text(message)
                .font(.custom("Bradley Hand", size: 13.5).bold())
                .foregroundStyle(.white.opacity(0.9))

            Button {
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
        .frame(height: 22)
    }

    // MARK: - Idle

    private var idleContent: some View {
        AudioWaveformView(level: 0)
    }

    // MARK: - Recording

    private var recordingContent: some View {
        AudioWaveformView(level: appState.audioLevel)
    }

    // MARK: - Transcribing

    private var transcribingContent: some View {
        Text("transcribing")
            .font(.custom("Bradley Hand", size: 13.5).bold())
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 6)
            .frame(height: 22)
    }
}
