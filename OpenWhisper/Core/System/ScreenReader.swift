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

    /// Chromium Embedded Framework apps (Spotify) answer only `AXEnhancedUserInterface`, the
    /// flag VoiceOver sets: without it Jarvis saw 1 element in Spotify (16 nodes), with it ~900.
    static func isChromiumEmbedded(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/Frameworks/Chromium Embedded Framework.framework").path)
    }

    /// Whether the app builds its tree only when asked, and then over a second or more.
    static func buildsTreeOnRequest(_ app: NSRunningApplication) -> Bool {
        isElectron(app) || isChromiumEmbedded(app)
    }

    /// Asks an Electron or Chromium app for its accessibility tree. Done as the app comes to
    /// the front, so the tree is there by the time a command needs it (ChatGPT: 16 elements a
    /// second after the ask, 317 a few seconds later).
    static func wakeTree(of app: NSRunningApplication) {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if isElectron(app) {
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        } else if isChromiumEmbedded(app) {
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    static func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        if buildsTreeOnRequest(app) { wakeTree(of: app) }
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
        // A capture once hung 25 s over a playing video: a press waits a few seconds at most.
        let read = await JarvisContext.withTimeout(.seconds(4)) { () -> [ScreenText] in
            guard let (lines, frame, _) = await recognizeFrontWindow(of: app) else { return [] }
            return lines.compactMap { line in
                line.topCandidates(1).first.map { ScreenText(text: $0.string, candidate: $0, windowFrame: frame) }
            }
        }
        guard let texts = read else {
            owLog("[ScreenReader] OCR of \(app.localizedName ?? "?"): gave up after 4 s")
            return []
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
        // Claude keeps an invisible 32 pt strip above its window (alpha 0): OCR read 0 lines of it.
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let windowID = info.first(where: {
                  let bounds = ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
                  return ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                      && ($0[kCGWindowLayer as String] as? Int) == 0
                      && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
                      && bounds.width > 100 && bounds.height > 100
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

    /// What a walk needs of one node, read in one call: one by one it was 3–4× slower
    /// (Spotify, 2 388 nodes: 290 → 97 ms; Claude, 722: 106 → 23 ms).
    struct Node {
        let role: String
        let frame: CGRect?
        let enabled: Bool
        let children: [AXUIElement]
    }

    private static let nodeAttributes = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                         kAXEnabledAttribute, kAXChildrenAttribute] as CFArray

    static func node(_ element: AXUIElement) -> Node {
        var values: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, nodeAttributes, AXCopyMultipleAttributeOptions(), &values)
        let list = values as? [AnyObject] ?? []
        func value(_ index: Int) -> AnyObject? { index < list.count ? list[index] : nil }
        var frame: CGRect?
        if let position = value(1), let size = value(2), CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
            var origin = CGPoint.zero, extent = CGSize.zero
            if AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) {
                frame = CGRect(origin: origin, size: extent)
            }
        }
        return Node(role: value(0) as? String ?? "", frame: frame, enabled: value(3) as? Bool ?? true,
                    children: value(4) as? [AXUIElement] ?? [])
    }

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
