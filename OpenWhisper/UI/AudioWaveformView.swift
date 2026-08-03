import SwiftUI

struct AudioWaveformView: View {
    let level: Float
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2.5
    private let barCount = 14
    private let grayColor = Color.white.opacity(0.75)

    // Minimal flat baseline height when quiet/silent (level = 0)
    private let baseHeight: CGFloat = 4.0
    private let maxHeight: CGFloat = 22.0
    // Reduced visual gain so normal speaking voice does not hit max height prematurely
    private let visualGain: CGFloat = 1.1

    @State private var samples: [CGFloat] = Array(repeating: 0.0, count: 14)

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(grayColor)
                    .frame(width: barWidth, height: currentHeight(for: index))
            }
        }
        .frame(height: 26, alignment: .center)
        .animation(.linear(duration: 0.04), value: samples)
        .onChange(of: level) { _, newLevel in
            pushSample(newLevel)
        }
        .onAppear {
            pushSample(level)
        }
    }

    private func pushSample(_ level: Float) {
        let clamped = min(max(CGFloat(level), 0), 1.0)
        let norm = pow(clamped, 1.2) * 0.85
        let addedHeight = norm * (maxHeight - baseHeight)

        var updated = samples
        if updated.count >= barCount {
            updated.removeFirst()
        }
        updated.append(addedHeight)
        samples = updated
    }

    private func currentHeight(for index: Int) -> CGFloat {
        guard index < samples.count else { return baseHeight }
        return max(baseHeight, min(maxHeight, baseHeight + samples[index]))
    }
}
