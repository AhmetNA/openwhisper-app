import XCTest
import CoreAudio
@testable import OpenWhisper

final class MockVolumeController: VolumeControlling, @unchecked Sendable {
    var deviceID: AudioDeviceID = 1
    var volumeToReturn: Float? = 0.8
    var isWritable: Bool = true
    private(set) var writtenVolumes: [Float] = []

    func currentVolume(deviceID: AudioDeviceID) -> Float? {
        return volumeToReturn
    }

    func setVolume(_ value: Float, deviceID: AudioDeviceID) -> Bool {
        guard isWritable else { return false }
        writtenVolumes.append(value)
        volumeToReturn = value
        return true
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        return deviceID
    }
}

final class TestTimerHandle: RampTimerHandle, @unchecked Sendable {
    private(set) var isStopped = false
    func stop() {
        isStopped = true
    }
}

final class TestRampScheduler: RampScheduler, @unchecked Sendable {
    private(set) var lastTickClosure: (@Sendable () -> Void)?
    let activeHandle = TestTimerHandle()

    func startRepeating(
        interval: TimeInterval,
        queue: DispatchQueue,
        tick: @escaping @Sendable () -> Void
    ) -> RampTimerHandle {
        lastTickClosure = tick
        return activeHandle
    }

    func triggerTick() {
        lastTickClosure?()
    }
}

final class AudioDuckerTests: XCTestCase {

    private var mockController: MockVolumeController!
    private var testScheduler: TestRampScheduler!
    private var ducker: AudioDucker!

    override func setUp() {
        super.setUp()
        mockController = MockVolumeController()
        testScheduler = TestRampScheduler()
        ducker = AudioDucker(volumeController: mockController, scheduler: testScheduler)
    }

    override func tearDown() {
        ducker = nil
        testScheduler = nil
        mockController = nil
        super.tearDown()
    }

    // 1. Zaten kısıkken duck çağrısı hiçbir yazma yapmıyor.
    func testDuckSkippedWhenAlreadyAtOrBelowTarget() {
        mockController.volumeToReturn = 0.20
        ducker.updateConfiguration(targetVolume: 0.25, restoreDuration: 1.5)
        ducker.flushQueueForTesting()

        ducker.duck()
        ducker.flushQueueForTesting()

        XCTAssertTrue(mockController.writtenVolumes.isEmpty, "Volume should not be changed when already below target")

        ducker.restore()
        ducker.flushQueueForTesting()

        XCTAssertTrue(mockController.writtenVolumes.isEmpty, "Restore should be no-op when duck was skipped")
    }

    // 2. Rampa 1.5 s'de hedefe varıyor, adım değerleri monoton artıyor.
    func testRestoreRampReachesTargetMonotonically() {
        let initialVolume: Float = 0.80
        mockController.volumeToReturn = initialVolume
        ducker.updateConfiguration(targetVolume: 0.25, restoreDuration: 1.5)
        ducker.flushQueueForTesting()

        ducker.duck()
        ducker.flushQueueForTesting()

        XCTAssertEqual(mockController.writtenVolumes, [0.25])

        ducker.restore()
        ducker.flushQueueForTesting()

        // 1.5s / 0.03s step = 50 steps
        for _ in 1...50 {
            testScheduler.triggerTick()
            ducker.flushQueueForTesting()
        }

        let rampWrites = Array(mockController.writtenVolumes.dropFirst())
        XCTAssertEqual(rampWrites.count, 50)
        XCTAssertEqual(rampWrites.last!, initialVolume, accuracy: 0.0001)

        // Verify strictly monotonic increasing
        for i in 1..<rampWrites.count {
            XCTAssertGreaterThanOrEqual(rampWrites[i], rampWrites[i - 1], "Ramp step \(i) should be >= step \(i - 1)")
        }
    }

