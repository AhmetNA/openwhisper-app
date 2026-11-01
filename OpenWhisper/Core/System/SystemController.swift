import AppKit
import CoreWLAN
import Foundation
import IOBluetooth
import IOKit.ps

/// Carries out a `SystemCommand` and returns the short status shown in the flow bar.
@MainActor
enum SystemController {
    static func perform(_ command: SystemCommand, disableWakeWord: (() -> Void)? = nil) async -> String {
        switch command {
        case .disableWakeWord:
            guard let disableWakeWord else { return L("Sesle uyandırma kapatılamadı", "Couldn't turn off voice wake-up") }
            disableWakeWord()
            return L("Sesle uyandırmayı kapattım. Yeniden açmak için Jarvis ayarlarını kullanabilirsin.", "Voice wake-up is off. You can turn it back on in Jarvis settings.")
        case .wifi(let on): return setWiFi(on)
        case .bluetooth(let on): return await setBluetooth(on)
        case .headset(let connect): return await setHeadset(connected: connect)
        case .mute(let mute): return setMute(mute)
        case .brightness(let up, let level): return setBrightness(up: up, level: level)
        case .darkMode(let on): return setDarkMode(on)
        case .scroll(let up, let large): return scroll(up: up, large: large)
        case .lockScreen: return lockScreen()
        case .displaySleep: return run("/usr/bin/pmset", ["displaysleepnow"], done: L("Ekran kapatıldı", "Display off"))
        case .displayWake: return RemoteControl.wakeDisplay() ? L("Ekran açıldı", "Display on") : L("Ekran açılamadı", "Couldn't wake the display")
        case .unlockRequest: return RemoteControl.unlockAnswer
        case .sleep: return run("/usr/bin/pmset", ["sleepnow"], done: L("Uyku moduna geçiliyor", "Going to sleep"))
        case .screenSaver: return openScreenSaver()
        case .screenshot: return takeScreenshot()
        case .battery: return batteryStatus()
        case .time: return timeNow()
        case .openApp(let name): return openApp(name)
        case .quitApp(let name): return quitApp(name)
        case .forceQuitApp(let name): return forceQuitApp(name)
        case .switchToApp(let name): return await switchToApp(name)
        case .switchToAgent(let agent):
            return await AgentAppActivator.activate(agent) != nil ? frontStatus(agent.displayName) : L("\(agent.displayName) açılamadı", "Couldn't open \(agent.displayName)")
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
            return await MailController.markAllRead() ? L("Tüm mailler okundu işaretlendi", "All mail marked as read") : noMailAccess
        case .calendarEvent(let event): return await CalendarController.add(event)
        case .browser(let action): return await BrowserController.perform(action)
        case .video(let action): return await VideoController.perform(action)
        case .openFile(let query): return await FileFinder.open(query)
        case .window(let action): return await WindowManager.perform(action)
        case .clipboard(.openLink): return await ClipboardHistory.shared.openLatestLink()
        case .reading(let action): return read(action)
        // Run by the command runner, which needs the session (`AppState.runScene`, WhatsApp).
        case .scene(let name): return L("\(name) sahnesi burada çalıştırılamaz", "The \(name) scene can't run here")
        case .clipboard(.sendWhatsApp): return L("Pano buradan gönderilemez", "The clipboard can't be sent from here")
        }
    }

    // MARK: - Reading

    nonisolated static var nothingToRead: String { L("Okunacak metin bulunamadı", "No text found to read") }
    nonisolated static var nothingToResume: String { L("Devam edecek bir okuma yok", "No reading to resume") }
    /// "Okunuyor: <title>"; `JarvisReply` stays silent on it, the reading follows.
    nonisolated static var readingPrefix: String { L("Okunuyor", "Reading") }
    nonisolated static var readingResumed: String { L("Okumaya devam ediliyor", "Resuming the reading") }

