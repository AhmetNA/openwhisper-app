import AppKit
import AVFoundation
import CoreBluetooth
import EventKit
import Foundation
import UserNotifications

/// Every macOS permission Jarvis uses, its live status, and a way to ask for it or open its
/// System Settings page. Shown in Settings › İzinler.
@MainActor
@Observable
final class PermissionsManager {
    enum Status: Equatable {
        case granted
        case denied
        case notDetermined
        case needsSettings, restricted, writeOnly, unavailable
        /// Automation target that isn't running, so macOS can't answer yet.
        case unknown(String)

        var label: String {
            switch self {
            case .granted: "Verildi"
            case .denied: "Reddedildi"
            case .notDetermined: "Henüz sorulmadı"
            case .needsSettings: "İzin gerekli"
            case .unavailable: "Uygulama yüklü değil"
            case .restricted: "Sistem tarafından kısıtlı"
            case .writeOnly: "Yalnızca yazma"
            case .unknown(let why): why
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case microphone, accessibility, screenRecording, calendars, reminders, bluetooth, notifications
        case automationSpotify, automationMail, automationSystemEvents

        var id: Self { self }

        var title: String {
            switch self {
            case .microphone: "Mikrofon"
            case .accessibility: "Erişilebilirlik"
            case .screenRecording: "Ekran ve sistem sesi kaydı"
            case .calendars: "Takvim"
            case .reminders: "Anımsatıcılar"
            case .bluetooth: "Bluetooth"
            case .notifications: "Bildirimler"
            case .automationSpotify: "Otomasyon: Spotify"
            case .automationMail: "Otomasyon: Mail"
            case .automationSystemEvents: "Otomasyon: System Events"
            }
        }

        var purpose: String {
            switch self {
            case .microphone: "\"Hey Jarvis\" dinleme ve dikte"
            case .accessibility: "Kısayol tuşları, metni yapıştırma ve ekranı kaydırma"
            case .screenRecording: "Bilgisayarda çalan sesi yazıya dökme"
            case .calendars: "\"Bugün ne var?\" özetindeki etkinlikler"
            case .reminders: "Sesle hatırlatıcı ekleme ve özetteki hatırlatıcılar"
            case .bluetooth: "Bluetooth'u açma/kapatma, kulaklığı bağlama"
            case .notifications: "Günlük özet ve hatırlatıcı bildirimleri"
            case .automationSpotify: "Şarkı çalma, durdurma, arama"
            case .automationMail: "Okunmamış mailler, son maili açma"
            case .automationSystemEvents: "Karanlık modu açma/kapatma"
            }
        }

        var symbol: String {
            switch self {
            case .microphone: "mic"
            case .accessibility: "accessibility"
            case .screenRecording: "rectangle.dashed.badge.record"
            case .calendars: "calendar"
            case .reminders: "checklist"
            case .bluetooth: "dot.radiowaves.left.and.right"
            case .notifications: "bell"
            case .automationSpotify: "music.note"
            case .automationMail: "envelope"
            case .automationSystemEvents: "gearshape.2"
            }
        }

        /// System Settings › Privacy & Security page for this permission.
        var settingsURL: URL? {
            let pane = switch self {
            case .microphone: "Privacy_Microphone"
            case .accessibility: "Privacy_Accessibility"
            case .screenRecording: "Privacy_ScreenCapture"
            case .calendars: "Privacy_Calendars"
            case .reminders: "Privacy_Reminders"
            case .bluetooth: "Privacy_Bluetooth"
            case .notifications: ""
            case .automationSpotify, .automationMail, .automationSystemEvents: "Privacy_Automation"
            }
            if self == .notifications {
                return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "com.openwhisper.app")")
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        }

        var automationBundleID: String? {
            switch self {
            case .automationSpotify: "com.spotify.client"
            case .automationMail: "com.apple.mail"
            case .automationSystemEvents: "com.apple.systemevents"
            default: nil
            }
        }
    }

    private(set) var statuses: [Kind: Status] = [:]
    private(set) var requesting: Kind?
    private(set) var messages: [Kind: String] = [:]
    private var refreshVersion = 0
    private let eventStore = EKEventStore()
    private var bluetoothProbe: BluetoothProbe?

    func refresh() async {
        refreshVersion += 1
        let version = refreshVersion
        statuses[.microphone] = Self.status(AVCaptureDevice.authorizationStatus(for: .audio))
        statuses[.accessibility] = AXIsProcessTrusted() ? .granted : .needsSettings
        statuses[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .needsSettings
        statuses[.calendars] = Self.status(EKEventStore.authorizationStatus(for: .event))
        statuses[.reminders] = Self.status(EKEventStore.authorizationStatus(for: .reminder))
        statuses[.bluetooth] = Self.status(CBManager.authorization)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard version == refreshVersion else { return }
        statuses[.notifications] = switch settings.authorizationStatus {
        case .authorized, .provisional: .granted
        case .denied: .denied
        default: .notDetermined
        }
        for kind in Kind.allCases {
            guard let bundleID = kind.automationBundleID else { continue }
            let status: Status
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) == nil {
                status = .unavailable
            } else {
                status = await Self.automationStatus(bundleID, ask: false)
            }
            guard version == refreshVersion else { return }
            statuses[kind] = status
        }
        for kind in Kind.allCases where statuses[kind] == .granted {
            messages[kind] = nil
        }
    }

    /// Shows the macOS prompt when the permission was never asked; otherwise (already
    /// denied, or one macOS only grants in Settings) opens its System Settings page.
    func request(_ kind: Kind) async {
        guard requesting == nil else { return }
        requesting = kind
        messages[kind] = nil
        defer { requesting = nil }
        await refresh()
        let current = statuses[kind]
        if current == .restricted {
            messages[kind] = "Bu izin sistem politikası tarafından kısıtlanmış. Sistem yöneticinizle görüşün."
            return
        }
        if current == .granted || current == .denied {
            openSettings(kind)
            return
        }
        do {
            switch kind {
            case .microphone:
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .accessibility:
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                openSettings(kind)
            case .screenRecording:
                _ = CGRequestScreenCaptureAccess()
                openSettings(kind)
                messages[kind] = "Sistem Ayarları'nda Jarvis'i etkinleştirin. macOS isterse Jarvis'i yeniden başlatın."
            case .calendars:
                _ = try await eventStore.requestFullAccessToEvents()
            case .reminders:
                _ = try await eventStore.requestFullAccessToReminders()
            case .bluetooth:
                bluetoothProbe = BluetoothProbe()
                // Keep the manager alive and wait for authorization, not a fixed one-second delay.
                for _ in 0..<120 {
                    if CBManager.authorization != .notDetermined { break }
                    try await Task.sleep(for: .milliseconds(500))
                }
                if CBManager.authorization == .notDetermined {
                    messages[kind] = "Bluetooth izni henüz yanıtlanmadı. macOS izin penceresini kontrol edin veya Sistem Ayarları'nı açın."
                }
            case .notifications:
                _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            case .automationSpotify, .automationMail, .automationSystemEvents:
                guard let bundleID = kind.automationBundleID,
                      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                    messages[kind] = "İzin istenemedi: ilgili uygulama bu Mac'te yüklü değil."
                    return
                }
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    configuration.hides = true
                    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                }
                let result = await Self.automationStatus(bundleID, ask: true)
                if case .unknown(let reason) = result {
                    messages[kind] = "İzin istenemedi: \(reason). Uygulamayı açıp yeniden deneyin."
                } else if result == .notDetermined {
                    messages[kind] = "macOS izin isteğini tamamlamadı. İlgili uygulamayı açıp yeniden deneyin."
                }
            }
        } catch {
            messages[kind] = "İzin istenemedi: \(error.localizedDescription)"
        }
        await refresh()
        if statuses[kind] == .denied {
            messages[kind] = "İzin verilmedi. Yeniden izin vermek için Sistem Ayarları'nda Jarvis'i etkinleştirin."
        }
    }