    // 3. Rampa ortasında duck() gelince: anında hedefe iniyor ve restore hedefi orijinal değer olarak kalıyor (3.2).
    func testReduckMidRampResetsToTargetAndPreservesOriginalVolume() {
        let initialVolume: Float = 0.80
        mockController.volumeToReturn = initialVolume
        ducker.updateConfiguration(targetVolume: 0.25, restoreDuration: 1.5)
        ducker.flushQueueForTesting()

        ducker.duck()
        ducker.flushQueueForTesting()

        ducker.restore()
        ducker.flushQueueForTesting()

        // Trigger 10 steps mid-ramp
        for _ in 1...10 {
            testScheduler.triggerTick()
            ducker.flushQueueForTesting()
        }

        let midRampVolume = mockController.writtenVolumes.last!
        XCTAssertGreaterThan(midRampVolume, 0.25)
        XCTAssertLessThan(midRampVolume, initialVolume)

        // Mid-ramp Fn press -> re-duck
        ducker.duck()
        ducker.flushQueueForTesting()

        XCTAssertEqual(mockController.writtenVolumes.last!, 0.25, "Re-duck should jump back to 0.25 immediately")

        // Trigger restore again
        ducker.restore()
        ducker.flushQueueForTesting()

        for _ in 1...50 {
            testScheduler.triggerTick()
            ducker.flushQueueForTesting()
        }

        XCTAssertEqual(mockController.writtenVolumes.last!, initialVolume, accuracy: 0.0001, "Final restore target must be original volume (0.80), not mid-ramp volume")
    }

    // 4. Rampa sırasında beklenmeyen bir dış değişiklik ölçülünce rampa iptal ediliyor (3.3).
    func testExternalVolumeChangeAbortsRamp() {
        mockController.volumeToReturn = 0.80
        ducker.updateConfiguration(targetVolume: 0.25, restoreDuration: 1.5)
        ducker.flushQueueForTesting()

        ducker.duck()
        ducker.flushQueueForTesting()

        ducker.restore()
        ducker.flushQueueForTesting()

        // Trigger 2 steps
        testScheduler.triggerTick()
        ducker.flushQueueForTesting()

        // User manually adjusts hardware volume slider to 0.95
        mockController.volumeToReturn = 0.95

        // Next tick detects external change (measured 0.95 vs last written ~0.26, diff > 0.05)
        testScheduler.triggerTick()
        ducker.flushQueueForTesting()

        XCTAssertTrue(testScheduler.activeHandle.isStopped, "Ramp timer should be stopped after external volume change")

        let countBeforeExtraTicks = mockController.writtenVolumes.count
        testScheduler.triggerTick()
        ducker.flushQueueForTesting()

        XCTAssertEqual(mockController.writtenVolumes.count, countBeforeExtraTicks, "No further writes should occur after ramp abort")
    }

    // 5. Okuma başarısız olunca hiçbir yazma yapılmıyor.
    func testUnreadableVolumeAbortsDuckWithoutWriting() {
        mockController.volumeToReturn = nil

        ducker.duck()
        ducker.flushQueueForTesting()

        XCTAssertTrue(mockController.writtenVolumes.isEmpty, "duck() must abort without writing if volume cannot be read")
    }

    // Sesli ses komutu, geri yükleme rampası sürerken gelirse kısık seviyeye değil,
    // dikte öncesi seviyeye uygulanıyor ve rampa bir daha yazmıyor.
    func testVolumeCommandDuringRestoreUsesPreDictationLevel() {
        mockController.volumeToReturn = 0.50
        ducker.updateConfiguration(targetVolume: 0.10, restoreDuration: 1.5)
        ducker.duck()
        ducker.restore()
        ducker.flushQueueForTesting()
        testScheduler.triggerTick()
        ducker.flushQueueForTesting()

        let change = ducker.applyVolumeCommand { $0 - 0.30 }
        XCTAssertEqual(change?.from ?? -1, 0.50, accuracy: 0.0001)
        XCTAssertEqual(change?.to ?? -1, 0.20, accuracy: 0.0001)
        XCTAssertTrue(testScheduler.activeHandle.isStopped)

        let writes = mockController.writtenVolumes.count
        testScheduler.triggerTick()
        ducker.restore()
        ducker.flushQueueForTesting()
        XCTAssertEqual(mockController.writtenVolumes.count, writes, "A cancelled ramp must not overwrite the command")
        XCTAssertEqual(mockController.volumeToReturn ?? -1, 0.20, accuracy: 0.0001)
    }

    func testVolumeCommandWithoutDuckReadsCurrentAndClamps() {
        mockController.volumeToReturn = 0.90
        let change = ducker.applyVolumeCommand { $0 + 0.30 }
        XCTAssertEqual(change?.to ?? -1, 1.0, accuracy: 0.0001)
        mockController.volumeToReturn = nil
        XCTAssertNil(ducker.applyVolumeCommand { $0 + 0.1 })
    }
}
