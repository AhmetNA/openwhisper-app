import AppKit
import SwiftUI

/// Borderless panels can't become key by default; this one needs the keyboard for its field.
/// Esc closes it.
private final class TypedRequestNSPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The "write to Jarvis" panel (⌃M): one line of text, Enter sends it to Jarvis, Esc or a
/// click elsewhere closes it. Non-activating, so the app behind it stays frontmost and a
/// "… bunu yaz" still lands in its field.
@MainActor
final class TypedRequestPanelController {
    private weak var appState: AppState?
    private var panel: TypedRequestNSPanel?
    private var resignObserver: NSObjectProtocol?
    private(set) var isShown = false
    /// Runs when the panel closes without a submit (a question left unanswered).
    private var onDismiss: (() -> Void)?

    init(appState: AppState) {
        self.appState = appState
    }

    func show(prompt: String?, onDismiss: (() -> Void)? = nil) {
        let panel = panel ?? makePanel()
        self.onDismiss = onDismiss
        // A fresh view each time: empty field, focus set again.
        let view = TypedRequestView(prompt: prompt) { [weak self] text in
            self?.onDismiss = nil
            self?.hide()
            self?.appState?.submitTypedRequest(text)
        } onCancel: { [weak self] in
            self?.hide()
        }
        let hosting = NSHostingView(rootView: view)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        position(panel)
        isShown = true
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        panel?.orderOut(nil)
        let dismissed = onDismiss
        onDismiss = nil
        dismissed?()
    }

    private func makePanel() -> TypedRequestNSPanel {
        let panel = TypedRequestNSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.hide() }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        self.panel = panel
        return panel
    }

    /// Upper third of the screen with the mouse, like Spotlight.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.68 - size.height / 2
        ))
    }
}

private struct TypedRequestView: View {
    let prompt: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    /// The logo's two ends: indigo at the top, teal at the bottom.
    private static let indigo = Color(red: 0.17, green: 0.17, blue: 0.49)
    private static let teal = Color(red: 0.08, green: 0.70, blue: 0.61)
    private static let cyan = Color(red: 0.35, green: 0.85, blue: 1.0)
    private static let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prompt {
                Text(prompt)
                    .font(.callout)
                    .foregroundStyle(Self.cyan.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
                    .shadow(color: Self.teal.opacity(0.8), radius: 8)
                TextField("", text: $text, prompt: Text("Jarvis'e yaz…").foregroundColor(.white.opacity(0.35)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .light, design: .rounded))
                    .foregroundStyle(.white)
                    .tint(Self.cyan)
                    .focused($focused)
                    .onSubmit {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSubmit(trimmed)
                    }
                    .onExitCommand(perform: onCancel)
                Image(systemName: "return")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(text.isEmpty ? .white.opacity(0.25) : Self.cyan)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    .animation(.easeOut(duration: 0.15), value: text.isEmpty)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 560, alignment: .leading)
        .background {
            ZStack {
                Self.shape.fill(.ultraThinMaterial)
                Self.shape.fill(LinearGradient(
                    colors: [Self.indigo.opacity(0.85), Color.black.opacity(0.8), Self.teal.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            }
        }
        .overlay { GlowingBorder(shape: Self.shape, colors: [Self.indigo, Self.teal, Self.cyan, Self.teal, Self.indigo]) }
        .shadow(color: Self.teal.opacity(0.35), radius: 18)
        .environment(\.colorScheme, .dark)
        // Room for the glow inside the borderless panel.
        .padding(24)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}

/// A gradient edge that slowly circles the box.
private struct GlowingBorder<S: Shape>: View {
    let shape: S
    let colors: [Color]

    var body: some View {
        TimelineView(.animation) { timeline in
            let angle = Angle.degrees(timeline.date.timeIntervalSinceReferenceDate * 60)
            let gradient = AngularGradient(colors: colors, center: .center, angle: angle)
            ZStack {
                shape.stroke(gradient, lineWidth: 1.5)
                shape.stroke(gradient, lineWidth: 4).blur(radius: 6).opacity(0.6)
            }
        }
        .allowsHitTesting(false)
    }
}
