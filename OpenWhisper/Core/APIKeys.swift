import Foundation

/// One cloud service Jarvis can use with the user's own key. Each key is a Keychain item of
/// its own; Settings › API Anahtarları lists them all, so adding a service is one entry here.
struct APIKeyProvider: Identifiable, Sendable {
    let id: String
    let title: String
    /// What Jarvis uses it for, shown under the title.
    let purpose: String
    let placeholder: String
    /// The usual start of a key; a key without it gets a warning, not a refusal.
    let expectedPrefix: String?
    let service: String
    let account: String
    /// Set when the user also gives the service's address (`CloudLLM`); else `fixedTestURL`.
    let needsAddress: Bool
    let fixedTestURL: URL?
    /// The header the key goes in; the value is "Bearer <key>" for `Authorization`.
    let keyHeader: String

    var store: KeychainSecretStore { KeychainSecretStore(service: service) }

    func key() -> String? {
        guard let key = store.read(account: account)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    var hasKey: Bool { key() != nil }

    /// False when the Keychain refused it; the caller must say so.
    @discardableResult
    func save(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        return store.write(key, account: account)
    }

    @discardableResult
    func delete() -> Bool { store.delete(account: account) }

    enum Check: Equatable {
        case ok
        /// Saved anyway; the user may know better.
        case warning(String)
        /// Not saved.
        case invalid(String)
    }

    func check(key: String) -> Check {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.contains(where: \.isWhitespace) { return .invalid("Anahtarda boşluk var; tamamını tek parça yapıştırın.") }
        if key.count < 16 { return .invalid("Anahtar çok kısa.") }
        if let expectedPrefix, !key.hasPrefix(expectedPrefix) {
            return .warning("Bu servisin anahtarları genelde \(expectedPrefix) ile başlar.")
        }
        return .ok
    }

    var testURL: URL? {
        needsAddress ? CloudLLM.address?.appendingPathComponent("models") : fixedTestURL
    }

    /// nil when the saved key works, otherwise what to tell the user. For the cloud LLM the
    /// model list it answers is kept for the model picker.
    func test() async -> String? {
        guard let key = key() else { return "Anahtar kayıtlı değil." }
        guard let url = testURL else { return "Önce servis adresini girin." }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(keyHeader == "Authorization" ? "Bearer \(key)" : key, forHTTPHeaderField: keyHeader)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            switch (response as? HTTPURLResponse)?.statusCode ?? -1 {
            case 200: break
            case 401, 403: return "Anahtar reddedildi."
            case 404: return "Adreste model listesi yok; adres genelde /v1 ile biter."
            case let status: return "Servis HTTP \(status) döndü."
            }
            guard needsAddress else { return nil }
            guard let ids = CloudChatClient.modelIDs(from: data) else { return "Servis OpenAI uyumlu cevap vermedi." }
            CloudLLM.cachedModels = ids.filter(CloudChatClient.isLikelyChatModel).sorted()
            return CloudLLM.cachedModels.isEmpty ? "Serviste sohbet modeli bulunamadı." : nil
        } catch {
            return "Servise ulaşılamadı."
        }
    }
}

enum APIKeys {
    static let cloudLLM = APIKeyProvider(
        id: "cloudLLM", title: "Bulut LLM",
        purpose: "Jarvis sohbeti. OpenAI uyumlu herhangi bir servis.",
        placeholder: "API anahtarı", expectedPrefix: nil,
        service: "com.openwhisper.app.llm", account: "cloud.api_key",
        needsAddress: true, fixedTestURL: nil, keyHeader: "Authorization")

    /// Stays where the voice settings always kept it (`SpeechSettingsStore`), so nothing moves.
    static let gemini = APIKeyProvider(
        id: "gemini", title: "Google Gemini",
        purpose: "Sesli cevap (TTS).",
        placeholder: "AIza…", expectedPrefix: "AIza",
        service: "com.openwhisper.app.tts", account: "gemini.api_key",
        needsAddress: false, fixedTestURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!,
        keyHeader: "x-goog-api-key")

    static let all = [cloudLLM, gemini]
}

/// The OpenAI-compatible service the user set up for Jarvis's chat: its address, chosen model
/// and the model list it last answered.
enum CloudLLM {
    static let addressKey = "cloudLLMAddress"
    static let modelKey = "cloudChatModel"
    static let modelsKey = "cloudChatModels"
    static let thinkingOffKey = "cloudChatThinkingOff"

    static var address: URL? {
        UserDefaults.standard.string(forKey: addressKey).flatMap { try? normalize($0).get() }
    }

    static var model: String? {
        UserDefaults.standard.string(forKey: modelKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    static var cachedModels: [String] {
        get { UserDefaults.standard.stringArray(forKey: modelsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: modelsKey) }
    }

    /// Accepted fields per server: true unless the model check found the server rejects them.
    static var thinkingOff: Bool {
        UserDefaults.standard.object(forKey: thinkingOffKey) as? Bool ?? true
    }

    /// The client Jarvis's chat should use, or nil when something is missing.
    static func client() -> (CloudChatClient, model: String)? {
        guard let address, let model, let key = APIKeys.cloudLLM.key() else { return nil }
        return (CloudChatClient(baseURL: address, apiKey: key, thinkingOff: thinkingOff), model)
    }

    /// The base URL from what the user typed: trailing "/" and a pasted "/chat/completions" go;
    /// https only, except on this Mac.
    static func normalize(_ text: String) -> Result<URL, AddressError> {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["/chat/completions", "/models"] where text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased() else { return .failure(.notAURL) }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && local) else { return .failure(.notHTTPS) }
        return .success(url)
    }

    enum AddressError: Error, Equatable {
        case notAURL, notHTTPS

        var message: String {
            switch self {
            case .notAURL: "Geçerli bir adres değil (örnek: https://api.ornek.com/v1)."
            case .notHTTPS: "Adres https:// ile başlamalı."
            }
        }
    }
}

/// Which model answers Jarvis's free conversation. Ollama stays the fallback either way.
enum ChatBackend: String, CaseIterable, Identifiable {
    case cloud, ollama

    var id: Self { self }
    var title: String {
        switch self {
        case .cloud: "Bulut"
        case .ollama: "Yerel (Ollama)"
        }
    }

    static let defaultsKey = "jarvisChatBackend"

    static var selected: ChatBackend {
        ChatBackend(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .cloud
    }
}
