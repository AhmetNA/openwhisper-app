import SwiftUI

struct FlowBarView: View {
    @Environment(AppState.self) var appState

    var body: some View {
        HStack(spacing: 0) {
            switch appState.recordingState {
            case .idle:
                idleContent
            case .recording:
                recordingContent
            case .transcribing:
                transcribingContent
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
