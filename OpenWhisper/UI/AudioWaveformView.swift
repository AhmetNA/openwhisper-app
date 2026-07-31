import SwiftUI

struct AudioWaveformView: View {
    let level: Float
    private let barWidth: CGFloat = 2.0
    private let barSpacing: CGFloat = 2.0
    private let barCount = 14
    private let grayColor = Color.white.opacity(0.75)

    // Minimal flat baseline height when quiet/silent (level = 0)
    private let baseHeight: CGFloat = 3.0

    // Waveform envelope multipliers (defines the curve shape as voice volume grows)
    private let waveShape: [CGFloat] = [
        4, 7, 12, 18, 11, 15, 9, 14, 18, 12, 15, 9, 6, 4
    ]

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(grayColor)
                    .frame(width: barWidth, height: currentHeight(for: index))
            }
        }
        .frame(height: 22, alignment: .center)
        .animation(.easeOut(duration: 0.08), value: level)
    }

    private func currentHeight(for index: Int) -> CGFloat {
        let norm = CGFloat(min(max(level, 0), 1.0))
        let add = waveShape[index] * norm
        return max(3, min(22, baseHeight + add))
    }
}
