import AppKit

/// What screen mode draws over the screen. All rects are in AX coordinates (top-left origin).
enum ScreenOverlayContent {
    case numbers([(number: Int, frame: CGRect)], covering: CGRect)
    case grid(CGRect)
}

/// The numbers and the grid of screen mode, in a click-through panel: clicks reach the app
/// below, and screenshots for OCR and the vision model don't see it.
@MainActor
final class ScreenOverlayController {
    private lazy var panel = Self.makePanel()
    private let view = ScreenOverlayView()

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        return panel
    }

    func show(_ content: ScreenOverlayContent) {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return }
        let covering: CGRect
        switch content {
        case .numbers(_, let rect): covering = rect
        case .grid(let rect): covering = rect
        }
        if panel.contentView !== view { panel.contentView = view }
        panel.setFrame(NSRect(x: covering.minX, y: mainHeight - covering.maxY, width: covering.width, height: covering.height), display: false)
        view.origin = covering.origin
        view.content = content
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private final class ScreenOverlayView: NSView {
    var origin: CGPoint = .zero
    var content: ScreenOverlayContent?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .numbers(let items, _): drawNumbers(items)
        case .grid(let rect): drawGrid(rect)
        case nil: break
        }
    }

    private func drawNumbers(_ items: [(number: Int, frame: CGRect)]) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white,
        ]
        var taken: [CGRect] = []
        for item in items {
            let label = "\(item.number)" as NSString
            let size = label.size(withAttributes: attributes)
            let badgeSize = CGSize(width: max(size.width + 8, 20), height: size.height + 2)
            var badge = CGRect(origin: CGPoint(x: item.frame.minX - origin.x, y: item.frame.minY - origin.y), size: badgeSize)
            // Side by side when controls sit close: an overlapping number can't be read.
            var tries = 0
            while tries < 6, taken.contains(where: { $0.intersects(badge) }) {
                badge.origin.x += badgeSize.width + 1
                tries += 1
            }
            taken.append(badge)
            NSColor.black.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let outline = NSBezierPath(roundedRect: badge.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            outline.lineWidth = 1
            outline.stroke()
            label.draw(at: CGPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func drawGrid(_ rect: CGRect) {
        let area = CGRect(origin: CGPoint(x: rect.minX - origin.x, y: rect.minY - origin.y), size: rect.size)
        NSColor.black.withAlphaComponent(0.08).setFill()
        area.fill()
        for number in 1...ScreenPointer.gridColumns * ScreenPointer.gridRows {
            guard let cell = ScreenPointer.gridCell(number, in: area) else { continue }
            NSColor.black.withAlphaComponent(0.55).setStroke()
            let dark = NSBezierPath(rect: cell)
            dark.lineWidth = 2
            dark.stroke()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            let light = NSBezierPath(rect: cell)
            light.lineWidth = 1
            light.stroke()
            let fontSize = max(10, min(cell.height * 0.45, cell.width * 0.45, 30))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold), .foregroundColor: NSColor.white,
            ]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let badge = CGRect(x: cell.midX - size.width / 2 - 4, y: cell.midY - size.height / 2, width: size.width + 8, height: size.height)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            label.draw(at: CGPoint(x: badge.minX + 4, y: badge.minY), withAttributes: attributes)
        }
    }
}
