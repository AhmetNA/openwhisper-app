import AppKit
import CoreWLAN
import Foundation
import IOBluetooth
import IOKit.ps

/// Carries out a `SystemCommand` and returns the short status shown in the flow bar.
@MainActor
enum SystemController {
    static func perform(_ command: SystemCommand) async -> String {
        switch command {
        case .wifi(let on): return setWiFi(on)
        case .bluetooth(let on): return await setBluetooth(on)
        case .headset(let connect): return await setHeadset(connected: connect)
        case .mute(let mute): return setMute(mute)
        case .brightness(let up, let level): return setBrightness(up: up, level: level)
        case .darkMode(let on): return setDarkMode(on)
        case .lockScreen: return lockScreen()
        case .displaySleep: return run("/usr/bin/pmset", ["displaysleepnow"], done: "Ekran kapatıldı")
        case .sleep: return run("/usr/bin/pmset", ["sleepnow"], done: "Uyku moduna geçiliyor")
        case .screenSaver: return openScreenSaver()
        case .screenshot: return takeScreenshot()
        case .battery: return batteryStatus()
        case .time: return timeNow()
        case .openApp(let name): return openApp(name)
        case .quitApp(let name): return quitApp(name)
        case .mailCount: return await mailCount()
        case .mailCheck:
            await MailController.checkForNewMail()
            return await mailCount()
        case .mailLatest: return await mailLatest()
        case .mailOpen: return await mailOpen()
        case .mailReadUnread: return await mailReadUnread()
        case .runShortcut(let name): return runShortcut(name)
        case .briefing(let dayOffset):
            let summary = await DailyBriefing.build(dayOffset: dayOffset)
            owLog("[Briefing] \(summary.headline)")
            await DailyBriefing.notify(summary)
            return summary.headline
        case .mailMarkAllRead:
            return await MailController.markAllRead() ? "Tüm mailler okundu işaretlendi" : "Mail'e erişilemedi"
        }
    }

    // MARK: - Shortcuts

