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

    /// The lock screen core's listening blue: the core, the accent line and the caret.
    private static let accent = Color(red: 0.3, green: 0.75, blue: 1)
    private static let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let prompt {
                Text(prompt)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                JarvisCore(color: Self.accent, active: true, size: 26, period: 4)
                    .frame(width: 26, height: 26)
                TextField("", text: $text, prompt: Text("Jarvis'e yaz…").foregroundColor(.white.opacity(0.3)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.92))
                    .tint(Self.accent)
                    .focused($focused)
                    .onSubmit {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        onSubmit(trimmed)
                    }
                    .onExitCommand(perform: onCancel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 560, alignment: .leading)
        .background {
            ZStack {
                Self.shape.fill(.ultraThinMaterial)
                Self.shape.fill(Color(white: 0.05).opacity(0.85))
            }
        }
        .overlay { Self.shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
        .overlay(alignment: .bottom) { accentLine }
        .clipShape(Self.shape)
        .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
        .environment(\.colorScheme, .dark)
        // Room for the shadow inside the borderless panel.
        .padding(24)
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }

    /// A thin accent line along the bottom edge that fades out at both ends.
    private var accentLine: some View {
        let gradient = LinearGradient(colors: [.clear, Self.accent, .clear], startPoint: .leading, endPoint: .trailing)
        return ZStack {
            Rectangle().fill(gradient).frame(height: 1)
            Rectangle().fill(gradient).frame(height: 3).blur(radius: 3).opacity(0.6)
        }
        .padding(.horizontal, 40)
        .allowsHitTesting(false)
    }
}
