import AVFoundation
import XCTest
@testable import OpenWhisper

final class NativeAudioRingTests: XCTestCase {
    private func buffer(_ values: [Float], rate: Double = 1000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
        buffer.frameLength = AVAudioFrameCount(values.count)
        for (i, v) in values.enumerated() { buffer.floatChannelData![0][i] = v }
        return buffer
    }

    func testBuffersSinceCutsTheFirstChunkAndKeepsTheRest() {
        let ring = NativeAudioRing(seconds: 10)
        ring.reset(sampleRate: 1000)
        let t0 = AVAudioTime.hostTime(forSeconds: 100)
        ring.append(buffer((0..<100).map(Float.init)), time: AVAudioTime(hostTime: t0))
        ring.append(buffer((100..<200).map(Float.init)), time: AVAudioTime(hostTime: t0 + AVAudioTime.hostTime(forSeconds: 0.1)))

        let out = ring.buffers(since: t0 + AVAudioTime.hostTime(forSeconds: 0.06))
        let samples = out.flatMap { Array(UnsafeBufferPointer(start: $0.0.floatChannelData![0], count: Int($0.0.frameLength))) }
        XCTAssertEqual(samples.first, 60)
        XCTAssertEqual(samples.last, 199)
        XCTAssertEqual(samples.count, 140)
    }

    func testOldAudioIsDropped() {
        let ring = NativeAudioRing(seconds: 0.1)
        ring.reset(sampleRate: 1000)
        let t0 = AVAudioTime.hostTime(forSeconds: 100)
        for k in 0..<5 {
            ring.append(buffer([Float](repeating: Float(k), count: 50)),
                        time: AVAudioTime(hostTime: t0 + AVAudioTime.hostTime(forSeconds: 0.05 * Double(k))))
        }
        let out = ring.buffers(since: 0)
        XCTAssertEqual(out.map { $0.0.floatChannelData![0][0] }, [3, 4])
    }
    @MainActor
    func testDeferredWakeRetainsCommandThroughLongModelLoadWithoutDuplicates() {
        let ring = NativeAudioRing(seconds: WakeWordListener.bufferedWakeSeconds)
        ring.reset(sampleRate: 1000)
        let origin = AVAudioTime.hostTime(forSeconds: 100)
        for second in 0..<18 {
            ring.append(buffer((0..<1000).map { Float(second * 1000 + $0) }),
                time: AVAudioTime(hostTime: origin + AVAudioTime.hostTime(forSeconds: Double(second))))
        }
        // A candidate takes 1.5 s to mature, then model/verification may take up to 15 s.
        let out = ring.buffers(since: origin + AVAudioTime.hostTime(forSeconds: 1.5))
        let samples = out.flatMap { Array(UnsafeBufferPointer(start: $0.0.floatChannelData![0], count: Int($0.0.frameLength))) }
        XCTAssertEqual(samples, (1500..<18000).map(Float.init))
        XCTAssertGreaterThan(WakeWordListener.bufferedWakeSeconds, PendingWhisperWake.timeout + 1.5)
    }

}
