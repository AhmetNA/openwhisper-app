import AppKit
import ApplicationServices

/// Moves and sizes app windows through Accessibility: halves of the screen, the whole screen,
/// macOS full screen and the next display. "Safari sola" launches Safari first when needed.
@MainActor
enum WindowManager {
    static func perform(_ action: WindowAction) async -> String {
        guard AXIsProcessTrusted() else { return "Pencereleri taşımak için Erişilebilirlik izni gerekli" }
        guard let app = await targetApp(action.app) else { return "\(action.app ?? "Öndeki uygulama") bulunamadı" }
        let name = app.localizedName ?? action.app ?? "Pencere"
        guard let window = await mainWindow(of: app) else { return "\(name) penceresi bulunamadı" }
        let done: Bool
        // "Tam ekran yap" a second time leaves it, as YouTube's "f" does.
        let leavesFullscreen = action.position == .fullscreen && bool(window, "AXFullScreen")
        switch action.position {
        case .fullscreen:
            done = AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, leavesFullscreen ? kCFBooleanFalse : kCFBooleanTrue) == .success
        case .left, .right, .maximize, .nextScreen:
            // Out of full screen first, or the frame can't change.
            if bool(window, "AXFullScreen") {
                AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
                try? await Task.sleep(for: .milliseconds(800))
            }
            guard let frame = target(for: action.position, from: frame(of: window)) else {
                return "Başka bir ekran yok"
            }
            done = setFrame(window, frame)
        }
        app.activate()
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        owLog("[Window] \(name) → \(action.position.rawValue): \(done ? "done" : "failed")")
        guard done else { return "\(name) penceresi taşınamadı" }
        switch action.position {
        case .left: return "\(name) solda"
        case .right: return "\(name) sağda"
        case .maximize: return "\(name) ekranı kaplıyor"
        case .fullscreen: return leavesFullscreen ? "\(name) tam ekrandan çıktı" : "\(name) tam ekran"
        case .nextScreen: return "\(name) diğer ekranda"
        }
    }

    /// The named app, launched if it isn't running; otherwise the frontmost one.
    private static func targetApp(_ name: String?) async -> NSRunningApplication? {
        guard let name else { return NSWorkspace.shared.frontmostApplication }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
            ?? ["/Applications", "/System/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
                .map { URL(fileURLWithPath: $0).appendingPathComponent(name + ".app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        if let bundleID = url.flatMap({ Bundle(url: $0)?.bundleIdentifier }),
           let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return running
        }
        guard let url else { return nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Waits up to 5 s for a window: a cold launch takes a moment to show one.
    private static func mainWindow(of app: NSRunningApplication) async -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for _ in 0..<25 {
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value {
                    return (value as! AXUIElement)
                }
            }
            var windows: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
               let first = (windows as? [AXUIElement])?.first {
                return first
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    /// In Accessibility coordinates: origin at the top left of the main display, y down.
    private static func frame(of window: AXUIElement) -> CGRect {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        var position = CGPoint.zero
        var size = CGSize.zero
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success, let positionRef {
            AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        }
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success, let sizeRef {
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: position, size: size)
    }

    private static func setFrame(_ window: AXUIElement, _ frame: CGRect) -> Bool {
        var position = frame.origin
        var size = frame.size
        guard let positionValue = AXValueCreate(.cgPoint, &position), let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        // Position, size, then position again: a window too big for its new place is clamped
        // by the size step and only lands right on the second move.
        let moved = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success
        let sized = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        return moved || sized
    }

    /// The frame for `position` on the display that holds most of `current`.
    private static func target(for position: WindowAction.Position, from current: CGRect) -> CGRect? {
        let screens = NSScreen.screens
        guard let main = screens.first else { return nil }
        // NSScreen frames have their origin at the bottom left; flip them into AX space.
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: main.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        let index = screens.indices.max {
            flipped(screens[$0].frame).intersection(current).area < flipped(screens[$1].frame).intersection(current).area
        } ?? 0
        let visible = flipped(screens[index].visibleFrame)
        switch position {
        case .left: return CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height)
        case .right: return CGRect(x: visible.midX, y: visible.minY, width: visible.width / 2, height: visible.height)
        case .maximize, .fullscreen: return visible
        case .nextScreen:
            guard screens.count > 1 else { return nil }
            let next = flipped(screens[(index + 1) % screens.count].visibleFrame)
            // Same place and size relative to the display, scaled to the new one.
            let sx = next.width / visible.width, sy = next.height / visible.height
            return CGRect(x: next.minX + (current.minX - visible.minX) * sx, y: next.minY + (current.minY - visible.minY) * sy,
                          width: min(current.width * sx, next.width), height: min(current.height * sy, next.height))
        }
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
