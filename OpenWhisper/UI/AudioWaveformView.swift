import SwiftUI
import Combine

/// `AudioWaveformView` at rest: the same flat bars without its 20 Hz timer, which kept
/// re-rendering zeros in the hidden flow bar between sessions.
struct IdleWaveformView: View {
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<14, id: \.self) { _ in
                Capsule()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 2.5, height: 3.5)
            }
        }
        .frame(height: 26, alignment: .center)
    }
}

/// Shown while a recording is turned into text: the same bars at rest, with a soft swell
/// running left to right through them like the dots of "typing…".
struct ProcessingWaveformView: View {
    private let barCount = 14
    private let period = 1.1

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            // The crest starts off the left edge and leaves off the right before coming back.
            let crest = phase * Double(barCount + 6) - 3
            HStack(spacing: 2.5) {
                ForEach(0..<barCount, id: \.self) { index in
                    let distance = Double(index) - crest
                    let swell = exp(-distance * distance / 3)
                    Capsule()
                        .fill(Color.white.opacity(0.45 + 0.5 * swell))
                        .frame(width: 2.5, height: 3.5 + 12 * swell)
                }
            }
        }
        .frame(height: 26, alignment: .center)
    }
}

struct AudioWaveformView: View {
    let level: Float
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2.5
    private let barCount = 14 // 14 bars * (1/14s per bar) = exact 1.0s window in original horizontal width
    private let grayColor = Color.white.opacity(0.75)

    private let baseHeight: CGFloat = 3.5
    private let maxHeight: CGFloat = 22.0

    @State private var samples: [CGFloat] = Array(repeating: 0.0, count: 14)

    // Continuous 20 Hz timer (1/20s = 50ms) guaranteeing continuous 20 Hz flow (1/20s per bar).
    private let timer = Timer.publish(every: 1.0 / 20.0, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(grayColor)
                    .frame(width: barWidth, height: currentHeight(for: index))
            }
        }
        .frame(height: 26, alignment: .center)
        .animation(.linear(duration: 1.0 / 20.0), value: samples)
        .onReceive(timer) { _ in
            pushSample(level)
        }
        .onAppear {
            pushSample(level)
        }
    }

    private func pushSample(_ level: Float) {
        let clamped = min(max(CGFloat(level), 0), 1.0)
        let boosted = min(pow(clamped, 0.7) * 1.35, 1.0)
        let addedHeight = boosted * (maxHeight - baseHeight)

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
