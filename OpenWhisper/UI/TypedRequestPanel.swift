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

    init(appState: AppState) {
        self.appState = appState
    }

    func show(prompt: String?) {
        let panel = panel ?? makePanel()
        // A fresh view each time: empty field, focus set again.
        let view = TypedRequestView(prompt: prompt) { [weak self] text in
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
        panel.hasShadow = true
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prompt {
                Text(prompt)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                TextField("Jarvis'e yaz…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}
