import Foundation
import CoreAudio

// MARK: - Volume control abstraction (testable seam)

/// Reads/writes a CoreAudio output device's volume. All calls are expected to happen on
/// `AudioDucker`'s own serial queue — see that type for why a single writer matters.
protocol VolumeControlling: Sendable {
    /// `nil` when the volume genuinely cannot be read (missing property, transport hiccup, …).
    /// Callers must never substitute a guessed value for `nil` — see AudioDucker.duck().
    func currentVolume(deviceID: AudioDeviceID) -> Float?
    /// `false` when the write failed or the device exposes no settable volume control at all
    /// (§1.3: neither the main element nor per-channel stereo controls are writable).
    @discardableResult
    func setVolume(_ value: Float, deviceID: AudioDeviceID) -> Bool
    func defaultOutputDeviceID() -> AudioDeviceID?
    /// Clears the device's mute, so a voice "louder" command is actually heard.
    func unmute(deviceID: AudioDeviceID)
}

extension VolumeControlling {
    func unmute(deviceID: AudioDeviceID) {}
}

/// Real CoreAudio-backed implementation. `kAudioDevicePropertyVolumeScalar` ('volm') is used
/// directly via `AudioObjectGetPropertyData`/`AudioObjectSetPropertyData` rather than the
/// higher-level `AudioHardwareService*` calls, which have been deprecated since 10.11.
final class CoreAudioVolumeController: VolumeControlling, @unchecked Sendable {

    /// Where a device's volume is actually controllable, resolved once per device and cached.
    private enum ControlPoint {
        case main
        case channels([UInt32])
        case unsupported
    }

    /// Only ever touched from AudioDucker's serial queue, so no lock is needed here.
    private var capabilityCache: [AudioDeviceID: ControlPoint] = [:]

    func currentVolume(deviceID: AudioDeviceID) -> Float? {
        switch controlPoint(for: deviceID) {
        case .main:
            return readScalar(deviceID: deviceID, element: kAudioObjectPropertyElementMain)
        case .channels(let channels):
            guard let first = channels.first else { return nil }
            return readScalar(deviceID: deviceID, element: first)
        case .unsupported:
            return nil
        }
    }

    @discardableResult
    func setVolume(_ value: Float, deviceID: AudioDeviceID) -> Bool {
        switch controlPoint(for: deviceID) {
        case .main:
            return writeScalar(value, deviceID: deviceID, element: kAudioObjectPropertyElementMain)
        case .channels(let channels):
            guard !channels.isEmpty else { return false }
            // Write every channel; report failure if any of them rejected the value.
            return channels.reduce(true) { ok, channel in
                writeScalar(value, deviceID: deviceID, element: channel) && ok
            }
        case .unsupported:
            return false
        }
    }

    func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
        ) == noErr else { return nil }
        return id == 0 ? nil : id
    }

    func unmute(deviceID: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &addr), isSettable(deviceID: deviceID, addr: &addr) else { return }
        var muted: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &muted)
    }

    // MARK: Capability resolution (§1.3)

    private func controlPoint(for deviceID: AudioDeviceID) -> ControlPoint {
        if let cached = capabilityCache[deviceID] { return cached }
        let resolved = probeControlPoint(deviceID: deviceID)
        capabilityCache[deviceID] = resolved
        return resolved
    }

    private func probeControlPoint(deviceID: AudioDeviceID) -> ControlPoint {
        var mainAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &mainAddr), isSettable(deviceID: deviceID, addr: &mainAddr) {
            return .main
        }

        // Fall back to the device's preferred stereo channel pair, written independently.
        var stereoAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &stereoAddr) else { return .unsupported }
        var channels = [UInt32](repeating: 0, count: 2)
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        guard AudioObjectGetPropertyData(deviceID, &stereoAddr, 0, nil, &size, &channels) == noErr else {
            return .unsupported
        }

        let settableChannels = channels.filter { channel in
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: channel
            )
            guard AudioObjectHasProperty(deviceID, &addr) else { return false }
            return isSettable(deviceID: deviceID, addr: &addr)
        }
        return settableChannels.isEmpty ? .unsupported : .channels(settableChannels)
    }

    private func isSettable(deviceID: AudioDeviceID, addr: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr && settable.boolValue
    }

    private func readScalar(deviceID: AudioDeviceID, element: UInt32) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    private func writeScalar(_ value: Float, deviceID: AudioDeviceID, element: UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
        var v = Float32(value)
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(deviceID, &addr, 0, nil, size, &v) == noErr
    }
}

