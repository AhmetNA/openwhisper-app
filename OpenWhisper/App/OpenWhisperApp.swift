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

func owLog(_ msg: String) {
    let timestamp = owLogDateFormatter.string(from: Date())
    let line = "[\(timestamp)] \(msg)\n"
    let path = "/tmp/openwhisper.log"
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
        owLog("[OpenWhisper] applicationWillTerminate called — restoring audio volume immediately")
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
