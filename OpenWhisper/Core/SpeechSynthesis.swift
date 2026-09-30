import Foundation
import Security

/// Turns a finished Jarvis reply into WAV audio. `JarvisVoice` owns everything around it —
/// playback, stop/interrupt, the disk cache and the Turkish number spelling — so a provider
/// only knows how to reach its engine. Providers are listed in `SpeechProviders.all`; adding
/// one (or a model) means adding a descriptor there, not touching Settings or `JarvisVoice`.
@MainActor
protocol SpeechSynthesisProvider: AnyObject {
    /// Shown in logs, e.g. "OmniVoice", "Gemini".
    var displayName: String { get }
    /// Everything that changes how a phrase sounds (provider, model, voice, style). Part of the
    /// cache key, so clips from different providers/models never replace each other.
    var cacheIdentity: String { get }
    /// Whether `synthesize` can be called now (server warm, API key present).
    var isReady: Bool { get }
    /// Why it isn't ready, for the log. Never contains secrets.
    var notReadyReason: String { get }
    /// Fill the cache with the acks once ready. Off for paid APIs: it would spend ~30 requests.
    var prefetchesAcks: Bool { get }
    /// Gets ready if it can (starts a local server, …). Safe to call repeatedly.
    func prepare() async
    /// Another provider took over: free what this one holds (the local server's RAM).
    func suspend()
    /// Returns playable WAV data for `text` (already in spoken form). Must honour task
    /// cancellation. Errors must not contain the text or any credential.
    func synthesize(_ text: String) async throws -> Data
}

extension SpeechSynthesisProvider {
    func suspend() {}
}

enum SpeechSynthesisError: Error, Equatable, CustomStringConvertible {
    case notReady(String)
    case cancelled
    /// The service answered with an error. `code` is its machine-readable code
    /// ("PERMISSION_DENIED"), never its message, which can quote the request.
    case http(status: Int, code: String?)
    /// Couldn't reach the service at all.
    case network(String)
    /// A safe, short summary — never the reply text or a key.
    case failed(String)

    var description: String {
        switch self {
        case .notReady(let reason): "not ready: \(reason)"
        case .cancelled: "cancelled"
        case .http(let status, let code): "HTTP \(status)\(code.map { " \($0)" } ?? "")"
        case .network(let summary): "network: \(summary)"
        case .failed(let summary): summary
        }
    }

    /// Short Turkish text for Settings.
    var userMessage: String {
        switch self {
        case .notReady: "API anahtarı yok."
        case .cancelled: "İptal edildi."
        case .http(let status, let code):
            switch status {
            case _ where code == "API_KEY_INVALID", 401, 403:
                "Anahtar geçersiz ya da bu API için yetkisiz (HTTP \(status))."
            case 404: "Model bulunamadı (HTTP 404)."
            case 429: "Kota ya da hız sınırı doldu (HTTP 429)."
            default: "Servis hata verdi (HTTP \(status)\(code.map { ", \($0)" } ?? ""))."
            }
        case .network: "Bağlantı kurulamadı. İnternet bağlantısını kontrol edin."
        case .failed: "Beklenmeyen yanıt geldi."
        }
    }
}

// MARK: - Registry

struct SpeechModelOption: Hashable, Identifiable {
    let id: String
    let title: String
    /// One line under the model picker.
    let detail: String
    /// Delivery instruction sent next to (never inside) the text, where the model supports it.
    var style: String? = nil
}

struct SpeechVoiceOption: Hashable, Identifiable {
    let id: String
    /// Character of the voice, e.g. "Bilgilendirici".
    let trait: String
}

struct SpeechProviderDescriptor: Identifiable {
    let id: String
    let title: String
    /// Settings text under the picker: where the audio is made and what leaves the Mac.
    let summary: String
    /// First is the default.
    let models: [SpeechModelOption]
    /// Selectable voices, first is the default. Empty when the voice is fixed (local clone).
    var voices: [SpeechVoiceOption] = []
    let needsAPIKey: Bool
    let make: @MainActor (SpeechModelOption, SpeechVoiceOption?, SpeechSettingsStore) -> SpeechSynthesisProvider

