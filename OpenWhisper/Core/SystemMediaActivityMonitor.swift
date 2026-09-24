import AppKit
import CoreAudio

/// Reports whether any *other* process is currently playing audio (Spotify, a browser video,
/// Music, VLC …), from CoreAudio's per-process "is running output" flag (macOS 14.2+). Polled
/// once a second: the property is cheap and polling avoids per-process listener bookkeeping as
/// apps come and go.
///
/// "Running output" means the app has its audio IO running, not that it's audible — a paused
/// player usually stops its IO within a moment, which the off-debounce absorbs.
///
/// Processes that are also recording are skipped: those are call apps (where the listener
/// shouldn't run anyway) and always-on voice utilities, whose output IO never stops. Anything
/// else that keeps output open while silent can be ignored by bundle ID:
/// `defaults write com.openwhisper.app mediaActivityIgnoredApps -array com.example.app`
final class SystemMediaActivityMonitor {
    private let onChange: (Bool) -> Void
    private let queue = DispatchQueue(label: "com.openwhisper.media-activity", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var reported = false
    private var activeSince: Date?
    private var inactiveSince: Date?
    /// A skip or a notification sound shouldn't bounce the microphone.
    private let onDelay: TimeInterval = 1.0
    private let offDelay: TimeInterval = 3.0

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    private func poll() {
        let players = Self.outputtingProcesses(excluding: ownPID)
        let now = Date()
        if !players.isEmpty {
            inactiveSince = nil
            if activeSince == nil { activeSince = now }
            if !reported, now.timeIntervalSince(activeSince!) >= onDelay {
                reported = true
                owLog("[MediaActivity] Audio playing: \(players.joined(separator: ", "))")
                DispatchQueue.main.async { self.onChange(true) }
            }
        } else {
            activeSince = nil
            if inactiveSince == nil { inactiveSince = now }
            if reported, now.timeIntervalSince(inactiveSince!) >= offDelay {
                reported = false
                owLog("[MediaActivity] Audio stopped")
                DispatchQueue.main.async { self.onChange(false) }
            }
        }
    }

    /// Names of processes (other than us) with running audio output.
    static func outputtingProcesses(excluding excludedPID: pid_t) -> [String] {
        guard #available(macOS 14.2, *) else {
            return defaultOutputRunningSomewhere() ? ["(unknown app)"] : []
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else {
            return []
        }

        var names: [String] = []
        let ignored = Set(UserDefaults.standard.stringArray(forKey: "mediaActivityIgnoredApps") ?? [])
        for object in objects {
            guard let running: UInt32 = property(object, kAudioProcessPropertyIsRunningOutput), running != 0,
                  let pid: pid_t = property(object, kAudioProcessPropertyPID), pid != excludedPID else { continue }
            if let recording: UInt32 = property(object, kAudioProcessPropertyIsRunningInput), recording != 0 { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            if let bundleID = app?.bundleIdentifier, ignored.contains(bundleID) { continue }
            names.append(app?.localizedName ?? app?.bundleIdentifier ?? "pid \(pid)")
        }
        return names
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    /// Pre-14.2 fallback: the default output device is in use by someone.
    private static func defaultOutputRunningSomewhere() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              let running: UInt32 = property(device, kAudioDevicePropertyDeviceIsRunningSomewhere) else { return false }
        return running != 0
    }
}
