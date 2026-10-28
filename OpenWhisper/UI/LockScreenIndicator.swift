import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Settings › Jarvis › "Kilit ekranında göster": while the Mac is locked, a small badge says
/// what Jarvis is doing; while Jarvis listens, your voice's waveform sits in the middle and a
/// soft white glow along the screen's edges follows it. The lock screen turns the display off
/// a few seconds after locking, so while Jarvis works on a command it is turned on and held on.
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
    private var displayAssertion: IOPMAssertionID = 0

    init(appState: AppState) {
        self.appState = appState
        let center = DistributedNotificationCenter.default()
        for (name, isLocked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.locked = isLocked
                    self?.sync()
                    self?.trackDisplayHold()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitToScreen() }
        })
        sync()
        trackDisplayHold()
    }

    /// Keeps the display on while locked and Jarvis listens, works, speaks or shows a result.
    private func trackDisplayHold() {
        let busy = withObservationTracking {
            guard let appState else { return false }
            return appState.lockScreenIndicatorEnabled
                && (appState.recordingState != .idle || appState.jarvisActivity != .none || appState.flowBarMessage != nil)
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackDisplayHold() }
        }
        holdDisplay(busy && locked)
    }

    private func holdDisplay(_ hold: Bool) {
        guard hold != (displayAssertion != 0) else { return }
        if hold {
            var id: IOPMAssertionID = 0
            guard IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Jarvis kilit ekranında çalışıyor" as CFString, &id) == kIOReturnSuccess else { return }
            displayAssertion = id
            // The assertion only keeps a lit display on; declared activity lights it if it went dark.
            var activity: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("Jarvis kilit ekranında uyandı" as CFString, kIOPMUserActiveLocal, &activity)
            owLog("[LockScreen] Holding the display on while Jarvis works")
        } else {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
            owLog("[LockScreen] Display released")
        }
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
                    Rectangle()
                        .strokeBorder(.white, lineWidth: 18)
                        .blur(radius: 28)
                        .opacity(0.12 + voice * 0.3)
                        .animation(.easeOut(duration: 0.15), value: voice)
                    VStack(spacing: 22) {
                        AudioWaveformView(level: appState.audioLevel)
                            .scaleEffect(3)
                            .frame(width: 220, height: 80)
                        caption("Dinliyor")
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                } else {
                    HStack(spacing: 16) {
                        JarvisCore(color: statusColor, active: appState.wakeWordListening || appState.recordingState != .idle
                                                                || appState.jarvisActivity != .none)
                            .frame(width: 44, height: 44)
                        caption(appState.flowBarMessage ?? statusText)
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.3)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: listening)
            .animation(.easeInOut(duration: 0.3), value: appState.flowBarMessage)
        }
        .ignoresSafeArea()
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 28, weight: .light, design: .rounded))
            .tracking(1.5)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: 700)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 8)
            .contentTransition(.opacity)
    }

    private var statusText: String {
        if appState.recordingState == .transcribing || appState.jarvisActivity == .thinking { return "Jarvis düşünüyor" }
        if appState.jarvisActivity == .speaking { return "Jarvis konuşuyor" }
        return appState.wakeWordListening ? "Jarvis uyanık" : "Jarvis uyuyor"
    }

    private var statusColor: Color {
        if appState.recordingState != .idle || appState.jarvisActivity != .none { return .white }
        return appState.wakeWordListening ? Color(red: 1, green: 0.55, blue: 0.15) : .gray
    }
}

/// A small reactor-style core: a glowing center inside two counter-rotating segmented rings.
/// Still and dim while Jarvis sleeps.
private struct JarvisCore: View {
    let color: Color
    let active: Bool
    @State private var turn = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 0.82)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [10, 5]))
                .rotationEffect(.degrees(turn ? 360 : 0))
            Circle()
                .trim(from: 0, to: 0.6)
                .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .padding(7)
                .rotationEffect(.degrees(turn ? -360 : 0))
            Circle()
                .fill(RadialGradient(colors: [.white, color, color.opacity(0)], center: .center,
                                     startRadius: 0, endRadius: 10))
                .padding(12)
                .scaleEffect(pulse ? 1.15 : 0.85)
                .animation(active ? .easeInOut(duration: 1.2).repeatForever() : .default, value: pulse)
        }
        .shadow(color: color.opacity(active ? 0.8 : 0), radius: 10)
        .opacity(active ? 1 : 0.55)
        .animation(active ? .linear(duration: 6).repeatForever(autoreverses: false) : .default, value: turn)
        .onAppear { turn = active; pulse = active }
        .onChange(of: active) { _, isActive in turn = isActive; pulse = isActive }
    }
}