    var defaultModel: SpeechModelOption { models[0] }

    /// Unknown ids (a model that was removed) fall back to the default.
    func model(id: String?) -> SpeechModelOption {
        models.first { $0.id == id } ?? defaultModel
    }

    /// Unknown ids fall back to the default; nil when the provider has no voice choice.
    func voice(id: String?) -> SpeechVoiceOption? {
        voices.first { $0.id == id } ?? voices.first
    }
}

enum SpeechProviders {
    static let defaultID = LocalOmniVoiceProvider.descriptor.id

    static let all: [SpeechProviderDescriptor] = [
        LocalOmniVoiceProvider.descriptor,
        GeminiSpeechProvider.descriptor,
    ]

    /// Unknown ids fall back to the local provider.
    static func descriptor(for id: String?) -> SpeechProviderDescriptor {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID }!
    }
}

// MARK: - Settings

/// Where the chosen provider/model (UserDefaults) and API keys (Keychain) live.
struct SpeechSettingsStore {
    static let providerKey = "voiceReplyProvider"
    static func modelKey(for provider: String) -> String { "voiceReplyModel.\(provider)" }
    static func voiceKey(for provider: String) -> String { "voiceReplyVoice.\(provider)" }

    let defaults: UserDefaults
    let secrets: SecretStore

    static let standard = SpeechSettingsStore(
        defaults: .standard,
        secrets: KeychainSecretStore(service: "com.openwhisper.app.tts")
    )

    var providerID: String {
        get { SpeechProviders.descriptor(for: defaults.string(forKey: Self.providerKey)).id }
        nonmutating set { defaults.set(SpeechProviders.descriptor(for: newValue).id, forKey: Self.providerKey) }
    }

    func modelID(for provider: String) -> String {
        SpeechProviders.descriptor(for: provider).model(id: defaults.string(forKey: Self.modelKey(for: provider))).id
    }

    func setModelID(_ model: String, for provider: String) {
        let descriptor = SpeechProviders.descriptor(for: provider)
        defaults.set(descriptor.model(id: model).id, forKey: Self.modelKey(for: descriptor.id))
    }

    /// "" when the provider has no voice choice.
    func voiceID(for provider: String) -> String {
        SpeechProviders.descriptor(for: provider).voice(id: defaults.string(forKey: Self.voiceKey(for: provider)))?.id ?? ""
    }

    func setVoiceID(_ voice: String, for provider: String) {
        let descriptor = SpeechProviders.descriptor(for: provider)
        guard let option = descriptor.voice(id: voice) else { return }
        defaults.set(option.id, forKey: Self.voiceKey(for: descriptor.id))
    }

    /// The provider Jarvis should speak with right now.
    @MainActor
    func makeProvider() -> SpeechSynthesisProvider {
        let descriptor = SpeechProviders.descriptor(for: providerID)
        return descriptor.make(descriptor.model(id: modelID(for: descriptor.id)),
                               descriptor.voice(id: voiceID(for: descriptor.id)), self)
    }

    func apiKey(for provider: String) -> String? {
        guard let key = secrets.read(account: "\(provider).api_key")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
    }

    func hasAPIKey(for provider: String) -> Bool { apiKey(for: provider) != nil }

    /// False when the Keychain refused it; the caller must say so.
    @discardableResult
    func saveAPIKey(_ key: String, for provider: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        return secrets.write(key, account: "\(provider).api_key")
    }

    @discardableResult
    func deleteAPIKey(for provider: String) -> Bool {
        secrets.delete(account: "\(provider).api_key")
    }
}

protocol SecretStore {
    func read(account: String) -> String?
    func write(_ value: String, account: String) -> Bool
    func delete(account: String) -> Bool
}

/// Generic-password items in the login Keychain, same scheme as `SpotifyCredentialsStore`.
struct KeychainSecretStore: SecretStore {
    let service: String

    func read(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
