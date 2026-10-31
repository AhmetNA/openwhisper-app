import AppKit
import IOKit.pwr_mgt
import SwiftUI

/// Settings › Jarvis › "Kilit ekranında göster": while the Mac is locked, a small badge says
/// what Jarvis is doing; when Jarvis wakes, two lights run along the screen's edges, and while it
/// listens the badge's core grows large and spins. The lock screen turns the display off
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
    @Namespace private var coreSpace
    @State private var wakes = 0

    private var listening: Bool { appState.recordingState == .recording }
    /// 0 in silence, rising to 1 as the voice gets louder.
    private var voice: Double {
        guard listening, appState.recordingHeardSpeech else { return 0 }
        return min(max((Double(appState.audioLevel) - 0.3) / 0.4, 0), 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.clear.keyframeAnimator(initialValue: 1.0, trigger: wakes) { _, sweep in
                    EdgeSweep(progress: sweep)
                        .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .shadow(color: .white, radius: 10)
                        .shadow(color: Color(red: 1, green: 0.55, blue: 0.15), radius: 24)
                        // Fades out over the last stretch, where the two lights meet.
                        .opacity(min(1, (1 - sweep) * 5))
                } keyframes: { _ in
                    MoveKeyframe(0)
                    CubicKeyframe(1, duration: 1.4)
                }
                if listening {
                    JarvisCore(color: Self.listeningColor, active: true, size: 110, period: 2.5)
                        .matchedGeometryEffect(id: "core", in: coreSpace)
                        .frame(width: 110, height: 110)
                        .scaleEffect(1 + voice * 0.1)
                        .shadow(color: Self.listeningColor.opacity(0.3 + voice * 0.5), radius: 12 + voice * 18)
                        .animation(.easeOut(duration: 0.15), value: voice)
                        // The middle of the lock screen belongs to other apps (Vorssaint).
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.3)
                } else {
                    VStack(spacing: 18) {
                        HStack(spacing: 18) {
                            JarvisCore(color: statusColor, active: appState.wakeWordListening || appState.recordingState != .idle
                                                                    || appState.jarvisActivity != .none)
                                .matchedGeometryEffect(id: "core", in: coreSpace)
                                .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("JARVIS")
                                    .font(.custom("Avenir Next", size: 30).weight(.ultraLight))
                                    .tracking(12)
                                    .foregroundStyle(.white)
                                Text(statusText)
                                    .font(.custom("Avenir Next", size: 12).weight(.semibold))
                                    .tracking(5)
                                    .foregroundStyle(statusColor)
                                    .contentTransition(.opacity)
                            }
                        }
                        .shadow(color: .black.opacity(0.5), radius: 8)
                        if let message = appState.flowBarMessage { caption(message) }
                    }
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.3)
                }
            }
            .animation(.spring(duration: 0.5), value: listening)
            .animation(.easeInOut(duration: 0.3), value: appState.flowBarMessage)
        }
        .ignoresSafeArea()
        .onChange(of: listening) { _, isListening in
            if isListening { wakes += 1 }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.custom("Avenir Next", size: 26).weight(.light))
            .tracking(1.5)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .frame(maxWidth: 700)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 8)
            .contentTransition(.opacity)
    }

    private var statusText: String {
        if appState.recordingState == .transcribing || appState.jarvisActivity == .thinking { return "THINKING" }
        if appState.jarvisActivity == .speaking { return "SPEAKING" }
        return appState.wakeWordListening ? "ALIVE" : "ASLEEP"
    }

    private static let listeningColor = Color(red: 0.35, green: 0.8, blue: 1)
    private static let speakingColor = Color(red: 0.72, green: 0.5, blue: 1)

    private var statusColor: Color {
        if appState.jarvisActivity == .speaking { return Self.speakingColor }
        if appState.recordingState != .idle || appState.jarvisActivity != .none { return .white }
        return appState.wakeWordListening ? Color(red: 1, green: 0.55, blue: 0.15) : .gray
    }
}

/// A reactor-style core: a glowing center inside two counter-rotating segmented rings.
/// Still and dim while Jarvis sleeps.
private struct JarvisCore: View {
    let color: Color
    let active: Bool
    var size: CGFloat = 52
    /// Seconds per turn.
    var period: Double = 6
    @State private var turn = false
    @State private var pulse = false

    var body: some View {
        let k = size / 52
        ZStack {
            Circle()
                .trim(from: 0, to: 0.82)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5 * k, lineCap: .round, dash: [10 * k, 5 * k]))
                .rotationEffect(.degrees(turn ? 360 : 0))
            Circle()
                .trim(from: 0, to: 0.6)
                .stroke(color.opacity(0.7), style: StrokeStyle(lineWidth: 1.5 * k, lineCap: .round))
                .padding(7 * k)
                .rotationEffect(.degrees(turn ? -360 : 0))
            Circle()
                .fill(RadialGradient(colors: [.white, color, color.opacity(0)], center: .center,
                                     startRadius: 0, endRadius: 10 * k))
                .padding(12 * k)
                .scaleEffect(pulse ? 1.15 : 0.85)
                .animation(active ? .easeInOut(duration: 1.2).repeatForever() : .default, value: pulse)
        }
        .shadow(color: color.opacity(active ? 0.8 : 0), radius: 10 * k)
        .opacity(active ? 1 : 0.55)
        .animation(active ? .linear(duration: period).repeatForever(autoreverses: false) : .default, value: turn)
        .onAppear { turn = active; pulse = active }
        .onChange(of: active) { _, isActive in turn = isActive; pulse = isActive }
    }
}

/// Two short lights that leave the top middle of the screen, run down either side and meet at the bottom.
private struct EdgeSweep: Shape {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var half = Path()
        half.move(to: CGPoint(x: rect.midX, y: rect.minY))
        half.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        half.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        half.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        let end = progress
        let tail = half.trimmedPath(from: max(end - 0.18, 0), to: end)
        var path = tail
        path.addPath(tail, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
        return path
    }
}