// MARK: - Ramp scheduling abstraction (testable seam)

/// A live repeating ramp timer. `stop()` must be safe to call more than once.
protocol RampTimerHandle: AnyObject, Sendable {
    func stop()
}

/// Drives ramp ticks. Kept separate from `AudioDucker` so tests can fire ticks synchronously
/// instead of waiting out a real 1.5s ramp.
protocol RampScheduler: Sendable {
    func startRepeating(
        interval: TimeInterval,
        queue: DispatchQueue,
        tick: @escaping @Sendable () -> Void
    ) -> RampTimerHandle
}

/// Real implementation: a `DispatchSourceTimer` on the caller-supplied serial queue (§1.4).
/// `Timer`/`RunLoop` are avoided deliberately — the main run loop is measurably busy for a
/// while after Fn is released (flow bar, transcription, paste), which would stall the very
/// ramp that is supposed to stay smooth during that window.
struct DispatchRampScheduler: RampScheduler {
    func startRepeating(
        interval: TimeInterval,
        queue: DispatchQueue,
        tick: @escaping @Sendable () -> Void
    ) -> RampTimerHandle {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: tick)
        timer.resume()
        return DispatchTimerHandle(timer: timer)
    }
}

private final class DispatchTimerHandle: RampTimerHandle, @unchecked Sendable {
    private let timer: DispatchSourceTimer
    init(timer: DispatchSourceTimer) { self.timer = timer }
    func stop() { timer.cancel() }
}

// MARK: - AudioDucker

/// Ducks the system output volume instantly when dictation starts and ramps it back smoothly
/// when dictation ends. See the design doc for the full rationale — in short: macOS has no
/// per-app output volume API, so this necessarily affects every app's audio, and lowering it
/// also removes most of the loudspeaker bleed DeepFilterNet can't cancel (no AEC without Apple
/// Voice Processing).
final class AudioDucker: @unchecked Sendable {

    static let shared = AudioDucker(volumeController: CoreAudioVolumeController(), scheduler: DispatchRampScheduler())

    struct Configuration: Sendable {
        var targetVolume: Float = 0.10
        var restoreDuration: TimeInterval = 1.5
    }

    private let volumeController: VolumeControlling
    private let scheduler: RampScheduler
    /// Every read/write of volume, and every mutation of the ramp state below, happens on this
    /// single serial queue — otherwise an in-flight duck and an in-flight ramp step could race
    /// and leave the device at an unintended level.
    private let queue = DispatchQueue(label: "com.openwhisper.audioducker")
    private let stepInterval: TimeInterval = 0.03
    /// Tolerance for treating a measured volume as "still what we wrote", to absorb the
    /// hardware quantization CoreAudio's docs describe for VolumeScalar ("many to one
    /// mapping" — a written value doesn't always read back bit-for-bit). Anything larger than
    /// this during a ramp is treated as a manual change (§3.3).
    private let externalChangeTolerance: Float = 0.05

    private var configuration = Configuration()
    /// The level the current duck wrote (the configured target, or a `duck(to:)` override).
    private var duckedLevel: Float?

    /// The volume to restore to. Set only when a fresh duck engages from an unducked state,
    /// cleared only when a restore ramp completes or is aborted by §3.3 — never touched by a
    /// re-duck that arrives mid-ramp (§3.2), so it always holds the pre-dictation level.
    private var originalVolume: Float?
    /// The device that was ducked; restore targets this device even if the system default
    /// output changes mid-dictation (§3.4).
    private var duckedDeviceID: AudioDeviceID?
    /// The last value *we* wrote, used to detect a manual change during a ramp (§3.3).
    private var lastWrittenVolume: Float?
    private var rampGeneration: UInt64 = 0
    private var activeRampHandle: RampTimerHandle?
    /// Step counter for the ramp currently identified by `rampGeneration`. See `rampTick`.
    private var currentRampStep: Int = 0

    init(volumeController: VolumeControlling, scheduler: RampScheduler) {
        self.volumeController = volumeController
        self.scheduler = scheduler
    }

    // MARK: Settings

    func updateConfiguration(targetVolume: Float, restoreDuration: TimeInterval) {
        queue.async { [self] in
            configuration = Configuration(
                targetVolume: min(max(targetVolume, 0.0), 1.0),
                restoreDuration: max(restoreDuration, 0.1)
            )
        }
    }

