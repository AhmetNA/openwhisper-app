import XCTest
@testable import OpenWhisper

final class DeepFilterAutoDeciderTests: XCTestCase {
    private let mic = "BuiltInMicrophoneDevice"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Runs one recording on `mic` that measured `floor`, and returns the decision taken at its start.
    @discardableResult
    private func record(_ decider: inout DeepFilterAutoDecider, floor: Double?, seconds: Double = 5, at time: Date) -> DeepFilterDecision {
        let decision = decider.decide(setting: .automatic, device: mic, mediaPlaying: false, echoCancellation: false, now: time)
        decider.recordingStopped(floorDBFS: floor, measuredSeconds: seconds, at: time + seconds)
        return decision
    }

    private func autoDecision(_ decider: inout DeepFilterAutoDecider, at time: Date, media: Bool = false, aec: Bool = false) -> DeepFilterDecision {
        decider.decide(setting: .automatic, device: mic, mediaPlaying: media, echoCancellation: aec, now: time)
    }

    func testManualSettingsAreObeyed() {
        var decider = DeepFilterAutoDecider()
        record(&decider, floor: -80, at: t0)
        XCTAssertTrue(decider.decide(setting: .on, device: mic, mediaPlaying: false, echoCancellation: false, now: t0 + 10).enabled)
        XCTAssertFalse(decider.decide(setting: .off, device: mic, mediaPlaying: true, echoCancellation: true, now: t0 + 10).enabled)
    }

    func testOnWithoutAMeasurement() {
        var decider = DeepFilterAutoDecider()
        let decision = autoDecision(&decider, at: t0)
        XCTAssertEqual(decision, DeepFilterDecision(enabled: true, reason: "no floor yet"))
    }

    func testCleanRoomTurnsItOff() {
        var decider = DeepFilterAutoDecider()
        record(&decider, floor: -74, at: t0)
        XCTAssertEqual(autoDecision(&decider, at: t0 + 30), DeepFilterDecision(enabled: false, reason: "clean"))
    }

    func testNoisyRoomKeepsItOn() {
        var decider = DeepFilterAutoDecider()
        record(&decider, floor: -43, at: t0)
        XCTAssertEqual(autoDecision(&decider, at: t0 + 30), DeepFilterDecision(enabled: true, reason: "noisy"))
    }

    func testThresholdEdges() {
        var decider = DeepFilterAutoDecider()
        record(&decider, floor: DeepFilterAutoDecider.cleanBelowDBFS, at: t0)
        // Exactly at the clean threshold is not clean: stays on (the band keeps the default on).
        XCTAssertTrue(autoDecision(&decider, at: t0 + 10).enabled)
        decider.recordingStopped(floorDBFS: DeepFilterAutoDecider.cleanBelowDBFS - 0.1, measuredSeconds: 5, at: t0 + 15)
        XCTAssertFalse(autoDecision(&decider, at: t0 + 20).enabled)
        decider.recordingStopped(floorDBFS: DeepFilterAutoDecider.noisyFromDBFS, measuredSeconds: 5, at: t0 + 25)
        XCTAssertTrue(autoDecision(&decider, at: t0 + 30).enabled)
    }

    func testBandKeepsThePreviousState() {
        var decider = DeepFilterAutoDecider()
        let band = (DeepFilterAutoDecider.cleanBelowDBFS + DeepFilterAutoDecider.noisyFromDBFS) / 2

        // On, then a floor in the band: stays on.
        record(&decider, floor: band, at: t0)
        XCTAssertEqual(record(&decider, floor: -70, at: t0 + 10), DeepFilterDecision(enabled: true, reason: "in band, kept"))
        // Clean turned it off; a floor in the band now keeps it off rather than flapping back on.
        XCTAssertEqual(record(&decider, floor: band, at: t0 + 20).enabled, false)
        XCTAssertEqual(record(&decider, floor: band + 1, at: t0 + 30), DeepFilterDecision(enabled: false, reason: "in band, kept"))
        // Only a clearly noisy floor brings it back.
        XCTAssertEqual(record(&decider, floor: -50, at: t0 + 40), DeepFilterDecision(enabled: false, reason: "in band, kept"))
        XCTAssertEqual(autoDecision(&decider, at: t0 + 50), DeepFilterDecision(enabled: true, reason: "noisy"))
    }

