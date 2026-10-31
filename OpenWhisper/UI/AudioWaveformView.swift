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

/// Shown while a recording is turned into text: a wavy line drawn left to right as if by a
/// pen, its tail fading out behind the tip.
struct ProcessingWaveformView: View {
    private let width: CGFloat = 68
    private let trail: CGFloat = 40
    private let period = 1.4

    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            Canvas { canvas, size in
                // The tip runs past the right edge so the tail can leave before it starts again.
                let tip = CGFloat(phase) * (size.width + trail)
                let from = max(0, tip - trail), to = min(size.width, tip)
                guard to > from else { return }
                var x = from
                while x < to {
                    let next = min(x + 1, to)
                    var segment = Path()
                    segment.move(to: point(at: x, in: size))
                    segment.addLine(to: point(at: next, in: size))
                    let fade = (next - (tip - trail)) / trail
                    canvas.stroke(segment, with: .color(.white.opacity(0.9 * fade)),
                                  style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    x = next
                }
                if tip <= size.width {
                    let p = point(at: tip, in: size)
                    canvas.fill(Path(ellipseIn: CGRect(x: p.x - 1.75, y: p.y - 1.75, width: 3.5, height: 3.5)),
                                with: .color(.white))
                }
            }
        }
        .frame(width: width, height: 26)
    }

    /// A handwritten-looking wave: the height wanders a little along the line.
    private func point(at x: CGFloat, in size: CGSize) -> CGPoint {
        let amplitude = 6 * (0.65 + 0.35 * sin(x * 0.09))
        return CGPoint(x: x, y: size.height / 2 + amplitude * sin(x * 0.32))
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