    /// Loads or checks the reading; the caller starts it after its reply (`ArticleReader.start`).
    private static func read(_ action: ReadingAction) -> String {
        let reader = ArticleReader.shared
        switch action {
        case .start:
            guard let title = reader.load() else { return nothingToRead }
            return "\(readingPrefix): \(title)"
        case .resume:
            return reader.isPaused ? readingResumed : nothingToResume
        case .stop:
            reader.stop()
            return L("Okuma durdu", "Reading stopped")
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
            return L("“\(name)” çalıştırılıyor", "Running “\(name)”")
        } catch {
            owLog("[System] Shortcut '\(name)' failed: \(error)")
            return L("“\(name)” çalıştırılamadı", "Couldn't run “\(name)”")
        }
    }

    // MARK: - Mail

    private static func mailCount() async -> String {
        guard let count = await MailController.unreadCount() else { return noMailAccess }
        return count == 0 ? noUnreadMail : L("\(count) okunmamış mail", count == 1 ? "1 unread mail" : "\(count) unread mails")
    }

    private static func mailLatest() async -> String {
        if let unread = await MailController.unreadMessages(limit: 1)?.first {
            return L("Yeni: ", "New: ") + "\(unread.sender) — \(unread.subject)"
        }
        guard let newest = await MailController.newestMessage() else { return L("Mail bulunamadı", "No mail found") }
        return L("Son mail: ", "Latest mail: ") + "\(newest.sender) — \(newest.subject)"
    }

