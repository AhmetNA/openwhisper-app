import Foundation
import Observation

/// Optional Turkish ITN for final dictation only. Command parsers always see the ASR text.
@Observable
@MainActor
final class DamgaNormalizer {
    static let shared = DamgaNormalizer()
    nonisolated static let port = 8774
    nonisolated static let serviceID = "jarvis-damga-1.0.3"
    nonisolated static let maxCharacters = 4000

    private let server: LocalModelServer
    private var preparation: Task<Bool, Never>?
    private var ready = false
    private var generation = 0
    private(set) var status = "Kapalı"

    init(directory: URL = JarvisVoice.supportDirectory.appendingPathComponent("damga"), port: Int = DamgaNormalizer.port) {
        server = LocalModelServer(.init(port: port, directory: directory))
    }

    nonisolated static func shouldNormalize(enabled: Bool, language: String, text: String) -> Bool {
        enabled && language == "tr" && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.count <= maxCharacters
    }

    /// Coalesces startup from Settings, app launch and overlapping dictations.
    @discardableResult
    func prepare() async -> Bool {
        if ready && server.isRunning { return true }
        if let preparation { return await preparation.value }
        let current = generation
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return false }
            guard server.isInstalled else {
                status = "Kurulu değil — app/servers/damga_server/setup.sh çalıştırın."
                return false
            }
            status = "Başlatılıyor…"
            // A port occupied by another process is left alone; never send it dictation.
            let health = await server.health()
            guard !Task.isCancelled else { return false }
            if let health {
                guard case .ready(let json) = health,
                      json["service"] as? String == Self.serviceID,
                      json["parent_pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier),
                      server.isRunning else {
                    status = "Damga bağlantısı kullanılamıyor; özgün metin korunuyor."
                    return false
                }
            } else {
                guard !Task.isCancelled else { return false }
                server.forgetIfExited()
                do { _ = try server.start() }
                catch {
                    status = "Damga başlatılamadı; özgün metin korunuyor."
                    return false
                }
            }
            guard !Task.isCancelled else { return false }
            let result = await server.waitUntilReady(timeout: 3, poll: .milliseconds(50))
            guard !Task.isCancelled else { return false }
            if case .ready(let json) = result,
               json["service"] as? String == Self.serviceID,
               json["parent_pid"] as? Int == Int(ProcessInfo.processInfo.processIdentifier) {
                return true
            }
            server.stop()
            status = "Damga hazır değil; özgün metin korunuyor."
            return false
        }
        preparation = task
        let success = await task.value
        guard generation == current else { return false }
        preparation = nil
        ready = success
        if success { status = "Hazır · CPU · çevrimdışı" }
        return success
    }

    func stop() {
        generation += 1
        preparation?.cancel()
        preparation = nil
        ready = false
        server.stop()
        status = "Kapalı"
    }

    /// Bounded request, no retry on the paste path. Every failure returns the input intact.
    func normalize(_ text: String, protectedTerms: [String] = []) async -> String {
        guard Self.shouldNormalize(enabled: true, language: "tr", text: text) else { return text }
        let current = generation
        guard await prepare(), current == generation else { return text }
        var request = URLRequest(url: server.baseURL.appendingPathComponent("normalize"), timeoutInterval: 0.75)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "protected_terms": protectedTerms])
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard current == generation, !Task.isCancelled else { return text }
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let output = json["text"] as? String,
                  !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  output.count <= Self.maxCharacters * 2 else {
                status = "Damga yanıtı geçersiz; özgün metin korunuyor."
                return text
            }
            status = "Hazır · CPU · çevrimdışı"
            return output
        } catch {
            guard current == generation else { return text }
            stop()
            status = "Damga yanıt vermedi; özgün metin korunuyor."
            return text
        }
    }
}
