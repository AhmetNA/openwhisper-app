import Foundation
import Security

struct TargetSpeakerProfile: Codable, Equatable, Sendable {
    // Version 3 profiles also record the audio processing mode (`.off` / `.deepFilterNet` /
    // `.appleVoiceProcessing`) active during enrollment. Switching modes changes the acoustic
    // path feeding the embedding model, so a profile enrolled under one mode is not guaranteed
    // to match audio captured under another; an older profile predates this field entirely and
    // must be re-enrolled, just like the version-2 multi-condition bump before it.
    static let currentSchemaVersion = 3
    static let expectedEmbeddingDimension = 256

    /// Which Apple audio processing path was active while this profile's embeddings were
    /// captured.
    enum AudioProcessingMode: String, Codable, Sendable, Equatable {
        /// Apple Voice Processing I/O active: echo/noise suppression + AGC.
        case vpio
        /// Unprocessed microphone signal.
        case raw

        static func resolved(fromNoiseSuppressionEnabled enabled: Bool) -> AudioProcessingMode {
            enabled ? .vpio : .raw
        }

        /// True when a recording made right now (given the user's current "Gürültü engelleme"
        /// preference) would use a different processing path than this profile was captured
        /// with. Pure/testable on purpose -- see `TargetSpeakerFilterTests`.
        func differsFromActive(noiseSuppressionEnabled: Bool) -> Bool {
            self != .resolved(fromNoiseSuppressionEnabled: noiseSuppressionEnabled)
        }

        var turkishLabel: String {
            switch self {
            case .vpio: "gürültü engellemeli"
            case .raw: "gürültü engellemesiz"
            }
        }
    }

    let schemaVersion: Int
    let modelIdentifier: String
    let embeddings: [[Float]]
    let createdAt: Date
    let updatedAt: Date
    let audioProcessingMode: AudioProcessingMode

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, modelIdentifier, embeddings, createdAt, updatedAt, audioProcessingMode
    }

    init(
        modelIdentifier: String,
        embeddings: [[Float]],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        audioProcessingMode: AudioProcessingMode = .off,
        schemaVersion: Int = TargetSpeakerProfile.currentSchemaVersion
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw TargetSpeakerProfileError.schemaMismatch
        }
        guard !modelIdentifier.isEmpty, !embeddings.isEmpty,
              embeddings.allSatisfy({ $0.count == Self.expectedEmbeddingDimension }),
              embeddings.allSatisfy({ $0.allSatisfy { $0.isFinite } }) else {
            throw TargetSpeakerProfileError.invalidProfile
        }

        self.schemaVersion = schemaVersion
        self.modelIdentifier = modelIdentifier
        self.embeddings = embeddings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.audioProcessingMode = audioProcessingMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        let embeddings = try container.decode([[Float]].self, forKey: .embeddings)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        // A pre-v3 profile has no `audioProcessingMode` key at all, so this throws
        // `DecodingError.keyNotFound` for it -- caught by the store's generic decode catch
        // (never a crash) and surfaced as "yeniden kayıt gerekli", same as any other corrupt profile.
        let audioProcessingMode = try container.decode(AudioProcessingMode.self, forKey: .audioProcessingMode)
        do {
            self = try TargetSpeakerProfile(
                modelIdentifier: modelIdentifier,
                embeddings: embeddings,
                createdAt: createdAt,
                updatedAt: updatedAt,
                audioProcessingMode: audioProcessingMode,
                schemaVersion: schemaVersion
            )
        } catch let error as TargetSpeakerProfileError {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }

    func isCompatible(with modelIdentifier: String, audioProcessingMode: AudioProcessingMode) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && self.modelIdentifier == modelIdentifier
            && self.audioProcessingMode == audioProcessingMode
    }
}

enum TargetSpeakerProfileError: Error, LocalizedError, Equatable {
    case invalidProfile
    case schemaMismatch
    case keychain(OSStatus)
    case encoding