    /// Names from `shortcuts list`; only called when the transcript mentions a shortcut.
    static func shortcutNames() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
    }

    /// Not awaited: a shortcut may run for a long time or show its own UI.
    private static func runShortcut(_ name: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.terminationHandler = { owLog("[System] Shortcut '\(name)' finished with status \($0.terminationStatus)") }
        do {
            try process.run()
            owLog("[System] Running shortcut '\(name)'")
            return "“\(name)” çalıştırılıyor"
        } catch {
            owLog("[System] Shortcut '\(name)' failed: \(error)")
            return "“\(name)” çalıştırılamadı"
        }
    }

    // MARK: - Mail

    private static func mailCount() async -> String {
        guard let count = await MailController.unreadCount() else { return "Mail'e erişilemedi" }
        return count == 0 ? "Okunmamış mail yok" : "\(count) okunmamış mail"
    }

    private static func mailLatest() async -> String {
        if let unread = await MailController.unreadMessages(limit: 1)?.first {
            return "Yeni: \(unread.sender) — \(unread.subject)"
        }
        guard let newest = await MailController.newestMessage() else { return "Mail bulunamadı" }
        return "Son mail: \(newest.sender) — \(newest.subject)"
    }

    private static func mailOpen() async -> String {
        if await MailController.openNewestUnread() { return "Son okunmamış mail açıldı" }
        if let url = appURL("Mail") {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        return "Okunmamış mail yok, Mail açıldı"
    }

    private static func mailReadUnread() async -> String {
        guard let messages = await MailController.unreadMessages(limit: 3) else { return "Mail'e erişilemedi" }
        guard !messages.isEmpty else { return "Okunmamış mail yok" }
        return messages.map { "\($0.sender): \($0.subject)" }.joined(separator: " · ")
    }

    /// App names (without ".app") in the usual folders, for "X'i aç / kapat".
    static func installedApps() -> [String] {
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var names: [String] = []
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            names += items.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        }
        return names
    }

    private static func appURL(_ name: String) -> URL? {
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return folders.map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Apps

    private static func openApp(_ name: String) -> String {
        guard let url = appURL(name) else { return "\(name) bulunamadı" }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { owLog("[System] Open \(name) failed: \(error)") }
        }
        owLog("[System] Open \(name)")
        return "\(name) açılıyor"
    }

    private static func quitApp(_ name: String) -> String {
        guard let url = appURL(name), let bundleID = Bundle(url: url)?.bundleIdentifier else { return "\(name) bulunamadı" }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return "\(name) zaten kapalı" }
        // A normal quit: the app can still ask to save unsaved work.
        running.forEach { $0.terminate() }
        owLog("[System] Quit \(name)")
        return "\(name) kapatılıyor"
    }

    // MARK: - Display and session

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static let getBrightness: GetBrightness? = dlsym(displayServices, "DisplayServicesGetBrightness")
        .map { unsafeBitCast($0, to: GetBrightness.self) }
    private static let setBrightnessFunction: SetBrightness? = dlsym(displayServices, "DisplayServicesSetBrightness")
        .map { unsafeBitCast($0, to: SetBrightness.self) }

    /// Built-in display only (DisplayServices, private like the Bluetooth switch).
    private static func setBrightness(up: Bool, level: Int?) -> String {
        let display = CGMainDisplayID()
        var current: Float = 0
        guard let getBrightness, let setBrightnessFunction, getBrightness(display, &current) == 0 else {
            return "Parlaklık değiştirilemedi"
        }
        let target = level.map { Float($0) / 100 } ?? min(1, max(0.05, current + (up ? 0.2 : -0.2)))
        guard setBrightnessFunction(display, target) == 0 else { return "Parlaklık değiştirilemedi" }
        owLog(String(format: "[System] Brightness %.2f → %.2f", current, target))
        return "Parlaklık %\(Int((target * 100).rounded()))"
    }

    private static func lockScreen() -> String {
        typealias Lock = @convention(c) () -> Void
        let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW)
        guard let symbol = dlsym(login, "SACLockScreenImmediate") else { return "Ekran kilitlenemedi" }
        unsafeBitCast(symbol, to: Lock.self)()
        owLog("[System] Screen locked")
        return "Ekran kilitlendi"
    }

    private static func openScreenSaver() -> String {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return "Ekran koruyucu açıldı"
    }

    /// Saved to the Desktop like ⌘⇧3, without the shutter sound.
    private static func takeScreenshot() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let path = NSHomeDirectory() + "/Desktop/Ekran Görüntüsü \(formatter.string(from: Date())).png"
        return run("/usr/sbin/screencapture", ["-x", path], done: "Ekran görüntüsü masaüstüne kaydedildi")
    }

    private static func setMute(_ mute: Bool) -> String {
        runAppleScript("set volume output muted \(mute)") ? (mute ? "Ses kapatıldı" : "Ses açıldı") : "Ses değiştirilemedi"
    }

    /// Asks for "System Events" automation access the first time.
    private static func setDarkMode(_ on: Bool) -> String {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"
        return runAppleScript(script) ? (on ? "Karanlık mod açıldı" : "Aydınlık mod açıldı") : "Görünüm değiştirilemedi"
    }

    // MARK: - Queries

    private static func batteryStatus() -> String {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let capacity = description[kIOPSCurrentCapacityKey] as? Int
        else { return "Pil bilgisi yok" }
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        return "Pil %\(capacity)" + (charging ? ", şarj oluyor" : onAC ? ", prizde" : "")
    }

    private static func timeNow() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "HH:mm, d MMMM EEEE"
        return "Saat \(formatter.string(from: Date()))"
    }

    // MARK: - Helpers

    private static func run(_ tool: String, _ arguments: [String], done: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        do {
            try process.run()
            owLog("[System] \(tool) \(arguments.joined(separator: " "))")
            return done
        } catch {
            owLog("[System] \(tool) failed: \(error)")
            return "Yapılamadı"
        }
    }

    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { owLog("[System] AppleScript failed: \(error)") }
        return error == nil
    }

    // MARK: - Wi-Fi

    private static func setWiFi(_ on: Bool) -> String {
        guard let interface = CWWiFiClient.shared().interface() else {
            owLog("[System] No Wi-Fi interface")
            return "Wi-Fi bulunamadı"
        }
        do {
            try interface.setPower(on)
            owLog("[System] Wi-Fi \(on ? "on" : "off")")
            return on ? "Wi-Fi açıldı" : "Wi-Fi kapatıldı"
        } catch {
            owLog("[System] Wi-Fi power change failed: \(error)")
            return "Wi-Fi değiştirilemedi"
        }
    }

    // MARK: - Bluetooth power

    /// There is no public API for the Bluetooth power switch. IOBluetooth exports these two C
    /// functions (the ones `blueutil` uses); looked up at run time so a future macOS that drops
    /// them only disables this command.
    private typealias GetPower = @convention(c) () -> Int32
    private typealias SetPower = @convention(c) (Int32) -> Void
    private static let bluetoothLibrary = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
    private static let getPower: GetPower? = dlsym(bluetoothLibrary, "IOBluetoothPreferenceGetControllerPowerState")
        .map { unsafeBitCast($0, to: GetPower.self) }
    private static let setPower: SetPower? = dlsym(bluetoothLibrary, "IOBluetoothPreferenceSetControllerPowerState")
        .map { unsafeBitCast($0, to: SetPower.self) }

    private static func setBluetooth(_ on: Bool) async -> String {
        guard let getPower, let setPower else {
            owLog("[System] Bluetooth power functions unavailable")
            return "Bluetooth değiştirilemedi"
        }
        if (getPower() != 0) == on { return on ? "Bluetooth zaten açık" : "Bluetooth zaten kapalı" }
        setPower(on ? 1 : 0)
        // The controller takes a moment to switch; confirm instead of assuming.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            if (getPower() != 0) == on {
                owLog("[System] Bluetooth \(on ? "on" : "off")")
                return on ? "Bluetooth açıldı" : "Bluetooth kapatıldı"
            }
        }
        owLog("[System] Bluetooth power did not change (still \(getPower()))")
        return "Bluetooth değiştirilemedi"
    }

    // MARK: - Headset

    /// Paired audio devices (headphones, headsets, speakers), connected ones first.
    private static func audioDevices() -> [IOBluetoothDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.filter { $0.deviceClassMajor == kBluetoothDeviceClassMajorAudio }
    }

    private static func setHeadset(connected connect: Bool) async -> String {
        if connect, let getPower, getPower() == 0 {
            _ = await setBluetooth(true)
        }
        let devices = audioDevices()
        if connect {
            if let already = devices.first(where: { $0.isConnected() }) {
                return "\(already.name ?? "Kulaklık") zaten bağlı"
            }
            // The most recently used paired audio device.
            guard let device = devices.max(by: { ($0.recentAccessDate() ?? .distantPast) < ($1.recentAccessDate() ?? .distantPast) }) else {
                return "Eşleşmiş kulaklık yok"
            }
            let name = device.name ?? "Kulaklık"
            let status = await Task.detached { device.openConnection() }.value
            owLog("[System] Connect \(name): \(status)")
            return status == kIOReturnSuccess ? "\(name) bağlandı" : "\(name) bağlanamadı"
        }
        let connected = devices.filter { $0.isConnected() }
        guard !connected.isEmpty else { return "Bağlı kulaklık yok" }
        for device in connected {
            let status = device.closeConnection()
            owLog("[System] Disconnect \(device.name ?? "?"): \(status)")
        }
        let names = connected.compactMap(\.name).joined(separator: ", ")
        return "\(names.isEmpty ? "Kulaklık" : names) bağlantısı kesildi"
    }
}