    /// Resolves and caches the current default output device's volume-control capability so
    /// the first real `duck()` — on the Fn-press critical path — only has to write, not probe.
    func prewarmOutputDeviceCapability() {
        queue.async { [self] in
            guard let deviceID = volumeController.defaultOutputDeviceID() else { return }
            _ = volumeController.currentVolume(deviceID: deviceID)
        }
    }

    #if DEBUG
    func flushQueueForTesting() {
        queue.sync {}
    }
    #endif

    // MARK: Public API

    /// Lower system volume to the configured target instantly. No-op if already at or below
    /// target (§3.1), and never overwrites a still-pending restore's target (§3.2).
    func duck() {
        queue.async { [self] in
            performDuck(target: configuration.targetVolume)
        }
    }

    /// Duck to an explicit level instead of the configured one. Voice sessions pass 0 while other
    /// media plays: the level-based auto-stop can't tell a song from speech, so the song has to
    /// be silent at the microphone. `restore()` ramps back up from this level as usual.
    func duck(to target: Float) {
        queue.async { [self] in
            performDuck(target: min(max(target, 0), 1))
        }
    }

    /// Ramp system volume back up to its pre-dictation level over the configured duration.
    /// No-op if nothing is currently ducked.
    func restore() {
        queue.async { [self] in
            performRestoreStart()
        }
    }

    /// Ramp-free restore for app shutdown (§3.7): runs synchronously so the write is guaranteed
    /// to land before the process actually exits, instead of racing an async queue hop.
    func restoreImmediatelyForTermination() {
        queue.sync {
            activeRampHandle?.stop()
            activeRampHandle = nil
            rampGeneration &+= 1
            guard let restoreLevel = originalVolume, let deviceID = duckedDeviceID else { return }
            if volumeController.setVolume(restoreLevel, deviceID: deviceID) {
                owLog("[AudioDucker] Terminating — restored volume to \(restoreLevel) instantly")
            } else {
                owLog("[AudioDucker] Terminating — restore write failed for device \(deviceID)")
            }
            originalVolume = nil
            duckedDeviceID = nil
            lastWrittenVolume = nil
        }
    }

    // MARK: Voice volume commands

    /// Applies a spoken volume command ("sesi biraz kıs") to the system output volume and
    /// returns the (before, after) levels, or nil when the volume can't be read or written.
    ///
    /// Runs on the ducker's queue, so it can't race a restore ramp. A command usually lands
    /// while the post-dictation restore is still ramping, so the current reading is the
    /// ducked level: the change is applied to the pre-dictation level instead, and the
    /// ramp is cancelled for good so it doesn't overwrite the new level.
    func applyVolumeCommand(_ transform: (Float) -> Float) -> (from: Float, to: Float)? {
        queue.sync {
            activeRampHandle?.stop()
            activeRampHandle = nil
            rampGeneration &+= 1
            guard let deviceID = duckedDeviceID ?? volumeController.defaultOutputDeviceID(),
                  let current = originalVolume ?? volumeController.currentVolume(deviceID: deviceID) else {
                owLog("[AudioDucker] Volume command aborted — could not read current volume")
                return nil
            }
            let target = min(max(transform(current), 0), 1)
            guard volumeController.setVolume(target, deviceID: deviceID) else {
                owLog("[AudioDucker] Volume command write failed for device \(deviceID)")
                return nil
            }
            if target > current { volumeController.unmute(deviceID: deviceID) }
            originalVolume = nil
            duckedDeviceID = nil
            lastWrittenVolume = nil
            owLog("[AudioDucker] Volume command \(current) → \(target)")
            return (current, target)
        }
    }

    // MARK: Duck