    var errorDescription: String? {
        switch self {
        case .invalidProfile: "Kayıtlı ses profili geçersiz"
        case .schemaMismatch: "Ses profili sürümü uyumsuz; yeniden kayıt gerekli"
        case .keychain(let status): "Ses profili Keychain hatası (\(status))"
        case .encoding: "Ses profili kodlanamadı"
        }
    }
}

protocol TargetSpeakerProfileStore: Sendable {
    func load() throws -> TargetSpeakerProfile?
    func save(_ profile: TargetSpeakerProfile) throws
    func delete() throws
}

final class KeychainTargetSpeakerProfileStore: TargetSpeakerProfileStore, @unchecked Sendable {
    private let service = "com.openwhisper.target-speaker"
    private let account = "default"

    func load() throws -> TargetSpeakerProfile? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            owLog("[TargetSpeaker] Keychain profile load: not found (errSecItemNotFound)")
            return nil
        }
        guard status == errSecSuccess else {
            owLog("[TargetSpeaker] Keychain profile load failed: Keychain status=\(status)")
            throw TargetSpeakerProfileError.keychain(status)
        }
        guard let data = result as? Data else {
            owLog("[TargetSpeaker] Keychain profile load failed: data encoding error")
            throw TargetSpeakerProfileError.encoding
        }

        do {
            let profile = try JSONDecoder().decode(TargetSpeakerProfile.self, from: data)
            guard profile.schemaVersion == TargetSpeakerProfile.currentSchemaVersion else {
                owLog("[TargetSpeaker] Keychain profile load failed: schema mismatch (found \(profile.schemaVersion), expected \(TargetSpeakerProfile.currentSchemaVersion))")
                throw TargetSpeakerProfileError.schemaMismatch
            }
            owLog("[TargetSpeaker] Keychain profile loaded successfully: schema=\(profile.schemaVersion), embeddings=\(profile.embeddings.count), model=\(profile.modelIdentifier)")
            return profile
        } catch let error as TargetSpeakerProfileError {
            throw error
        } catch {
            owLog("[TargetSpeaker] Keychain profile JSON decode failed: \(error)")
            throw TargetSpeakerProfileError.encoding
        }
    }

    func save(_ profile: TargetSpeakerProfile) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(profile)
        } catch {
            owLog("[TargetSpeaker] Keychain profile JSON encode failed: \(error)")
            throw TargetSpeakerProfileError.encoding
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            owLog("[TargetSpeaker] Keychain profile updated: embeddings=\(profile.embeddings.count)")
            return
        }
        guard updateStatus == errSecItemNotFound else {
            owLog("[TargetSpeaker] Keychain profile update failed: Keychain status=\(updateStatus)")
            throw TargetSpeakerProfileError.keychain(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            owLog("[TargetSpeaker] Keychain profile add failed: Keychain status=\(addStatus)")
            throw TargetSpeakerProfileError.keychain(addStatus)
        }
        owLog("[TargetSpeaker] Keychain profile created: embeddings=\(profile.embeddings.count)")
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            owLog("[TargetSpeaker] Keychain profile delete failed: Keychain status=\(status)")
            throw TargetSpeakerProfileError.keychain(status)
        }
        owLog("[TargetSpeaker] Keychain profile deleted successfully")
    }
}

final class InMemoryTargetSpeakerProfileStore: TargetSpeakerProfileStore, @unchecked Sendable {
    private let lock = NSLock()
    private var profile: TargetSpeakerProfile?

    func load() throws -> TargetSpeakerProfile? {
        lock.lock()
        defer { lock.unlock() }
        return profile
    }

    func save(_ profile: TargetSpeakerProfile) throws {
        lock.lock()
        self.profile = profile
        lock.unlock()
    }

    func delete() throws {
        lock.lock()
        profile = nil
        lock.unlock()
    }
}