    private static func mailOpen() async -> String {
        if await MailController.openNewestUnread() { return L("Son okunmamış mail açıldı", "Opened the latest unread mail") }
        if let url = appURL("Mail") {
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        return L("Okunmamış mail yok, Mail açıldı", "No unread mail, opened Mail")
    }

    /// The flow bar shows up to this much of the mail text; Jarvis says less (`JarvisReply`).
    private static let mailBodyLimit = 400

    private static func mailReadLatest() async -> String {
        guard let mail = await MailController.newestMessageWithBody() else { return noMailAccess }
        var text = mail.body
        if text.count > mailBodyLimit { text = String(text.prefix(mailBodyLimit)) + "…" }
        if CommandLanguage.isEnglish {
            let subject = mail.subject.isEmpty ? "no subject" : "subject: \(mail.subject)"
            return "From \(mail.sender), \(subject). \(text.isEmpty ? "The text is empty." : text)"
        }
        let subject = mail.subject.isEmpty ? "konusuz" : "konu: \(mail.subject)"
        return text.isEmpty ? "Gönderen \(mail.sender), \(subject). Metin boş."
            : "Gönderen \(mail.sender), \(subject). \(text)"
    }

    /// `name` is as heard ("Ahmet"); the answer uses the sender's own name from Mail.
    private static func mailFrom(_ name: String) async -> String {
        guard let found = await MailController.messages(from: name) else { return noMailAccess }
        guard let newest = found.first else { return L("Son maillerde gönderen \(name) olan mail yok", "No recent mail from \(name)") }
        let unread = found.filter(\.unread).count
        if CommandLanguage.isEnglish {
            let count = found.count == 1 ? "1 mail" : "\(found.count) mails"
            let unreadPart = unread == 0 ? "" : unread == found.count ? ", all unread" : ", \(unread) unread"
            return "\(newest.message.sender): \(count)\(unreadPart). The latest: \(newest.message.subject)"
        }
        let count = found.count == 1 ? "1 mail" : "\(found.count) mail"
        let unreadPart = unread == 0 ? "" : unread == found.count ? ", hepsi okunmamış" : ", \(unread) tanesi okunmamış"
        return "\(newest.message.sender): \(count)\(unreadPart). Sonuncusu: \(newest.message.subject)"
    }

    /// Never sends: the draft opens in Mail and the user presses Send there.
    private static func mailReplyDraft(_ text: String) async -> String {
        guard let original = await MailController.openReplyDraft(text) else { return L("Cevap taslağı açılamadı", "Couldn't open a reply draft") }
        if CommandLanguage.isEnglish {
            return text.isEmpty ? "I opened an empty reply to \(original.sender), you can write it before sending"
                : "The reply draft to \(original.sender) is ready. Press Send in Mail to send it"
        }
        let to = "\(original.sender) adlı kişiye"
        return text.isEmpty ? "\(to) boş cevap açtım, göndermeden önce yazabilirsin"
            : "\(to) cevap taslağı hazır. Göndermek için Mail'de Gönder'e bas"
    }

    private static func mailReadUnread() async -> String {
        guard let messages = await MailController.unreadMessages(limit: 3) else { return noMailAccess }
        guard !messages.isEmpty else { return noUnreadMail }
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

    private static var noMailAccess: String { L("Mail'e erişilemedi", "Couldn't reach Mail") }
    private static var noUnreadMail: String { L("Okunmamış mail yok", "No unread mail") }

    /// "Safari önde": also how the runner tells the switch worked.
    nonisolated static func frontStatus(_ name: String) -> String { L("\(name) önde", "\(name) in front") }
    private static func notFound(_ name: String) -> String { L("\(name) bulunamadı", "\(name) not found") }
    private static func alreadyClosed(_ name: String) -> String { L("\(name) zaten kapalı", "\(name) is already closed") }

    // MARK: - Apps

    private static func openApp(_ name: String) -> String {
        guard let url = appURL(name) else { return notFound(name) }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { owLog("[System] Open \(name) failed: \(error)") }
        }
        owLog("[System] Open \(name)")
        return L("\(name) açılıyor", "Opening \(name)")
    }

    /// Opens the app with activation (which also switches to its full-screen Space and
    /// launches it if needed) and waits until it is frontmost: a chained "… ve videoyu
    /// başlat" must run in it, not in the app that was in front before.
    private static func switchToApp(_ name: String) async -> String {
        guard let url = appURL(name) else { return notFound(name) }
        let bundleID = Bundle(url: url)?.bundleIdentifier
        if let bundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return L("\(name) zaten önde", "\(name) is already in front") }
        let wasRunning = bundleID.map { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? false
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let pid: pid_t
        do {
            pid = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration).processIdentifier
        } catch {
            owLog("[System] Switch to \(name) failed: \(error)")
            return L("\(name) açılamadı", "Couldn't open \(name)")
        }
        let deadline = Date().addingTimeInterval(wasRunning ? 2 : 10)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                // Let its window come up and take keyboard focus before the next command.
                try? await Task.sleep(nanoseconds: wasRunning ? 200_000_000 : 1_000_000_000)
                owLog("[System] Switched to \(name) (launched: \(!wasRunning))")
                return frontStatus(name)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        owLog("[System] \(name) did not come to the front in time")
        return L("\(name) öne gelemedi", "\(name) didn't come to the front")
    }

    private static func quitApp(_ name: String) -> String {
        guard let url = appURL(name), let bundleID = Bundle(url: url)?.bundleIdentifier else { return notFound(name) }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !running.isEmpty else { return alreadyClosed(name) }
        // A normal quit: the app can still ask to save unsaved work.
        running.forEach { $0.terminate() }
        owLog("[System] Quit \(name)")
        return L("\(name) kapatılıyor", "Quitting \(name)")
    }

