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
/// The app's own output is excluded so opening the microphone cannot keep the listener alive.
/// Other processes count even if they also record (for example a browser with microphone access).
/// Output IO is a playback proxy, not an audibility meter. Apps that keep output open while
/// silent can be ignored: `defaults write com.openwhisper.app mediaActivityIgnoredApps -array com.example.app`
final class SystemMediaActivityMonitor {
    private let onChange: (Bool) -> Void
    private let queue = DispatchQueue(label: "com.openwhisper.media-activity", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private var activity = MediaActivityDebouncer()

    deinit { timer?.cancel() }

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
        if let playing = activity.update(hasOutput: !players.isEmpty, at: ProcessInfo.processInfo.systemUptime) {
            owLog(playing ? "[MediaActivity] Audio playing: \(players.joined(separator: ", "))" : "[MediaActivity] Audio stopped")
            DispatchQueue.main.async { [weak self] in self?.onChange(playing) }
        }
    }

    /// Names of processes (other than us) with running audio output.
    static func outputtingProcesses(excluding excludedPID: pid_t) -> [String] {
        if #available(macOS 14.2, *) {
            return outputtingProcessIDs(excluding: excludedPID).map { pid in
                let app = NSRunningApplication(processIdentifier: pid)
                return app?.localizedName ?? app?.bundleIdentifier ?? "pid \(pid)"
            }
        }
        return defaultOutputRunningSomewhere() ? ["(unknown app)"] : []
    }

    static func outputtingProcessIDs(excluding excludedPID: pid_t) -> [pid_t] {
        guard #available(macOS 14.2, *) else {
            return []
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

        var pids: [pid_t] = []
        let ignored = Set(UserDefaults.standard.stringArray(forKey: "mediaActivityIgnoredApps") ?? [])
        for object in objects {
            guard let running: UInt32 = property(object, kAudioProcessPropertyIsRunningOutput), running != 0,
                  let pid: pid_t = property(object, kAudioProcessPropertyPID), pid != excludedPID else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            if let bundleID = app?.bundleIdentifier, ignored.contains(bundleID) { continue }
            pids.append(pid)
        }
        return pids
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

/// Debounces transient sounds and short playback gaps using a monotonic clock.
struct MediaActivityDebouncer {
    private(set) var isPlaying = false
    private var pendingSince: TimeInterval?

    mutating func update(hasOutput: Bool, at now: TimeInterval) -> Bool? {
        guard hasOutput != isPlaying else {
            pendingSince = nil
            return nil
        }
        guard let since = pendingSince else {
            pendingSince = now
            return nil
        }
        guard now - since >= (hasOutput ? 1.0 : 3.0) else { return nil }
        isPlaying = hasOutput
        pendingSince = nil
        return isPlaying
    }
}
