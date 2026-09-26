import SwiftUI
import UserNotifications

enum OpenWhisperNotification {
    /// Results such as "a song started" are useful briefly, but should not accumulate in
    /// Notification Center. Errors remain visible until the user clears them.
    static func post(title: String, body: String, isError: Bool, identifierPrefix: String) {
        let identifier = "\(identifierPrefix)-\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = isError ? .default : nil

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil),
            withCompletionHandler: nil
        )

        guard !isError else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            // Remove both forms in case macOS delayed delivery while the app was busy.
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        }
    }
}

private let owLogDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return df
}()

/// `swift test` logs elsewhere: its fake sessions ("test transcript", synthetic enrollments)
/// in the app's log were mistaken for real use while diagnosing wake-word failures.
private let owLogPath = NSClassFromString("XCTestCase") != nil ? "/tmp/openwhisper-tests.log" : "/tmp/openwhisper.log"

func owLog(_ msg: String) {
    VoiceEventLog.shared.appendToCurrent(msg)
    let timestamp = owLogDateFormatter.string(from: Date())
    let line = "[\(timestamp)] \(msg)\n"
    let path = owLogPath
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        if let data = line.data(using: .utf8) { fh.write(data) }
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

@main
struct OpenWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(AppState.shared)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: AppState.shared.menuBarIcon)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(AppState.shared.menuBarIconColor)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Registered via Apple Events rather than SwiftUI's onOpenURL: the app only has a
        // MenuBarExtra scene, which doesn't reliably receive URL opens.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        Task { @MainActor in AppState.shared.handleExternalURL(url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        owLog("applicationDidFinishLaunching called")
        NSApplication.shared.setActivationPolicy(.accessory)

        // Set delegate so notifications show even when app is in foreground
        UNUserNotificationCenter.current().delegate = self

        Task { @MainActor in
            owLog("Starting setup...")
            await AppState.shared.setup()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        owLog("[OpenWhisper] applicationWillTerminate called — resuming paused media")
        RecordingMediaController.shared.end()
        RecordingMediaController.shared.waitUntilIdle()
        AudioDucker.shared.restoreImmediatelyForTermination()
    }

    // Show notifications as banners even when the app is active/foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
