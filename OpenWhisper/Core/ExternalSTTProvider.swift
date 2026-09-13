import Foundation
import CryptoKit

/// A provider manifest describes an external local ASR runtime without adding a Swift model
/// class. Its bridge must implement:
///   --check                 -> JSON, exit 0 when the runtime/model can be prepared
///   --transcribe <wav-path> -> {"text":"..."} JSON on stdout
struct ExternalSTTProviderManifest: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let bridge: String
    let supportedLanguages: [String]
    let python: String?
}

final class ExternalSTTProvider: @unchecked Sendable {
    private struct Runtime: Sendable {
        let python: URL
        let bridge: URL
    }

    private enum ProviderError: LocalizedError {
        case runtimeNotFound
        case invalidResponse
        case processFailed(String)
        case notApproved

        var errorDescription: String? {
            switch self {
            case .runtimeNotFound:
                return "Dış STT sağlayıcısı için Python ortamı veya köprü bulunamadı."
            case .invalidResponse:
                return "Dış STT sağlayıcısı geçerli JSON sonuç döndürmedi."
            case .processFailed(let message):
                return "Dış STT sağlayıcısı başarısız oldu: \(message)"
            case .notApproved:
                return "Bu sağlayıcı kullanıcı dizininden keşfedildi ve henüz onaylanmadı. Ayarlar > Konuşma modeli bölümünden onaylayın."
            }
        }
    }

    let manifest: ExternalSTTProviderManifest
    let descriptor: TranscriptionModelDescriptor
    let trust: ProviderTrust
    private let manifestURL: URL
    private var ready = false

    init(manifest: ExternalSTTProviderManifest, manifestURL: URL, trust: ProviderTrust) {
        self.manifest = manifest
        descriptor = TranscriptionModelDescriptor(id: manifest.id, displayName: manifest.displayName)
        self.manifestURL = manifestURL
        self.trust = trust
    }

    /// Availability means the bridge and its launcher can be found. We deliberately do not run
    /// model inference here; selecting a provider performs the real --check and may download
    /// weights through the provider's own cache mechanism.
    var isAvailable: Bool { resolveRuntime() != nil }
    var isDownloaded: Bool { isAvailable }

