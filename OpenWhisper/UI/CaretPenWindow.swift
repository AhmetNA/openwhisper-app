import AppKit
import SwiftUI

/// The processing pen drawn next to the text caret of the field a dictation goes into, in
/// place of the flow bar. Click-through, so it never gets in the way.
@MainActor
final class CaretPenController {
    private let panel: NSPanel
    private var shownAt: CGRect?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 84, height: 26),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
    }

    /// `caret` is in AX coordinates (top-left origin of the main display). False when it is on
    /// no screen, so the flow bar can show the pen instead.
    func show(at caret: CGRect) -> Bool {
        if shownAt == caret { return true }
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return false }
        let origin = NSPoint(x: caret.minX + 6, y: mainHeight - caret.maxY + caret.height / 2 - 13)
        guard NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: caret.minX, y: mainHeight - caret.midY)) }) else {
            return false
        }
        // A new view each time, so the pen starts from the left again.
        panel.contentView = NSHostingView(rootView: CaretPenView())
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: 84, height: 26)), display: true)
        panel.orderFrontRegardless()
        shownAt = caret
        return true
    }

    func hide() {
        guard shownAt != nil else { return }
        shownAt = nil
        panel.orderOut(nil)
    }
}

/// The flow bar's pen on the same dark glass, so it shows on light pages too.
private struct CaretPenView: View {
    var body: some View {
        ProcessingWaveformView()
            .padding(.horizontal, 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 13).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 13).fill(Color.black.opacity(0.35))
                }
            )
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}
