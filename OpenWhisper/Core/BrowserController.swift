import AppKit
import Foundation

/// Safari by voice. Tabs go through Safari's own AppleScript so nothing is typed into
/// whatever app happens to be in front; only back / forward use a keystroke, and only while
/// Safari is already the frontmost app. Main actor: NSAppleScript is main-thread only.
@MainActor
enum BrowserController {
    static let bundleID = "com.apple.Safari"

    /// Fixed statuses, so `JarvisReply` can tell a failed summary from a summary.
    nonisolated static let noPage = "Safari'de açık sayfa yok"
    nonisolated static let unreadable = "Sayfa okunamadı"
    nonisolated static let summaryFailed = "Sayfa özetlenemedi"
    nonisolated static let notFront = "Safari önde olmadığı için yapamadım"
    nonisolated static let failures: Set<String> = [noPage, unreadable, summaryFailed, notFront, "Safari'ye ulaşılamadı", "Adres açılamadı"]

    static func perform(_ action: BrowserAction) async -> String {
        switch action {
        case .newTab:
            return run("""
                tell application "Safari"
                    activate
                    if (count of windows) = 0 then
                        make new document
                    else
                        tell front window to set current tab to (make new tab)
                    end if
                end tell
                """, done: "Yeni sekme açıldı")
        case .closeTab:
            // Closing a tab in a Safari window hidden behind Chrome would be a surprise.
            guard isFront else { return notFront }
            guard hasWindow() else { return noPage }
            return run(#"tell application "Safari" to close current tab of front window"#, done: "Sekme kapatıldı")
        case .reload:
            guard hasWindow() else { return noPage }
            return run("""
                tell application "Safari"
                    set current to current tab of front window
                    set URL of current to (URL of current)
                end tell
                """, done: "Sayfa yenilendi")
        case .nextTab, .previousTab:
            guard hasWindow() else { return noPage }
            let step = action == .nextTab ? "(i mod n) + 1" : "((i - 2 + n) mod n) + 1"
            return run("""
                tell application "Safari"
                    tell front window
                        set n to count of tabs
                        set i to index of current tab
                        set current tab to tab (\(step))
                    end tell
                end tell
                """, done: action == .nextTab ? "Sonraki sekme" : "Önceki sekme")
        case .back, .forward:
            // No AppleScript verb for history; ⌘[ / ⌘] would hit another app if Safari isn't in front.
            guard isFront else { return notFront }
            let key = action == .back ? "[" : "]"
            return run(#"tell application "System Events" to keystroke "\#(key)" using command down"#,
                       done: action == .back ? "Geri gidildi" : "İleri gidildi")
        case .open(let address):
            guard let url = URL(string: address) else { return "Adres açılamadı" }
            return await open(url, done: "\(url.host ?? address) açıldı")
        case .search(let engine, let query):
            guard let url = searchURL(engine, query) else { return "Adres açılamadı" }
            return await open(url, done: "\(engine == .youtube ? "YouTube" : "Google")'da aranıyor: \(query)")
        case .summarize:
            return await summarizeCurrentPage()
        }
    }

    /// `.urlQueryAllowed` leaves "&", "+" and "=" in, which would split the query.
    nonisolated static func searchURL(_ engine: BrowserAction.Engine, _ query: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        switch engine {
        case .google: return URL(string: "https://www.google.com/search?q=\(encoded)")
        case .youtube: return URL(string: "https://www.youtube.com/results?search_query=\(encoded)")
        }
    }

    // MARK: - Summary

    /// Page text sent to the model; longer pages are cut so the prompt fits the default context
    /// (no `num_ctx`: a different one would make Ollama reload the model cleanup also uses).
    static let maxPageCharacters = 5000

    private static func summarizeCurrentPage() async -> String {
        guard hasWindow() else { return noPage }
        guard let page = currentPage() else { return unreadable }
        let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 80 else { return unreadable }
        owLog("[Browser] Summarizing '\(page.title)' (\(text.count) chars)")
        guard let summary = await ollamaSummary(title: page.title, text: String(text.prefix(maxPageCharacters))) else {
            return summaryFailed
        }
        OpenWhisperNotification.post(title: "Özet — \(page.title)", body: summary, isError: false, identifierPrefix: "page-summary")
        return summary
    }

    private static func currentPage() -> (title: String, text: String)? {
        var error: NSDictionary?
        let script = NSAppleScript(source: """
            tell application "Safari"
                set t to current tab of front window
                return {name of t, text of t}
            end tell
            """)
        guard let result = script?.executeAndReturnError(&error), error == nil, result.numberOfItems == 2 else {
            owLog("[Browser] Could not read the page: \(error ?? [:])")
            return nil
        }
        return (result.atIndex(1)?.stringValue ?? "Sayfa", result.atIndex(2)?.stringValue ?? "")
    }

    private static func ollamaSummary(title: String, text: String) async -> String? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }
        let prompt = """
            Aşağıda bir web sayfasının metni var. Sayfanın ne anlattığını Türkçe, en fazla 3 kısa \
            cümleyle özetle. Sadece özeti yaz; giriş cümlesi, başlık, madde işareti kullanma.

            Sayfa başlığı: \(title)
            Sayfa metni:
            \(text)
            """
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        let body: [String: Any] = [
            "model": UserDefaults.standard.string(forKey: "ollamaModel") ?? LLMCleanup.defaultModel,
            "prompt": prompt,
            "stream": false,
            "think": false,
            "keep_alive": LLMCleanup.keepAlive,
            "options": ["temperature": 0.2, "num_predict": 220],
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reply = json["response"] as? String else {
                owLog("[Browser] Ollama summary HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let summary = reply
                .replacingOccurrences(of: #"(?s)<think>.*?</think>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            owLog("[Browser] Summary in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(summary)")
            return summary.isEmpty ? nil : summary
        } catch {
            owLog("[Browser] Ollama summary failed: \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    private static func open(_ url: URL, done: String) async -> String {
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return "Safari'ye ulaşılamadı"
        }
        do {
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: safari, configuration: .init())
            owLog("[Browser] Opened \(url.absoluteString)")
            return done
        } catch {
            owLog("[Browser] Open failed: \(error)")
            return "Adres açılamadı"
        }
    }

    private static var isFront: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    private static func hasWindow() -> Bool {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil else { return false }
        var error: NSDictionary?
        let count = NSAppleScript(source: #"tell application "Safari" to count of windows"#)?
            .executeAndReturnError(&error).int32Value ?? 0
        return error == nil && count > 0
    }

    private static func run(_ source: String, done: String) -> String {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            owLog("[Browser] AppleScript failed: \(error)")
            return "Safari'ye ulaşılamadı"
        }
        owLog("[Browser] \(done)")
        return done
    }
}