    func loadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(0.10)
        let runtime = try resolveRuntimeOrThrow()
        progress(0.25)
        _ = try await run(arguments: ["--check"], runtime: runtime)
        ready = true
        progress(1.0)
        owLog("[STTProvider:\(manifest.id)] \(manifest.displayName) hazır")
    }

    func transcribe(audioData: [Float], language: String) async throws -> String {
        guard ready else { throw ProviderError.processFailed("model henüz yüklenmedi") }
        if !manifest.supportedLanguages.isEmpty,
           language != "auto",
           !manifest.supportedLanguages.contains(language) {
            owLog("[STTProvider:\(manifest.id)] language='\(language)' desteklenmiyor; sağlayıcının varsayılan dili kullanılacak")
        }

        let runtime = try resolveRuntimeOrThrow()
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openwhisper-stt-\(manifest.id)-\(UUID().uuidString).wav")
        try Self.writePCM16WAV(audioData, to: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let response = try await run(arguments: ["--transcribe", wavURL.path], runtime: runtime)
        guard let text = response["text"] as? String else { throw ProviderError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveRuntimeOrThrow() throws -> Runtime {
        guard let runtime = resolveRuntime() else { throw ProviderError.runtimeNotFound }
        return runtime
    }

    /// Sabit yorumlayıcı adayları: `resolveRuntime()` yalnızca bunlardan biriyle (ya da manifest'te
    /// belirtilip bu listeyle kanonik olarak eşleşen bir yolla) Process() başlatır. Liste dışı bir
    /// yorumlayıcıya izin verilmiyor çünkü alt process, OpenWhisper'ın mikrofon/Accessibility TCC
    /// izinlerini miras alıyor; manifest ise kullanıcı tarafından yazılabilir bir dizinden okunuyor.
    private func allowlistedPythonCandidates() -> [URL] {
        // sourceRoot geliştirme akışı için #filePath'ten türetiliyor, bu hesap değiştirilmedi.
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return [
            sourceRoot.appendingPathComponent(".venv/bin/python"),
            sourceRoot.appendingPathComponent(".venv/bin/python3"),
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
            URL(fileURLWithPath: "/usr/bin/python3"),
        ]
    }

    /// Karşılaştırmalar için sembolik bağları çözüp yolu standardize eder; böylece `../..` veya
    /// symlink hileleriyle allowlist/dizin kontrollerini atlatmak mümkün olmaz.
    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// manifest.bridge, manifest dosyasının bulunduğu dizinin alt ağacında kalmak zorunda. Ham
    /// string `hasPrefix` yerine yol bileşeni bazlı karşılaştırma kullanıyoruz; aksi halde
    /// `/a/foo` öneki `/a/foobar` ile yanlışlıkla eşleşebilir.
    private func resolveBridgeURL() -> URL? {
        guard !manifest.bridge.hasPrefix("/") else {
            owLog("[STTProvider:\(manifest.id)] manifest'teki bridge yolu mutlak, reddedildi: \(manifest.bridge)")
            return nil
        }

        let manifestDir = Self.canonicalURL(manifestURL.deletingLastPathComponent())
        let candidate = Self.canonicalURL(
            manifestURL.deletingLastPathComponent().appendingPathComponent(manifest.bridge)
        )

        let dirComponents = manifestDir.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > dirComponents.count,
              Array(candidateComponents.prefix(dirComponents.count)) == dirComponents else {
            owLog("[STTProvider:\(manifest.id)] manifest'teki bridge yolu manifest dizini dışına çıkıyor, reddedildi: \(manifest.bridge)")
            return nil
        }
        return candidate
    }

    private func resolveRuntime() -> Runtime? {
        let fm = FileManager.default
        guard let bridgeURL = resolveBridgeURL(), fm.isReadableFile(atPath: bridgeURL.path) else { return nil }

        let allowlist = allowlistedPythonCandidates()
        let canonicalAllowlist = Set(allowlist.map { Self.canonicalURL($0).path })

        var candidates: [URL] = []
        if let configuredPython = manifest.python, !configuredPython.isEmpty {
            let configuredURL = configuredPython.hasPrefix("/")
                ? URL(fileURLWithPath: configuredPython)
                : manifestURL.deletingLastPathComponent().appendingPathComponent(configuredPython)
            let canonicalConfigured = Self.canonicalURL(configuredURL)
            if canonicalAllowlist.contains(canonicalConfigured.path) {
                // Ham (kontrol edilmemiş) yolu değil, kanonikleştirilmiş yolu ekliyoruz: manifest
                // dizini kullanıcı tarafından yazılabilir olduğundan, doğrulama ile Process()
                // çağrısı arasında bir symlink değiştirilerek TOCTOU ile allowlist atlatılabilir.
                candidates.append(canonicalConfigured)
            } else {
                owLog("[STTProvider:\(manifest.id)] manifest'teki python yolu allowlist dışında, reddedildi: \(configuredPython)")
            }
        }

        // OPENWHISPER_STT_PYTHON / OPENWHISPER_TURKISH_STT_PYTHON allowlist dışı tutuluyor:
        // bunları ayarlamak zaten uygulamayı elle başlatmayı gerektiriyor, manifest üzerinden
        // tetiklenebilecek ek bir saldırı yüzeyi oluşturmuyor.
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["OPENWHISPER_STT_PYTHON"] ?? environment["OPENWHISPER_TURKISH_STT_PYTHON"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        candidates += allowlist
        guard let python = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) else { return nil }
        return Runtime(python: python, bridge: bridgeURL)
    }

    // MARK: - User-installed approval gate
    //
    // `.bundled` manifests ship inside the signed app bundle and are trusted like any other
    // first-party code path. `.userInstalled` manifests come from a user-writable directory, so
    // an attacker who can drop a manifest+bridge pair there could otherwise get an arbitrary
    // executable launched as a child of OpenWhisper -- inheriting its microphone/Accessibility
    // TCC grants. The gate below closes that: nothing under `.userInstalled` runs a process until
    // the user explicitly approves it in Settings, and approval is tied to the exact bytes of the
    // manifest+bridge rather than the provider id, so an approved provider whose files change
    // afterward silently loses its approval.

    private static let approvalDefaultsKey = "approvedSTTProviders"

    /// SHA256(manifest JSON'unun ham baytları || bridge script'inin ham baytları). Onay bu özete
    /// bağlanır, sağlayıcı id'sine değil -- id sabit kalsa bile manifest ya da bridge dosyası
    /// onaydan SONRA (ör. bir sonraki uygulama açılışından önce) değiştirilirse özet artık
    /// tutmaz ve onay kendiliğinden düşer. Bu, kalıcı/gecikmeli değişim senaryosunu kapatır
    /// ("bugün onayla, yarın script'in altını değiştir, bir sonraki çalıştırmada hâlâ eski
    /// script sanılsın"). Kapsam dışı: onay kontrolü ile process.run() arasındaki mikrosaniyelik
    /// pencerede aynı çağrı içinde dosyanın değiştirilmesi (TOCTOU) -- bu, dizine yazma erişimi
    /// olan bir saldırganın zaten yapabileceği daha geniş bir sınıfın parçası ve bu fonksiyonun
    /// hedefi değil.
    func computeApprovalFingerprint() -> String? {
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let bridgeURL = resolveBridgeURL(),
              let bridgeData = try? Data(contentsOf: bridgeURL) else { return nil }
        var combined = manifestData
        combined.append(bridgeData)
        let digest = SHA256.hash(data: combined)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `.bundled` sağlayıcılar için her zaman true (kapı onlara uygulanmıyor). `.userInstalled`
    /// için, saklanan parmak izi mevcut manifest+bridge içeriğiyle YENİDEN hesaplanan parmak
    /// iziyle eşleşiyorsa true.
    func isApproved() -> Bool {
        guard trust == .userInstalled else { return true }
        guard let fingerprint = computeApprovalFingerprint() else { return false }
        let approvals = UserDefaults.standard.dictionary(forKey: Self.approvalDefaultsKey) as? [String: String] ?? [:]
        return approvals[manifest.id] == fingerprint
    }

    /// Kullanıcının Ayarlar'daki açık onayını, mevcut manifest+bridge içeriğinin parmak iziyle
    /// birlikte kalıcı hale getirir.
    func approve() {
        guard let fingerprint = computeApprovalFingerprint() else { return }
        var approvals = UserDefaults.standard.dictionary(forKey: Self.approvalDefaultsKey) as? [String: String] ?? [:]
        approvals[manifest.id] = fingerprint
        UserDefaults.standard.set(approvals, forKey: Self.approvalDefaultsKey)
        owLog("[STTProvider:\(manifest.id)] kullanıcı onayı kaydedildi (fingerprint: \(fingerprint.prefix(12))…)")
    }

    /// Onayı geri alır; sağlayıcı bir sonraki çalıştırma denemesinde tekrar kapıya takılır.
    func revokeApproval() {
        var approvals = UserDefaults.standard.dictionary(forKey: Self.approvalDefaultsKey) as? [String: String] ?? [:]
        approvals.removeValue(forKey: manifest.id)
        UserDefaults.standard.set(approvals, forKey: Self.approvalDefaultsKey)
        owLog("[STTProvider:\(manifest.id)] kullanıcı onayı geri alındı")
    }

    /// Ayarlar ekranındaki onay satırında göstermek için: manifest yolu koşulsuz doludur.
    /// Yorumlayıcı ve bridge alanları yalnızca `resolveRuntime()` başarılıysa doludur -- en
    /// şüpheli manifest (containment/allowlist kontrolünü geçemeyen) de bu sayede Ayarlar'dan
    /// kaybolmaz, sadece o iki alan nil döner ve arayüz "çözümlenemedi" gösterir. Onay henüz
    /// verilmemiş olsa bile bu bilgiler elde edilebilir, çünkü kapı yalnızca
    /// `run(arguments:runtime:)` içinde uygulanıyor, `resolveRuntime()` etkilenmiyor.
    var approvalDisplayPaths: (manifestPath: String, pythonPath: String?, bridgePath: String?) {
        let runtime = resolveRuntime()
        return (manifestURL.path, runtime?.python.path, runtime?.bridge.path)
    }

    private func run(arguments: [String], runtime: Runtime) async throws -> [String: Any] {
        // Process() fiilen başlamadan ÖNCE uygulanan kapı: hem --check hem --transcribe bu tek
        // noktadan geçtiği için ikisi de kapsanıyor. `.bundled` sağlayıcılar için isApproved()
        // her zaman true döner, kapı yalnızca `.userInstalled` sağlayıcıları etkiler.
        guard isApproved() else {
            owLog("[STTProvider:\(manifest.id)] kullanıcı dizininden keşfedilen sağlayıcı onaylanmadığı için çalıştırılmadı")
            throw ProviderError.notApproved
        }

        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = runtime.python
            process.arguments = [runtime.bridge.path] + arguments
            process.standardOutput = stdout
            process.standardError = stderr
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONUNBUFFERED"] = "1"
            process.environment = environment
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                throw ProviderError.processFailed(error.localizedDescription)
            }

            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0 else {
                let detail = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "exit \(process.terminationStatus)"
                throw ProviderError.processFailed(detail)
            }
            guard let object = try JSONSerialization.jsonObject(with: output) as? [String: Any] else {
                throw ProviderError.invalidResponse
            }
            return object
        }.value
    }

    private static func writePCM16WAV(_ samples: [Float], to url: URL) throws {
        var pcm = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var value = Int16((clamped * 32767.0).rounded())
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        var header = Data()
        func appendASCII(_ value: String) { header.append(value.data(using: .ascii)!) }
        func appendUInt32LE(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
        }
        func appendUInt16LE(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { header.append(contentsOf: $0) }
        }
        appendASCII("RIFF")
        appendUInt32LE(UInt32(36 + pcm.count))
        appendASCII("WAVEfmt ")
        appendUInt32LE(16)
        appendUInt16LE(1)
        appendUInt16LE(1)
        appendUInt32LE(16_000)
        appendUInt32LE(32_000)
        appendUInt16LE(2)
        appendUInt16LE(16)
        appendASCII("data")
        appendUInt32LE(UInt32(pcm.count))
        try (header + pcm).write(to: url, options: .atomic)
    }
}

extension ExternalSTTProvider: TranscriptionModelProvider {
    func transcribe(audioData: [Float], language: String, overlapSampleCount: Int) async throws -> String {
        try await transcribe(audioData: audioData, language: language)
    }
}
