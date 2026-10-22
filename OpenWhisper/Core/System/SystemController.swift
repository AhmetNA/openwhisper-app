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
        case .scroll(let up, let large): return scroll(up: up, large: large)
        case .lockScreen: return lockScreen()
        case .displaySleep: return run("/usr/bin/pmset", ["displaysleepnow"], done: "Ekran kapatıldı")
        case .displayWake: return RemoteControl.wakeDisplay() ? "Ekran açıldı" : "Ekran açılamadı"
        case .unlockRequest: return RemoteControl.unlockAnswer
        case .sleep: return run("/usr/bin/pmset", ["sleepnow"], done: "Uyku moduna geçiliyor")
        case .screenSaver: return openScreenSaver()
        case .screenshot: return takeScreenshot()
        case .battery: return batteryStatus()
        case .time: return timeNow()
        case .openApp(let name): return openApp(name)
        case .quitApp(let name): return quitApp(name)
        case .forceQuitApp(let name): return forceQuitApp(name)
        case .switchToApp(let name): return await switchToApp(name)
        case .switchToAgent(let agent):
            return await AgentAppActivator.activate(agent) != nil ? "\(agent.displayName) önde" : "\(agent.displayName) açılamadı"
        case .mailCount: return await mailCount()
        case .mailCheck:
            await MailController.checkForNewMail()
            return await mailCount()
        case .mailLatest: return await mailLatest()
        case .mailOpen: return await mailOpen()
        case .mailReadUnread: return await mailReadUnread()
        case .mailReadLatest: return await mailReadLatest()
        case .mailFrom(let name): return await mailFrom(name)
        case .mailReplyDraft(let text): return await mailReplyDraft(text)
        case .whatsAppUnread: return await WhatsAppController.unreadSummary()
        case .whatsAppFrom(let name): return await WhatsAppController.latest(from: name)
        case .whatsAppConversation(let name): return await WhatsAppController.conversation(with: name)
        case .whatsAppSearch(let topic, let person): return await WhatsAppController.search(topic: topic, person: person)
        case .runShortcut(let name): return runShortcut(name)
        case .briefing(let dayOffset):
            let summary = await DailyBriefing.build(dayOffset: dayOffset)
            owLog("[Briefing] \(summary.headline)")
            await DailyBriefing.notify(summary)
            return summary.headline
        case .mailMarkAllRead:
            return await MailController.markAllRead() ? "Tüm mailler okundu işaretlendi" : "Mail'e erişilemedi"
        case .developerMode: return await startDeveloperMode()
        case .calendarEvent(let event): return await CalendarController.add(event)
        case .browser(let action): return await BrowserController.perform(action)
        case .video(let action): return await VideoController.perform(action)
        }
    }

    // MARK: - Developer mode

    /// Claude, then ChatGPT. On this Mac ChatGPT.app is the merged ChatGPT + Codex app
    /// (bundle ID com.openai.codex); the older com.openai.chat is tried too, each app once.
    private static let claudeBundleID = "com.anthropic.claudefordesktop"
    private static let developerAppBundleIDs = [claudeBundleID, "com.openai.codex", "com.openai.chat"]
    private static let developerModeVolume = 40

    /// Volume first, so the music starts at 40%. Only Claude is activated: ChatGPT opens behind
    /// it and Spotify stays behind both.
    private static func startDeveloperMode() async -> String {
        let volume = SystemVolume.set(developerModeVolume)
        var opened: [String] = []
        var seen = Set<URL>()
        for bundleID in developerAppBundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  seen.insert(url.standardizedFileURL).inserted else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = bundleID == claudeBundleID
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { owLog("[System] Developer mode: open \(name) failed: \(error)") }
            }
            opened.append(name)
        }
        let music = await SpotifyController.shared.playLikedSongs()
        keepClaudeInFront()
        owLog("[System] Developer mode: apps \(opened), volume \(volume.message), music \(music.message)")
        let apps = opened.isEmpty ? "Claude ve ChatGPT bulunamadı" : opened.joined(separator: ", ") + " açıldı"
        let sound = volume.succeeded ? "ses %\(developerModeVolume)" : volume.message
        return "Developer modu: \(apps) · \(sound) · \(music.message)"
    }

    /// A cold-launching ChatGPT (or Spotify) can still take the front a few seconds later despite
    /// `activates = false`, so Claude is brought back once its launch has settled.
    private static func keepClaudeInFront() {
        Task { @MainActor in
            for delay: UInt64 in [1_500_000_000, 3_000_000_000] {
                try? await Task.sleep(nanoseconds: delay)
                // Only undo a developer-mode launch, never an app the user switched to meanwhile.
                guard let front = NSWorkspace.shared.frontmostApplication,
                      let frontID = front.bundleIdentifier, frontID != claudeBundleID,
                      developerAppBundleIDs.contains(frontID) || frontID == "com.spotify.client",
                      let claude = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first
                else { continue }
                owLog("[System] Developer mode: \(front.localizedName ?? frontID) took the front, bringing Claude back")
                _ = await AgentAppActivator.bringToFront(claude)
            }
        }
    }

    // MARK: - Shortcuts

    /// Names from `shortcuts list`; only called when the transcript mentions a shortcut.
    nonisolated static func shortcutNames() -> [String] {
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

    /// The flow bar shows up to this much of the mail text; Jarvis says less (`JarvisReply`).
    private static let mailBodyLimit = 400

    private static func mailReadLatest() async -> String {
        guard let mail = await MailController.newestMessageWithBody() else { return "Mail'e erişilemedi" }
        var text = mail.body
        if text.count > mailBodyLimit { text = String(text.prefix(mailBodyLimit)) + "…" }
        let subject = mail.subject.isEmpty ? "konusuz" : "konu: \(mail.subject)"
        return text.isEmpty ? "Gönderen \(mail.sender), \(subject). Metin boş."
            : "Gönderen \(mail.sender), \(subject). \(text)"
    }

    /// `name` is as heard ("Ahmet"); the answer uses the sender's own name from Mail.
    private static func mailFrom(_ name: String) async -> String {
        guard let found = await MailController.messages(from: name) else { return "Mail'e erişilemedi" }
        guard let newest = found.first else { return "Son maillerde gönderen \(name) olan mail yok" }
        let unread = found.filter(\.unread).count
        let count = found.count == 1 ? "1 mail" : "\(found.count) mail"
        let unreadPart = unread == 0 ? "" : unread == found.count ? ", hepsi okunmamış" : ", \(unread) tanesi okunmamış"
        return "\(newest.message.sender): \(count)\(unreadPart). Sonuncusu: \(newest.message.subject)"
    }

    /// Never sends: the draft opens in Mail and the user presses Send there.
    private static func mailReplyDraft(_ text: String) async -> String {
        guard let original = await MailController.openReplyDraft(text) else { return "Cevap taslağı açılamadı" }
        let to = "\(original.sender) adlı kişiye"
        return text.isEmpty ? "\(to) boş cevap açtım, göndermeden önce yazabilirsin"
            : "\(to) cevap taslağı hazır. Göndermek için Mail'de Gönder'e bas"
    }

    private static func mailReadUnread() async -> String {
        guard let messages = await MailController.unreadMessages(limit: 3) else { return "Mail'e erişilemedi" }
        guard !messages.isEmpty else { return "Okunmamış mail yok" }
        return messages.map { "\($0.sender): \($0.subject)" }.joined(separator: " · ")
    }

    /// App names (without ".app") in the usual folders, for "X'i aç / kapat".
    nonisolated static func installedApps() -> [String] {
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var names: [String] = []
        for folder in folders {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            names += items.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        }
        // Not in the folders above, but "Finder'a geç" should work.
        return names + ["Finder"]
    }

    private static func appURL(_ name: String) -> URL? {
        let folders = ["/Applications", "/Applications/Utilities", "/System/Applications",
                       "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        if name == "Finder" { return URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app") }
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

    /// Opens the app with activation (which also switches to its full-screen Space and
    /// launches it if needed) and waits until it is frontmost: a chained "… ve videoyu
    /// başlat" must run in it, not in the app that was in front before.
    private static func switchToApp(_ name: String) async -> String {
        guard let url = appURL(name) else { return "\(name) bulunamadı" }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        if let bundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return "\(name) zaten önde" }
        let wasRunning = bundleID.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let pid: pid_t
        do {
            pid = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier
        } catch {
            owLog("[System] Switch to \(name) failed: \(error)")
            return "\(name) açılamadı"
        }
        let deadline = Date().addingTimeInterval(wasRunning ? 2 : 10)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                // Let its window come up and take keyboard focus before the next command.
                try? await Task.sleep(nanoseconds: wasRunning ? 200_000_000 : 1_000_000_000)
                owLog("[System] Switched to \(name) (launched: \(!wasRunning))")
                return "\(name) önde"
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        owLog("[System] \(name) did not come to the front in time")
        return "\(name) öne gelemedi"
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

    /// Kills the app with SIGKILL together with everything that belongs to it: helper processes
    /// whose executable lives inside the .app bundle (Chrome/Electron renderers, crash
    /// reporters) and every descendant the app spawned. Unsaved work is lost.
    private static func forceQuitApp(_ name: String) -> String {
        guard let url = appURL(name) else { return "\(name) bulunamadı" }
        let bundlePath = url.resolvingSymlinksInPath().path + "/"
        let processes = allProcesses()
        var targets = Set(processes.filter { $0.path.hasPrefix(bundlePath) }.map(\.pid))
        // Descendants: a child may live outside the bundle (a shell, a node server, …).
        var grew = true
        while grew {
            let children = processes.filter { targets.contains($0.ppid) && !targets.contains($0.pid) }
            targets.formUnion(children.map(\.pid))
            grew = !children.isEmpty
        }
        // Never Jarvis itself, or whatever it runs inside of.
        var protected: Set<pid_t> = [getpid()]
        var ancestor = getppid()
        while ancestor > 1, protected.insert(ancestor).inserted {
            ancestor = processes.first { $0.pid == ancestor }?.ppid ?? 1
        }
        targets.subtract(protected)
        guard !targets.isEmpty else { return "\(name) zaten kapalı" }
        let killed = targets.filter { kill($0, SIGKILL) == 0 }
        owLog("[System] Force quit \(name): killed \(killed.count)/\(targets.count) processes")
        return killed.isEmpty ? "\(name) kapatılamadı" : "\(name) zorla kapatıldı"
    }

    private struct ProcessEntry { let pid: pid_t; let ppid: pid_t; let path: String }

    private static func allProcesses() -> [ProcessEntry] {
        let capacity = proc_listallpids(nil, 0) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = length > 0 ? String(cString: pathBuffer) : ""
            return ProcessEntry(pid: pid, ppid: pid_t(info.pbi_ppid), path: path)
        }
    }

    // MARK: - Display and session

    /// Sends a real scroll-wheel event without changing the frontmost app or pointer position.
    /// Line-based scrolling follows the target app's own scrolling behavior and works in both
    /// native views and Chromium/Electron content such as Codex.
    private static func scroll(up: Bool, large: Bool) -> String {
        guard AXIsProcessTrusted() else {
            return "Ekran kaydırılamadı: Erişilebilirlik izni gerekli"
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: up ? (large ? 21 : 7) : (large ? -21 : -7),
            wheel2: 0,
            wheel3: 0
        ) else {
            return "Ekran kaydırılamadı"
        }
        event.post(tap: .cghidEventTap)
        owLog("[System] Scroll \(up ? "up" : "down") \(large ? "large" : "normal")")
        return up ? "Yukarı kaydırıldı" : "Aşağı kaydırıldı"
    }

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
        // As with Bluetooth: say so when nothing changes, instead of "açıldı" for a no-op.
        if interface.powerOn() == on { return on ? "Wi-Fi zaten açık" : "Wi-Fi zaten kapalı" }
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