    func actionTitle(for kind: Kind) -> String {
        if requesting == kind { return "Yanıt bekleniyor…" }
        guard let status = statuses[kind] else { return "Kontrol ediliyor…" }
        switch status {
        case .granted, .denied, .needsSettings, .restricted: return "Ayarları aç"
        case .unavailable: return "Yüklü değil"
        case .writeOnly: return "Tam erişim iste"
        case .unknown: return "Uygulamayı aç ve izin iste"
        case .notDetermined: return "İzin iste"
        }
    }

    func openSettings(_ kind: Kind) {
        guard let url = kind.settingsURL, NSWorkspace.shared.open(url) else {
            messages[kind] = "Sistem Ayarları açılamadı. Gizlilik ve Güvenlik bölümünden bu izni açın."
            return
        }
        messages[kind] = "Sistem Ayarları'nda Jarvis'in iznini kontrol edin. Durum bu sayfada otomatik güncellenir."
    }

    // MARK: - Status mapping

    static func status(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    static func status(_ status: EKAuthorizationStatus) -> Status {
        switch status {
        case .fullAccess: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .writeOnly: .writeOnly
        default: .notDetermined
        }
    }

    static func status(_ status: CBManagerAuthorization) -> Status {
        switch status {
        case .allowedAlways: .granted
        case .denied: .denied
        case .restricted: .restricted
        default: .notDetermined
        }
    }

    /// Off the main thread: the Apple Event check can block while it asks the user.
    private static func automationStatus(_ bundleID: String, ask: Bool) async -> Status {
        await Task.detached(priority: .userInitiated) {
            var target = AEAddressDesc()
            let status: OSStatus = bundleID.withCString { pointer in
                guard AECreateDesc(typeApplicationBundleID, pointer, strlen(pointer), &target) == noErr else { return OSStatus(procNotFound) }
                defer { AEDisposeDesc(&target) }
                return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
            }
            switch status {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
            case OSStatus(procNotFound): return .unknown("Uygulama kapalı")
            default: return .unknown("Bilinmiyor (\(status))")
            }
        }.value
    }
}

/// Holds a central manager just long enough for macOS to show the Bluetooth prompt.
private final class BluetoothProbe: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}
