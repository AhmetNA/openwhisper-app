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

/// Shown while a recording is turned into text: a pen scribbling loops back and forth across
/// the bar, its trail fading out behind the tip. Sines at unrelated rates keep the path from
/// repeating, so it looks random but stays smooth.
struct ProcessingWaveformView: View {
    var width: CGFloat = 68
    var height: CGFloat = 26
    private let trail = 0.7
    private let samples = 48
    /// Path times where the pen is near its left end, on the middle line, heading right
    /// (`startX` from the left edge), so it starts at the caret; which one varies the drawing.
    static let startX: CGFloat = 8
    @State private var startTime = [-0.56, 2.447, 11.305, 14.492, 26.378, 38.282].randomElement()!
    @State private var started = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = max(0, context.date.timeIntervalSince(started))
            let now = startTime + elapsed
            // The trail grows from the starting point instead of appearing already drawn.
            let length = min(trail, elapsed)
            Canvas { canvas, size in
                var previous = point(at: now - length, in: size)
                for step in 1...samples {
                    let fade = Double(step) / Double(samples)
                    let current = point(at: now - length * (1 - fade), in: size)
                    var segment = Path()
                    segment.move(to: previous)
                    segment.addLine(to: current)
                    canvas.stroke(segment, with: .color(.white.opacity(0.9 * fade)),
                                  style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    previous = current
                }
                canvas.fill(Path(ellipseIn: CGRect(x: previous.x - 1.75, y: previous.y - 1.75, width: 3.5, height: 3.5)),
                            with: .color(.white))
            }
        }
        .frame(width: width, height: height)
    }

    private func point(at t: Double, in size: CGSize) -> CGPoint {
        let x = 0.72 * sin(2.1 * t) + 0.28 * sin(3.7 * t + 1.3)
        let y = 0.55 * sin(6.3 * t) + 0.3 * sin(9.1 * t + 2.1) + 0.15 * sin(13.7 * t + 0.4)
        return CGPoint(x: size.width / 2 + (size.width / 2 - 4) * x, y: size.height / 2 + min(8, size.height / 2 - 4) * y)
    }
}

struct AudioWaveformView: View {
    let level: Float
    var height: CGFloat = 26
    var width: CGFloat = 67.5
    private var barWidth: CGFloat { width / 27 }
    private var barSpacing: CGFloat { width / 27 }
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
                    .frame(width: barWidth, height: currentHeight(for: index) * height / 26)
            }
        }
        .frame(height: height, alignment: .center)
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
