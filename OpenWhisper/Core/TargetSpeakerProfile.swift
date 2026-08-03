import Foundation
import Security

struct TargetSpeakerProfile: Codable, Equatable, Sendable {
    // Version 3 adds `audioProcessingMode`: Apple's Voice Processing I/O (echo/noise
    // suppression + AGC, toggled by the "Gürültü engelleme" setting) measurably changes the
    // signal's spectral character, so an embedding captured with it on is not directly
    // comparable to one captured with it off. Recording which mode produced a profile lets the
    // app warn the user (and offer a fix) instead of silently degrading match accuracy -- see
    // `AppState`'s audio-processing-mode-mismatch handling.
    //
    // Version 2 profiles (enrolled from multiple speaking conditions) predate VPIO entirely --
    // every one of them was necessarily captured with processing off. `init(from:)` migrates
    // them forward on load by assuming `.raw` rather than forcing re-enrollment (see there).
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
    /// True only for the single in-memory instance produced by migrating a legacy schema-2
    /// profile during `init(from:)`. Deliberately NOT persisted (excluded from `CodingKeys`/
    /// `encode(to:)`): it exists only so the caller that just loaded the profile can show a
    /// one-time "your old profile was assumed raw-mode" notice and then resave, after which the
    /// stored JSON is genuinely schema 3 and this flag reads false again on the next load.
    let migratedFromLegacySchema: Bool

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, modelIdentifier, embeddings, createdAt, updatedAt, audioProcessingMode
    }

    init(
        modelIdentifier: String,
        embeddings: [[Float]],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        schemaVersion: Int = TargetSpeakerProfile.currentSchemaVersion,
        audioProcessingMode: AudioProcessingMode = .vpio
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
        self.migratedFromLegacySchema = false
    }

    /// Internal, non-throwing constructor for the schema-2 -> schema-3 migration path in
    /// `init(from:)`: the embeddings/model-identifier were already validated by the caller, so
    /// this skips re-running the public initializer's checks (which would also reject
    /// `schemaVersion: 2` outright).
    private init(
        migratedToCurrentSchemaFrom modelIdentifier: String,
        embeddings: [[Float]],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.modelIdentifier = modelIdentifier
        self.embeddings = embeddings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.audioProcessingMode = .raw
        self.migratedFromLegacySchema = true
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        let embeddings = try container.decode([[Float]].self, forKey: .embeddings)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        if storedSchemaVersion == 2 {
            guard !modelIdentifier.isEmpty, !embeddings.isEmpty,
                  embeddings.allSatisfy({ $0.count == Self.expectedEmbeddingDimension }),
                  embeddings.allSatisfy({ $0.allSatisfy { $0.isFinite } }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .schemaVersion,
                    in: container,
                    debugDescription: TargetSpeakerProfileError.invalidProfile.localizedDescription
                )
            }
            self = TargetSpeakerProfile(
                migratedToCurrentSchemaFrom: modelIdentifier,
                embeddings: embeddings,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
            return
        }

        // Schema 3 (or later, which will also fail the throwing init's version check below):
        // the mode field is mandatory. A blob claiming schema 3 without it is corrupt, not a
        // migration case -- decode it strictly rather than guessing a default.
        let audioProcessingMode = try container.decode(AudioProcessingMode.self, forKey: .audioProcessingMode)
        do {
            self = try TargetSpeakerProfile(
                modelIdentifier: modelIdentifier,
                embeddings: embeddings,
                createdAt: createdAt,
                updatedAt: updatedAt,
                schemaVersion: storedSchemaVersion,
                audioProcessingMode: audioProcessingMode
            )
        } catch let error as TargetSpeakerProfileError {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: error.localizedDescription
            )
        }
    }

    /// Explicit -- not auto-synthesizable once `migratedFromLegacySchema` exists without a
    /// matching `CodingKeys` case. Persists exactly the schema-3 fields; the transient migration
    /// flag never round-trips, by design (see its doc comment).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(modelIdentifier, forKey: .modelIdentifier)
        try container.encode(embeddings, forKey: .embeddings)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(audioProcessingMode, forKey: .audioProcessingMode)
    }

    /// Explicit (not synthesized) so `migratedFromLegacySchema` -- a transient, non-persisted
    /// load-time flag -- never causes two profiles with identical stored data to compare
    /// unequal.
    static func == (lhs: TargetSpeakerProfile, rhs: TargetSpeakerProfile) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.modelIdentifier == rhs.modelIdentifier
            && lhs.embeddings == rhs.embeddings
            && lhs.createdAt == rhs.createdAt
            && lhs.updatedAt == rhs.updatedAt
            && lhs.audioProcessingMode == rhs.audioProcessingMode
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