    /// Kills the app with SIGKILL together with everything that belongs to it: helper processes
    /// whose executable lives inside the .app bundle (Chrome/Electron renderers, crash
    /// reporters) and every descendant the app spawned. Unsaved work is lost.
    private static func forceQuitApp(_ name: String) -> String {
        guard let url = appURL(name) else { return notFound(name) }
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
        guard !targets.isEmpty else { return alreadyClosed(name) }
        let killed = targets.filter { kill($0, SIGKILL) == 0 }
        owLog("[System] Force quit \(name): killed \(killed.count)/\(targets.count) processes")
        return killed.isEmpty ? L("\(name) kapatılamadı", "Couldn't quit \(name)") : L("\(name) zorla kapatıldı", "Force quit \(name)")
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
    /// Half the front window ("kaydır"), most of it ("çok kaydır"), glided over ~0.45 s rather
    /// than jumped: 7 lines at once moved too little, too abruptly to follow.
    private static func scroll(up: Bool, large: Bool) -> String {
        SystemCommandParser.lastScrollUp = up
        guard AXIsProcessTrusted() else {
            return L("Ekran kaydırılamadı: Erişilebilirlik izni gerekli", "Couldn't scroll: Accessibility permission needed")
        }
        let window = NSWorkspace.shared.frontmostApplication.flatMap(ScreenReader.focusedWindow(of:))
        let frame = window.flatMap { ScreenReader.node($0).frame }
        let height = frame?.height ?? NSScreen.main?.visibleFrame.height ?? 800
        let distance = height * (large ? 0.9 : 0.5)
        // Over the window itself, not wherever the pointer happens to be.
        let point = frame.map { CGPoint(x: $0.midX, y: $0.midY) }
        DispatchQueue.global(qos: .userInteractive).async {
            let steps = 24
            var moved = 0.0
            for step in 1...steps {
                // Ease in and out: slow start, fast middle, slow end.
                let target = distance * (1 - cos(Double(step) / Double(steps) * .pi)) / 2
                let delta = Int32((target - moved).rounded())
                moved += Double(delta)
                if delta != 0, let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                   wheel1: up ? delta : -delta, wheel2: 0, wheel3: 0) {
                    if let point { event.location = point }
                    event.post(tap: .cghidEventTap)
                }
                usleep(19_000)
            }
        }
        owLog("[System] Scroll \(up ? "up" : "down") \(Int(distance)) pt")
        return up ? L("Yukarı kaydırıldı", "Scrolled up") : L("Aşağı kaydırıldı", "Scrolled down")
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
            return brightnessFailed
        }
        let target = level.map { Float($0) / 100 } ?? min(1, max(0.05, current + (up ? 0.2 : -0.2)))
        guard setBrightnessFunction(display, target) == 0 else { return brightnessFailed }
        owLog(String(format: "[System] Brightness %.2f → %.2f", current, target))
        let percent = Int((target * 100).rounded())
        return L("Parlaklık %\(percent)", "Brightness \(percent)%")
    }

    private static var brightnessFailed: String { L("Parlaklık değiştirilemedi", "Couldn't change the brightness") }

    private static func lockScreen() -> String {
        typealias Lock = @convention(c) () -> Void
        let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW)
        guard let symbol = dlsym(login, "SACLockScreenImmediate") else { return L("Ekran kilitlenemedi", "Couldn't lock the screen") }
        unsafeBitCast(symbol, to: Lock.self)()
        owLog("[System] Screen locked")
        return L("Ekran kilitlendi", "Screen locked")
    }

    private static func openScreenSaver() -> String {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return L("Ekran koruyucu açıldı", "Screen saver on")
    }

    /// Saved to the Desktop like ⌘⇧3, without the shutter sound.
    private static func takeScreenshot() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let path = NSHomeDirectory() + "/Desktop/Ekran Görüntüsü \(formatter.string(from: Date())).png"
        return run("/usr/sbin/screencapture", ["-x", path], done: L("Ekran görüntüsü masaüstüne kaydedildi", "Screenshot saved to the Desktop"))
    }

    private static func setMute(_ mute: Bool) -> String {
        runAppleScript("set volume output muted \(mute)") ? (mute ? L("Ses kapatıldı", "Sound muted") : L("Ses açıldı", "Sound on")) : L("Ses değiştirilemedi", "Couldn't change the sound")
    }

    /// Asks for "System Events" automation access the first time.
    private static func setDarkMode(_ on: Bool) -> String {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)"
        return runAppleScript(script) ? (on ? L("Karanlık mod açıldı", "Dark mode on") : L("Aydınlık mod açıldı", "Light mode on")) : L("Görünüm değiştirilemedi", "Couldn't change the appearance")
    }

    // MARK: - Queries

    private static func batteryStatus() -> String {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        guard let source = sources.first,
              let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              let capacity = description[kIOPSCurrentCapacityKey] as? Int
        else { return L("Pil bilgisi yok", "No battery info") }
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        return L("Pil %\(capacity)", "Battery \(capacity)%") + (charging ? L(", şarj oluyor", ", charging") : onAC ? L(", prizde", ", plugged in") : "")
    }

    private static func timeNow() -> String {
        let formatter = DateFormatter()
        formatter.locale = CommandLanguage.locale
        formatter.dateFormat = "HH:mm, d MMMM EEEE"
        return "\(CommandLanguage.isEnglish ? "It's" : "Saat") \(formatter.string(from: Date()))"
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
            return L("Yapılamadı", "Couldn't do it")
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
            return L("Wi-Fi bulunamadı", "Wi-Fi not found")
        }
        // As with Bluetooth: say so when nothing changes, instead of "açıldı" for a no-op.
        if interface.powerOn() == on { return on ? L("Wi-Fi zaten açık", "Wi-Fi is already on") : L("Wi-Fi zaten kapalı", "Wi-Fi is already off") }
        do {
            try interface.setPower(on)
            owLog("[System] Wi-Fi \(on ? "on" : "off")")
            return on ? L("Wi-Fi açıldı", "Wi-Fi on") : L("Wi-Fi kapatıldı", "Wi-Fi off")
        } catch {
            owLog("[System] Wi-Fi power change failed: \(error)")
            return L("Wi-Fi değiştirilemedi", "Couldn't change Wi-Fi")
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
            return bluetoothFailed
        }
        if (getPower() != 0) == on { return on ? L("Bluetooth zaten açık", "Bluetooth is already on") : L("Bluetooth zaten kapalı", "Bluetooth is already off") }
        setPower(on ? 1 : 0)
        // The controller takes a moment to switch; confirm instead of assuming.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            if (getPower() != 0) == on {
                owLog("[System] Bluetooth \(on ? "on" : "off")")
                return on ? L("Bluetooth açıldı", "Bluetooth on") : L("Bluetooth kapatıldı", "Bluetooth off")
            }
        }
        owLog("[System] Bluetooth power did not change (still \(getPower()))")
        return bluetoothFailed
    }

    private static var bluetoothFailed: String { L("Bluetooth değiştirilemedi", "Couldn't change Bluetooth") }

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
                return L("\(already.name ?? "Kulaklık") zaten bağlı", "\(already.name ?? "The headset") is already connected")
            }
            // The most recently used paired audio device.
            guard let device = devices.max(by: { ($0.recentAccessDate() ?? .distantPast) < ($1.recentAccessDate() ?? .distantPast) }) else {
                return L("Eşleşmiş kulaklık yok", "No paired headset")
            }
            let name = device.name ?? L("Kulaklık", "Headset")
            let status = await Task.detached { device.openConnection() }.value
            owLog("[System] Connect \(name): \(status)")
            return status == kIOReturnSuccess ? L("\(name) bağlandı", "\(name) connected") : L("\(name) bağlanamadı", "Couldn't connect \(name)")
        }
        let connected = devices.filter { $0.isConnected() }
        guard !connected.isEmpty else { return L("Bağlı kulaklık yok", "No headset connected") }
        for device in connected {
            let status = device.closeConnection()
            owLog("[System] Disconnect \(device.name ?? "?"): \(status)")
        }
        let names = connected.compactMap(\.name).joined(separator: ", ")
        return L("\(names.isEmpty ? "Kulaklık" : names) bağlantısı kesildi", "\(names.isEmpty ? "Headset" : names) disconnected")
    }
}
