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

    func testFastCommandBeforeDetectionSurvivesDelayedHandoffWithoutDuplicates() {
        let ring = NativeAudioRing(seconds: 3)
        ring.reset(sampleRate: 1000)
        let t0 = AVAudioTime.hostTime(forSeconds: 100)
        // Detection at 1 s; a fast command began at 0.6 s. Handoff waits another 0.8 s.
        for k in 0..<18 {
            ring.append(buffer((k * 100..<(k + 1) * 100).map(Float.init)),
                        time: AVAudioTime(hostTime: t0 + AVAudioTime.hostTime(forSeconds: Double(k) / 10)))
        }
        let start = WakeWordListener.commandAudioStart(
            endHostTime: t0 + AVAudioTime.hostTime(forSeconds: 1))
        let samples = ring.buffers(since: start).flatMap {
            Array(UnsafeBufferPointer(start: $0.0.floatChannelData![0], count: Int($0.0.frameLength)))
        }
        XCTAssertEqual(samples, (400..<1800).map(Float.init))
    }

    func testCommandLookbackIncludesEchoDelayAndDoesNotUnderflow() {
        let end = AVAudioTime.hostTime(forSeconds: 100)
        let start = WakeWordListener.commandAudioStart(endHostTime: end, echoLookahead: 0.5)
        XCTAssertEqual(AVAudioTime.seconds(forHostTime: end - start), 1.1, accuracy: 0.00001)
        XCTAssertEqual(WakeWordListener.commandAudioStart(endHostTime: 1), 0)
    }
}
