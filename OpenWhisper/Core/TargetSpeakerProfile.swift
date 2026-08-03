import Foundation
import Security

struct TargetSpeakerProfile: Codable, Equatable, Sendable {
    // Version 2 profiles are enrolled from multiple speaking conditions (for example
    // sitting and lying down), so an older one-condition profile must be re-enrolled.
    static let currentSchemaVersion = 2
    static let expectedEmbeddingDimension = 256

    let schemaVersion: Int
    let modelIdentifier: String
    let embeddings: [[Float]]
    let createdAt: Date
    let updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, modelIdentifier, embeddings, createdAt, updatedAt
    }

    init(
        modelIdentifier: String,
        embeddings: [[Float]],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
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
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        let embeddings = try container.decode([[Float]].self, forKey: .embeddings)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        do {
            self = try TargetSpeakerProfile(
                modelIdentifier: modelIdentifier,
                embeddings: embeddings,
                createdAt: createdAt,
                updatedAt: updatedAt,
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

    func isCompatible(with modelIdentifier: String) -> Bool {
        schemaVersion == Self.currentSchemaVersion && self.modelIdentifier == modelIdentifier
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
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TargetSpeakerProfileError.keychain(status) }
        guard let data = result as? Data else { throw TargetSpeakerProfileError.encoding }

        do {
            let profile = try JSONDecoder().decode(TargetSpeakerProfile.self, from: data)
            guard profile.schemaVersion == TargetSpeakerProfile.currentSchemaVersion else {
                throw TargetSpeakerProfileError.schemaMismatch
            }
            return profile
        } catch let error as TargetSpeakerProfileError {
            throw error
        } catch {
            throw TargetSpeakerProfileError.encoding
        }
    }

    func save(_ profile: TargetSpeakerProfile) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(profile)
        } catch {
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
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw TargetSpeakerProfileError.keychain(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw TargetSpeakerProfileError.keychain(addStatus) }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TargetSpeakerProfileError.keychain(status)
        }
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
