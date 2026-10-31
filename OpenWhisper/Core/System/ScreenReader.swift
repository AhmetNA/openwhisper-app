import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// Reads the front window of an app over Accessibility: its visible text, for "bunu özetle"
/// outside Safari.
enum ScreenReader {
    /// Electron apps show their web content only with this set (see ClaudeSessionNavigator).
    private static let electronBundleIDs: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.codex"]

    /// Electron apps (Claude, Codex, Slack, VS Code, Discord…) build their accessibility tree
    /// only once asked through `AXManualAccessibility`; recognized by the framework they ship.
    static func isElectron(_ app: NSRunningApplication) -> Bool {
        if electronBundleIDs.contains(app.bundleIdentifier ?? "") { return true }
        guard let url = app.bundleURL else { return false }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    static func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if isElectron(app) {
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let window = element(root, kAXFocusedWindowAttribute) ?? element(root, kAXMainWindowAttribute) else { return nil }
        // A hung app must not stall the walk below its window either.
        AXUIElementSetMessagingTimeout(window, 0.5)
        return window
    }

    /// The window's title and the text it shows, in reading order, up to `limit` characters.
    static func windowText(of app: NSRunningApplication, limit: Int = 6000) -> (title: String, text: String)? {
        guard let window = focusedWindow(of: app) else { return nil }
        var parts: [String] = []
        var length = 0
        var visited = 0
        func walk(_ node: AXUIElement, depth: Int) {
            guard length < limit, visited < 4000, depth < 40 else { return }
            visited += 1
            let role = string(node, kAXRoleAttribute) ?? ""
            if ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading"].contains(role),
               let text = string(node, kAXValueAttribute) ?? string(node, kAXTitleAttribute) {
                let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !flat.isEmpty, parts.last != flat {
                    parts.append(flat)
                    length += flat.count + 1
                }
            }
            for child in children(node) { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        let text = String(parts.joined(separator: "\n").prefix(limit))
        return (string(window, kAXTitleAttribute) ?? app.localizedName ?? "Pencere", text)
    }

    /// The front window read by OCR, for apps whose accessibility tree stays empty (many
    /// Electron apps). Needs Screen Recording; nil without it or when nothing legible shows.
    static func ocrWindowText(of app: NSRunningApplication, limit: Int = 6000) async -> (title: String, text: String)? {
        let start = Date()
        guard let (lines, _, title) = await recognizeFrontWindow(of: app) else { return nil }
        let text = String(lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n").prefix(limit))
        owLog("[ScreenReader] OCR of \(app.localizedName ?? "?"): \(text.count) chars in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        guard !text.isEmpty else { return nil }
        return (title ?? app.localizedName ?? "Pencere", text)
    }

    /// A line OCR read in the front window, and where its words are on screen.
    struct ScreenText: @unchecked Sendable {
        let text: String
        fileprivate let candidate: VNRecognizedText
        fileprivate let windowFrame: CGRect

        /// `range` of `text` in screen points, top-left origin as `CGEvent` takes it.
        func frame(of range: Range<String.Index>) -> CGRect? {
            guard let box = (try? candidate.boundingBox(for: range))??.boundingBox else { return nil }
            return CGRect(x: windowFrame.minX + box.minX * windowFrame.width,
                          y: windowFrame.minY + (1 - box.maxY) * windowFrame.height,
                          width: box.width * windowFrame.width, height: box.height * windowFrame.height)
        }
    }

    /// Every line of text in the front window, read off a screenshot: what the accessibility
    /// tree doesn't show (canvases, games, many Electron views) is still on the screen.
    static func ocrTexts(of app: NSRunningApplication) async -> [ScreenText] {
        let start = Date()
        guard let (lines, frame, _) = await recognizeFrontWindow(of: app) else { return [] }
        let texts = lines.compactMap { line in
            line.topCandidates(1).first.map { ScreenText(text: $0.string, candidate: $0, windowFrame: frame) }
        }
        owLog("[ScreenReader] OCR of \(app.localizedName ?? "?"): \(texts.count) lines in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        return texts
    }

    nonisolated(unsafe) private static var askedForScreenRecording = false

    /// The front window's screenshot run through Vision: its text lines, its frame in screen
    /// points and its title.
    private static func recognizeFrontWindow(of app: NSRunningApplication) async
        -> (lines: [VNRecognizedTextObservation], frame: CGRect, title: String?)? {
        guard let (image, frame, title) = await captureFrontWindow(of: app) else { return nil }
        let lines = await Task.detached { () -> [VNRecognizedTextObservation] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["tr-TR", "en-US"]
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return request.results ?? []
        }.value
        return (lines, frame, title)
    }

    /// A screenshot of `app`'s front window, its frame in screen points and its title. Needs
    /// Screen Recording; asks for it once per launch.
    static func captureFrontWindow(of app: NSRunningApplication) async -> (image: CGImage, frame: CGRect, title: String?)? {
        guard CGPreflightScreenCaptureAccess() else {
            if !askedForScreenRecording {
                askedForScreenRecording = true
                CGRequestScreenCaptureAccess()
            }
            owLog("[ScreenReader] OCR skipped: no Screen Recording permission")
            return nil
        }
        // The CG list is front to back, so the first normal window of the app is the one in front.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let windowID = info.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                      && ($0[kCGWindowLayer as String] as? Int) == 0
              })?[kCGWindowNumber as String] as? CGWindowID,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) else { return nil }
        return (image, window.frame, window.title)
    }

    // MARK: - AX helpers

    static func children(_ node: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
