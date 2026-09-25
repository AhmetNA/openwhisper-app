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
        /// Automation target that isn't running, so macOS can't answer yet.
        case unknown(String)

        var label: String {
            switch self {
            case .granted: "Verildi"
            case .denied: "Reddedildi"
            case .notDetermined: "Henüz sorulmadı"
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
            case .accessibility: "Kısayol tuşları ve metni yapıştırma"
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
    private let eventStore = EKEventStore()
    private var bluetoothProbe: BluetoothProbe?

    func refresh() async {
        statuses[.microphone] = Self.status(AVCaptureDevice.authorizationStatus(for: .audio))
        statuses[.accessibility] = AXIsProcessTrusted() ? .granted : .notDetermined
        statuses[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        statuses[.calendars] = Self.status(EKEventStore.authorizationStatus(for: .event))
        statuses[.reminders] = Self.status(EKEventStore.authorizationStatus(for: .reminder))
        statuses[.bluetooth] = Self.status(CBManager.authorization)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        statuses[.notifications] = switch settings.authorizationStatus {
        case .authorized, .provisional: .granted
        case .denied: .denied
        default: .notDetermined
        }
        for kind in Kind.allCases {
            guard let bundleID = kind.automationBundleID else { continue }
            statuses[kind] = await Self.automationStatus(bundleID, ask: false)
        }
    }

    /// Shows the macOS prompt when the permission was never asked; otherwise (already
    /// denied, or one macOS only grants in Settings) opens its System Settings page.
    func request(_ kind: Kind) async {
        switch kind {
        case .microphone:
            if statuses[kind] == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) } else { openSettings(kind) }
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { openSettings(kind) }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { openSettings(kind) }
        case .calendars:
            if statuses[kind] == .notDetermined { _ = try? await eventStore.requestFullAccessToEvents() } else { openSettings(kind) }
        case .reminders:
            if statuses[kind] == .notDetermined { _ = try? await eventStore.requestFullAccessToReminders() } else { openSettings(kind) }
        case .bluetooth:
            if statuses[kind] == .notDetermined {
                // Creating a central manager is what shows the Bluetooth prompt.
                bluetoothProbe = BluetoothProbe()
                try? await Task.sleep(for: .seconds(1))
            } else {
                openSettings(kind)
            }
        case .notifications:
            if statuses[kind] == .notDetermined {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            } else {
                openSettings(kind)
            }
        case .automationSpotify, .automationMail, .automationSystemEvents:
            guard let bundleID = kind.automationBundleID else { return }
            if case .denied = statuses[kind] { openSettings(kind); break }
            // macOS only asks while the target app runs; launch it hidden first.
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
               NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.hides = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                try? await Task.sleep(for: .seconds(1.5))
            }
            _ = await Self.automationStatus(bundleID, ask: true)
        }
        await refresh()
    }

    func openSettings(_ kind: Kind) {
        if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
    }

    // MARK: - Status mapping

    private static func status(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    private static func status(_ status: EKAuthorizationStatus) -> Status {
        switch status {
        case .fullAccess: .granted
        case .denied, .restricted, .writeOnly: .denied
        default: .notDetermined
        }
    }

    private static func status(_ status: CBManagerAuthorization) -> Status {
        switch status {
        case .allowedAlways: .granted
        case .denied, .restricted: .denied
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
            case OSStatus(procNotFound): return .unknown("Uygulama kapalı — sormak için İzin iste")
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
