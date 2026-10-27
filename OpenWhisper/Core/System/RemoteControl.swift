import AppKit
import IOKit.ps
import IOKit.pwr_mgt

/// "Uzaktan kontrol": with a microphone across the room, "Jarvis" must still be heard once the
/// display has gone dark. True system sleep stops the CPU and the mic, so nothing can wake it
/// by voice; this keeps the system awake while the display sleeps, and the wake-word listener
/// keeps running (`AppState.updateWakeWordListener`).
///
/// Unlocking is never done by voice: macOS ignores synthetic input at the lock screen, and a
/// spoken unlock would let anyone in the room in. The answer points to Apple Watch unlock.
@MainActor
final class RemoteControl {
    /// On battery below this the Mac is let sleep again, so a forgotten switch can't drain it.
    static let minimumBatteryPercent = 20
    static let unlockAnswer = "Kilidi sesle açamam; Apple Watch ile ya da şifrenizle açabilirsiniz"
    static let lockedAnswer = "Mac kilitli; bunu kilidi açınca yapabilirim"

    /// Whether the assertion is held now; false while switched off or on low battery.
    private(set) var isHoldingAwake = false
    /// Called when `isHoldingAwake` changes.
    var onChange: (() -> Void)?
    private var wanted = false
    private var assertionID: IOPMAssertionID = 0
    private var powerTimer: Timer?

    func setEnabled(_ enabled: Bool) {
        wanted = enabled
        powerTimer?.invalidate()
        powerTimer = nil
        if enabled {
            // Battery level and power source are checked once a minute while on.
            powerTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        let battery = Self.batteryPercentOnBattery()
        let lowBattery = battery.map { $0 < Self.minimumBatteryPercent } ?? false
        let hold = wanted && !lowBattery
        guard hold != isHoldingAwake else { return }
        if hold {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Jarvis uzaktan kontrol: ekran kapalıyken dinliyor" as CFString, &id)
            guard result == kIOReturnSuccess else {
                owLog("[RemoteControl] Could not hold the Mac awake (IOReturn \(result))")
                return
            }
            assertionID = id
            isHoldingAwake = true
            owLog("[RemoteControl] Holding the Mac awake; the display may sleep, \"Jarvis\" keeps listening")
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isHoldingAwake = false
            if let battery, wanted {
                owLog("[RemoteControl] On battery at \(battery)% (below \(Self.minimumBatteryPercent)%): released, the Mac may sleep; held again on power")
            } else {
                owLog("[RemoteControl] Switched off: released, the Mac may sleep")
            }
        }
        onChange?()
    }

    /// The battery level while running on battery; nil on power or without a battery.
    private static func batteryPercentOnBattery() -> Int? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String == kIOPMBatteryPowerKey else { return nil }
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let capacity = description[kIOPSCurrentCapacityKey] as? Int else { return nil }
        return capacity
    }

    // MARK: - Power log

    private var cpuLogTimer: Timer?
    private var asleepSince: (cpu: Double, uptime: TimeInterval)?
    private var lastSample: (cpu: Double, uptime: TimeInterval)?

    /// While the display sleeps, Jarvis's own CPU use once a minute and for the whole stretch, so
    /// the cost of listening with the display off is in the log (`[Power]`).
    func logPower(displayAsleep: Bool) {
        cpuLogTimer?.invalidate()
        cpuLogTimer = nil
        let now = (cpu: Self.processCPUSeconds(), uptime: ProcessInfo.processInfo.systemUptime)
        if displayAsleep {
            asleepSince = now
            lastSample = now
            cpuLogTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let last = self.lastSample else { return }
                    let sample = (cpu: Self.processCPUSeconds(), uptime: ProcessInfo.processInfo.systemUptime)
                    owLog(String(format: "[Power] Display asleep: Jarvis used %.1f%% of one core in the last minute",
                                 Self.percent(from: last, to: sample)))
                    self.lastSample = sample
                }
            }
        } else if let since = asleepSince {
            asleepSince = nil
            owLog(String(format: "[Power] Display was asleep %.0f min: Jarvis used %.1f%% of one core on average",
                         (now.uptime - since.uptime) / 60, Self.percent(from: since, to: now)))
        }
    }

    private static func percent(from a: (cpu: Double, uptime: TimeInterval), to b: (cpu: Double, uptime: TimeInterval)) -> Double {
        b.uptime > a.uptime ? (b.cpu - a.cpu) / (b.uptime - a.uptime) * 100 : 0
    }

    /// User + system CPU time of this process so far.
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    // MARK: - Display and lock

    private static var userActivityID: IOPMAssertionID = 0

    /// Lights the display as a key press would; a locked Mac shows its lock screen.
    static func wakeDisplay() -> Bool {
        let result = IOPMAssertionDeclareUserActivity("Jarvis: ekranı aç" as CFString, kIOPMUserActiveLocal, &userActivityID)
        owLog("[System] Display wake requested (IOReturn \(result))")
        return result == kIOReturnSuccess
    }

    /// The login window covers the session: nothing can be typed into apps or seen on screen.
    static var screenIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
    }

    /// Routes that type into an app or need it in front.
    static func needsUnlockedScreen(_ route: VoiceRouter.Route) -> Bool {
        switch route {
        case .agent, .agentWithoutForeground, .typed, .dictationEdit, .whatsAppSend: return true
        case .command(let command): return needsUnlockedScreen(command)
        case .commands(let steps): return steps.contains { needsUnlockedScreen($0.command) }
        default: return false
        }
    }

    /// Commands that act on what is on screen or type into an app; with the Mac locked they
    /// would do nothing (or type into the lock screen), so the user is told instead.
    static func needsUnlockedScreen(_ command: VoiceCommand) -> Bool {
        guard case .system(let system) = command else { return false }
        switch system {
        case .scroll, .screenshot, .switchToApp, .switchToAgent, .mailReplyDraft, .mailOpen:
            return true
        case .browser(let action):
            return action != .summarize
        default:
            return false
        }
    }
}