    func testMediaAndEchoCancellationForceItOn() {
        var decider = DeepFilterAutoDecider()
        record(&decider, floor: -80, at: t0)
        XCTAssertEqual(autoDecision(&decider, at: t0 + 10, media: true), DeepFilterDecision(enabled: true, reason: "media playing"))
        XCTAssertEqual(autoDecision(&decider, at: t0 + 10, aec: true), DeepFilterDecision(enabled: true, reason: "echo cancellation"))
        // The override leaves the room's own state alone.
        XCTAssertFalse(autoDecision(&decider, at: t0 + 20).enabled)
    }

    func testStaleMeasurementTurnsItBackOn() {
        var decider = DeepFilterAutoDecider()
        record(&decider, floor: -80, at: t0)
        let late = t0 + 5 + DeepFilterAutoDecider.maxMeasurementAge + 1
        XCTAssertEqual(autoDecision(&decider, at: late), DeepFilterDecision(enabled: true, reason: "floor stale"))
    }

    func testShortRecordingsAreNotMeasurements() {
        var decider = DeepFilterAutoDecider()
        record(&decider, floor: -80, seconds: DeepFilterAutoDecider.minMeasuredSeconds - 0.1, at: t0)
        XCTAssertNil(decider.floor(for: mic))
        XCTAssertTrue(autoDecision(&decider, at: t0 + 10).enabled)
    }

    func testMeasurementsArePerInput() {
        var decider = DeepFilterAutoDecider()
        record(&decider, floor: -80, at: t0)
        let buds = decider.decide(setting: .automatic, device: "buds", mediaPlaying: false, echoCancellation: false, now: t0 + 10)
        XCTAssertEqual(buds, DeepFilterDecision(enabled: true, reason: "no floor yet"))
    }

    func testNoChangeMidRecording() {
        var decider = DeepFilterAutoDecider()
        record(&decider, floor: -40, at: t0)
        // The recording starts with the denoiser on…
        let active = autoDecision(&decider, at: t0 + 10)
        XCTAssertTrue(active.enabled)
        // …and the room going quiet while it runs changes nothing for it: the floor is filed
        // only at stop, and only the next recording's decision reads it.
        XCTAssertEqual(decider.floor(for: mic)?.dbfs, -40)
        decider.recordingStopped(floorDBFS: -80, measuredSeconds: 5, at: t0 + 15)
        XCTAssertTrue(active.enabled)
        XCTAssertFalse(autoDecision(&decider, at: t0 + 20).enabled)
    }

    func testStopWithoutAStartedDecisionFilesNothing() {
        var decider = DeepFilterAutoDecider()
        XCTAssertFalse(decider.recordingStopped(floorDBFS: -80, measuredSeconds: 5, at: t0))
        XCTAssertNil(decider.floor(for: mic))
    }

    func testMeterIgnoresWarmupSilenceAndSpeech() {
        var meter = RawNoiseFloorMeter()
        let rate = 48_000.0
        let frames = 480 // 10 ms
        // Warm-up ramp and digital zeros must not teach a floor.
        for _ in 0..<30 { meter.add(rms: 1e-7, frames: frames, sampleRate: rate) }
        for _ in 0..<50 { meter.add(rms: 0, frames: frames, sampleRate: rate) }
        XCTAssertNil(meter.floorDBFS)
        // A room at -70 dBFS with speech at -30 dBFS for most of the recording.
        for i in 0..<300 {
            let level: Float = i % 4 == 0 ? 0.000316 : 0.0316
            meter.add(rms: level, frames: frames, sampleRate: rate)
        }
        XCTAssertEqual(meter.floorDBFS ?? 0, -70, accuracy: 0.5)
        XCTAssertEqual(meter.measuredSeconds, 3, accuracy: 0.02)
    }

    func testProfileModeFollowsTheSetting() {
        XCTAssertEqual(DeepFilterSetting.automatic.profileMode, .deepFilterNet)
        XCTAssertEqual(DeepFilterSetting.on.profileMode, .deepFilterNet)
        XCTAssertEqual(DeepFilterSetting.off.profileMode, .off)
    }
}
