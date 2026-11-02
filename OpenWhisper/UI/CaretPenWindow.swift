import AppKit
import SwiftUI

/// The processing pen drawn next to the text caret of the field a dictation goes into, in
/// place of the flow bar. Click-through, so it never gets in the way.
@MainActor
final class CaretPenController {
    private let panel: NSPanel
    private var shownAt: CGRect?
    private var shownWidth: CGFloat?
    /// The glass's edge left of the pen: little, as it overlaps the text before the caret.
    static let leading: CGFloat = 3

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

    /// Short recordings stay compact; 14 seconds or more reaches the 320-point cap.
    static func width(for duration: TimeInterval) -> CGFloat {
        let progress = min(1, max(0, (duration - 2) / 12))
        return round(79 + 241 * progress)
    }

    /// Shared by listening and processing, so the handoff keeps its height.
    static func height(for caret: CGRect) -> CGFloat {
        min(32, max(28, caret.height + 2))
    }

    /// `caret` uses AX coordinates (top-left origin). Fall back to the flow bar off-screen.
    func show(at caret: CGRect, duration: TimeInterval, field: CGRect?) -> Bool {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return false }
        let height = Self.height(for: caret)
        // The pen's first point lands on the caret's middle.
        var origin = NSPoint(x: caret.minX - Self.leading - ProcessingWaveformView.startX,
                             y: mainHeight - caret.maxY + caret.height / 2 - height / 2)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: caret.minX, y: mainHeight - caret.midY)) }) else {
            return false
        }
        var bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        if let field, field.insetBy(dx: -1, dy: -1).contains(CGPoint(x: caret.minX, y: caret.midY)) {
            let visibleField = CGRect(x: field.minX, y: mainHeight - field.maxY,
                                      width: field.width, height: field.height).intersection(bounds)
            if visibleField.width >= 40, visibleField.height >= 18 {
                // A one-line field is shorter than the pen: stay inside it sideways only.
                bounds = visibleField.height >= height
                    ? visibleField.insetBy(dx: 2, dy: 0)
                    : CGRect(x: visibleField.minX + 2, y: bounds.minY, width: visibleField.width - 4, height: bounds.height)
            }
        }
        let fittedHeight = min(height, bounds.height)
        let width = min(Self.width(for: duration), bounds.width)
        // Only the screen limits the left edge: at a field's start the glass must still cover the caret.
        let leftLimit = screen.visibleFrame.minX + 8
        origin.x = max(leftLimit, min(origin.x, bounds.maxX - width))
        origin.y = min(max(origin.y, bounds.minY), bounds.maxY - fittedHeight)
        let frame = NSRect(origin: origin, size: NSSize(width: width, height: fittedHeight))
        if shownAt == caret, shownWidth == width, panel.frame == frame { return true }
        let view = CaretPenView(width: width - Self.leading - 8, height: fittedHeight)
        if shownAt == caret, let hosting = panel.contentView as? NSHostingView<CaretPenView> {
            hosting.rootView = view
        } else {
            panel.contentView = NSHostingView(rootView: view)
        }
        panel.setFrame(frame, display: true)
        shownWidth = width
        panel.orderFrontRegardless()
        shownAt = caret
        return true
    }

    func hide() {
        guard shownAt != nil else { return }
        shownAt = nil
        shownWidth = nil
        panel.orderOut(nil)
    }
}

/// The flow bar's pen on the same dark glass, so it shows on light pages too.
private struct CaretPenView: View {
    var width: CGFloat
    var height: CGFloat
    var body: some View {
        ProcessingWaveformView(width: width, height: height)
            .padding(.leading, CaretPenController.leading)
            .padding(.trailing, 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: height / 2).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: height / 2).fill(Color.black.opacity(0.35))
                }
            )
            .overlay(RoundedRectangle(cornerRadius: height / 2).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: height / 2))
    }
}
