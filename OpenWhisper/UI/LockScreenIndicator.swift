import AppKit
import SwiftUI

/// Settings › Jarvis › "Kilit ekranında göster": while the Mac is locked, a small badge says
/// whether Jarvis is awake; while Jarvis listens it grows, the screen's edges darken, and a
/// white glow inside them follows your voice once speech is heard.
///
/// Ordinary windows can't appear over the lock screen, so the window is moved into a SkyLight
/// space with a high absolute level (private API, loaded at runtime; without it the window just
/// stays under the lock screen).
@MainActor
final class LockScreenIndicatorController {
    private weak var appState: AppState?
    private var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var locked = RemoteControl.screenIsLocked

    init(appState: AppState) {
        self.appState = appState
        let center = DistributedNotificationCenter.default()
        for (name, isLocked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.locked = isLocked
                    self?.sync()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToScreen() }
        })
        sync()
    }

    func sync() {
        guard let appState, appState.lockScreenIndicatorEnabled, locked else {
            window?.orderOut(nil)
            return
        }
        let window = window ?? makeWindow(appState: appState)
        fitToScreen()
        window.orderFrontRegardless()
        SkyLightSpace.shared?.add(window)
        owLog("[LockScreen] Indicator shown")
    }

    private func fitToScreen() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        window.setFrame(screen.frame, display: true)
    }

    private func makeWindow(appState: AppState) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: LockScreenIndicatorView().environment(appState))
        self.window = window
        return window
    }
}

/// A SkyLight space above the lock screen.
private final class SkyLightSpace {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    @MainActor static let shared = SkyLightSpace()

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindows

    private init?() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW),
              let mainConnection = dlsym(handle, "SLSMainConnectionID"),
              let spaceCreate = dlsym(handle, "SLSSpaceCreate"),
              let setLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSpaces = dlsym(handle, "SLSShowSpaces"),
              let addWindows = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
            owLog("[LockScreen] SkyLight unavailable; the indicator stays under the lock screen")
            return nil
        }
        connection = unsafeBitCast(mainConnection, to: MainConnection.self)()
        space = unsafeBitCast(spaceCreate, to: SpaceCreate.self)(connection, 1, 0)
        // 400: the level the notification center uses over the lock screen; 100 stayed under it.
        let levelResult = unsafeBitCast(setLevel, to: SpaceSetLevel.self)(connection, space, 400)
        let showResult = unsafeBitCast(showSpaces, to: ShowSpaces.self)(connection, [space] as CFArray)
        owLog("[LockScreen] SkyLight space \(space) (level \(levelResult), show \(showResult))")
        self.addWindows = unsafeBitCast(addWindows, to: AddWindows.self)
    }

    func add(_ window: NSWindow) {
        let result = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
        owLog("[LockScreen] Window \(window.windowNumber) moved to space \(space) (\(result))")
    }
}

struct LockScreenIndicatorView: View {
    @Environment(AppState.self) var appState

    private var listening: Bool { appState.recordingState == .recording }
    /// 0 in silence, rising to 1 as the voice gets louder.
    private var voice: Double {
        guard listening, appState.recordingHeardSpeech else { return 0 }
        return min(max((Double(appState.audioLevel) - 0.3) / 0.4, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if listening {
                    RadialGradient(colors: [.clear, .clear, .black.opacity(0.75)], center: .center,
                                   startRadius: 0, endRadius: max(geo.size.width, geo.size.height) * 0.62)
                    RoundedRectangle(cornerRadius: 60)
                        .strokeBorder(.white, lineWidth: 36)
                        .blur(radius: 45)
                        .padding(70)
                        .opacity(voice * 0.85)
                        .animation(.easeOut(duration: 0.15), value: voice)
                }
                badge
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.4)
            }
            .animation(.easeInOut(duration: 0.3), value: listening)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var badge: some View {
        if listening {
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 26, weight: .semibold))
                AudioWaveformView(level: appState.audioLevel)
                    .scaleEffect(1.6)
                    .frame(width: 100)
                Text("Dinliyor")
                    .font(.system(size: 22, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(Capsule().fill(.black.opacity(0.45)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25 + voice * 0.6), lineWidth: 1.5))
        } else {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.35)))
        }
    }

    private var statusText: String {
        if appState.recordingState == .transcribing || appState.jarvisActivity == .thinking { return "Jarvis düşünüyor" }
        if appState.jarvisActivity == .speaking { return "Jarvis konuşuyor" }
        return appState.wakeWordListening ? "Jarvis uyanık" : "Jarvis uyuyor"
    }

    private var statusColor: Color {
        if appState.recordingState != .idle || appState.jarvisActivity != .none { return .white }
        return appState.wakeWordListening ? .green : .gray
    }
}