    private func performDuck(target: Float) {
        activeRampHandle?.stop()
        activeRampHandle = nil
        rampGeneration &+= 1

        if originalVolume != nil, let deviceID = duckedDeviceID {
            // §3.2: a new Fn press arrived while the previous restore ramp was still running.
            // Cancel the ramp (above) and jump straight back to target, but keep the already
            // stored `originalVolume` — it's the pre-dictation level, not the ramp's current
            // in-between value.
            writeDuckTarget(deviceID: deviceID, target: target)
            return
        }

        guard let deviceID = volumeController.defaultOutputDeviceID() else {
            owLog("[AudioDucker] duck() aborted — no default output device")
            return
        }
        guard let current = volumeController.currentVolume(deviceID: deviceID) else {
            // Unlike the old AppleScript implementation, an unreadable volume is never guessed
            // at — a wrong guess could raise the user's actual volume.
            owLog("[AudioDucker] duck() aborted — could not read current volume")
            return
        }
        guard current > target else {
            // §3.1: already quiet enough — leave `originalVolume` nil so restore() no-ops too.
            owLog("[AudioDucker] duck() skipped — already at/below target (\(current) <= \(target))")
            return
        }

        originalVolume = current
        duckedDeviceID = deviceID
        writeDuckTarget(deviceID: deviceID, target: target)
    }

    private func writeDuckTarget(deviceID: AudioDeviceID, target: Float) {
        if volumeController.setVolume(target, deviceID: deviceID) {
            lastWrittenVolume = target
            duckedLevel = target
            owLog("[AudioDucker] Ducked to \(target) on device \(deviceID)")
        } else {
            owLog("[AudioDucker] duck() write failed for device \(deviceID)")
        }
    }

    // MARK: Restore ramp

    private func performRestoreStart() {
        guard let restoreLevel = originalVolume, let deviceID = duckedDeviceID else { return }

        activeRampHandle?.stop()
        activeRampHandle = nil
        rampGeneration &+= 1
        let generation = rampGeneration

        // Volume perception is logarithmic, so a scalar-linear ramp sounds fast-then-slow.
        // This ratio-based curve is linear in dB by construction (v(t) = start·(end/start)^(t/T))
        // without needing the separate VolumeDecibels property, which has its own per-device
        // range and settability to probe on top of VolumeScalar's.
        let duckedLevel = max(self.duckedLevel ?? configuration.targetVolume, 0.0001) // floor avoids a zero-ratio blowup
        let duration = max(configuration.restoreDuration, stepInterval)
        let totalSteps = max(1, Int((duration / stepInterval).rounded()))
        let ratio = Double(max(restoreLevel, 0.0001) / duckedLevel)
        currentRampStep = 0

        let handle = scheduler.startRepeating(interval: stepInterval, queue: queue) { [weak self] in
            self?.rampTick(
                generation: generation,
                deviceID: deviceID,
                duckedLevel: duckedLevel,
                restoreLevel: restoreLevel,
                ratio: ratio,
                totalSteps: totalSteps
            )
        }
        activeRampHandle = handle
    }

    private func rampTick(
        generation: UInt64,
        deviceID: AudioDeviceID,
        duckedLevel: Float,
        restoreLevel: Float,
        ratio: Double,
        totalSteps: Int
    ) {
        // A newer duck()/restore() superseded this ramp — let it own the device from here.
        guard generation == rampGeneration else { return }
        // Owned exclusively by the active ramp's ticks (guarded above), so a plain instance
        // property avoids capturing a mutable local across the scheduler's escaping closure —
        // that capture trips the Swift 6 strict-concurrency checker even though this queue is
        // already the single writer for every other piece of ramp state.
        currentRampStep += 1
        let step = currentRampStep

        if let lastWritten = lastWrittenVolume,
           let measured = volumeController.currentVolume(deviceID: deviceID),
           abs(measured - lastWritten) > externalChangeTolerance {
            owLog("[AudioDucker] Ramp aborted — external volume change detected (measured \(measured), expected \(lastWritten))")
            finishRamp(clearingState: true)
            return
        }

        let isFinalStep = step >= totalSteps
        let value: Float = isFinalStep
            ? restoreLevel
            : Float(Double(duckedLevel) * pow(ratio, Double(step) / Double(totalSteps)))

        if volumeController.setVolume(value, deviceID: deviceID) {
            lastWrittenVolume = value
        } else {
            owLog("[AudioDucker] Ramp write failed at step \(step)/\(totalSteps)")
        }

        if isFinalStep {
            owLog("[AudioDucker] Restore ramp complete → \(restoreLevel)")
            finishRamp(clearingState: true)
        }
    }

    private func finishRamp(clearingState: Bool) {
        activeRampHandle?.stop()
        activeRampHandle = nil
        rampGeneration &+= 1
        if clearingState {
            originalVolume = nil
            duckedDeviceID = nil
            lastWrittenVolume = nil
        }
    }
}
