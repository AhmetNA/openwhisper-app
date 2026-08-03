import SwiftUI

struct AudioWaveformView: View {
    let level: Float
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2.5
    private let barCount = 14
    private let grayColor = Color.white.opacity(0.75)

    // Minimal flat baseline height when quiet/silent (level = 0)
    private let baseHeight: CGFloat = 4.0
    // Low but perfectly normal speech levels should still read clearly in the compact flow bar.
    // This only affects the visual scale; microphone capture and speech detection are unchanged.
    private let visualGain: CGFloat = 2.2

    // Waveform envelope multipliers (defines the curve shape as voice volume grows)
    private let waveShape: [CGFloat] = [
        5, 9, 15, 23, 14, 19, 12, 18, 23, 15, 19, 12, 8, 5
    ]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(grayColor)
                    .frame(width: barWidth, height: currentHeight(for: index))
            }
        }
        .frame(height: 26, alignment: .center)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func currentHeight(for index: Int) -> CGFloat {
        let norm = min(max(CGFloat(level) * visualGain, 0), 1.0)
        let add = waveShape[index] * norm
        return max(baseHeight, min(26, baseHeight + add))
    }
}
