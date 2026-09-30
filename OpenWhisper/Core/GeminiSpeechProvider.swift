import Foundation

/// Jarvis's voice from the Gemini API (Interactions endpoint, TTS models). Sends the reply text
/// to Google over the internet; the key comes from the Keychain on every request and goes only
/// in the `x-goog-api-key` header. Unary responses are already RIFF WAV (24 kHz mono 16-bit),
/// which `AVAudioPlayer` plays as is.
@MainActor
final class GeminiSpeechProvider: SpeechSynthesisProvider {
    nonisolated static let descriptor = SpeechProviderDescriptor(
        id: "gemini",
        title: "Gemini API",
        summary: "İnternete bağlanır: ses üretmek için Jarvis'in yanıt metni Google'a gönderilir. Kullanım Gemini API hesabınıza yazılır.",
        models: [
            SpeechModelOption(id: "gemini-3.8-flash-lite-tts", title: "Flash Lite",
                              detail: "Hızlı ve ucuz; kısa, gündelik cevaplar için."),
            SpeechModelOption(id: "gemini-3.8-flash-tts", title: "Flash",
                              detail: "Daha yüksek ses kalitesi ve ifade kontrolü.",
                              style: "Calm, composed and courteous, like a refined AI butler. Natural Turkish pronunciation."),
        ],
        // The prebuilt voices, Charon (deep, even) first as the default.
        voices: [
            SpeechVoiceOption(id: "Charon", trait: "Bilgilendirici"),
            SpeechVoiceOption(id: "Zephyr", trait: "Parlak"),
            SpeechVoiceOption(id: "Puck", trait: "Neşeli"),
            SpeechVoiceOption(id: "Kore", trait: "Kararlı"),
            SpeechVoiceOption(id: "Fenrir", trait: "Heyecanlı"),
            SpeechVoiceOption(id: "Leda", trait: "Genç"),
            SpeechVoiceOption(id: "Orus", trait: "Kararlı"),
            SpeechVoiceOption(id: "Aoede", trait: "Ferah"),
            SpeechVoiceOption(id: "Callirrhoe", trait: "Rahat"),
            SpeechVoiceOption(id: "Autonoe", trait: "Parlak"),
            SpeechVoiceOption(id: "Enceladus", trait: "Nefesli"),
            SpeechVoiceOption(id: "Iapetus", trait: "Net"),
            SpeechVoiceOption(id: "Umbriel", trait: "Rahat"),
            SpeechVoiceOption(id: "Algieba", trait: "Akıcı"),
            SpeechVoiceOption(id: "Despina", trait: "Akıcı"),
            SpeechVoiceOption(id: "Erinome", trait: "Net"),
            SpeechVoiceOption(id: "Algenib", trait: "Pürüzlü"),
            SpeechVoiceOption(id: "Rasalgethi", trait: "Bilgilendirici"),
            SpeechVoiceOption(id: "Laomedeia", trait: "Neşeli"),
            SpeechVoiceOption(id: "Achernar", trait: "Yumuşak"),
            SpeechVoiceOption(id: "Alnilam", trait: "Kararlı"),
            SpeechVoiceOption(id: "Schedar", trait: "Dengeli"),
            SpeechVoiceOption(id: "Gacrux", trait: "Olgun"),
            SpeechVoiceOption(id: "Pulcherrima", trait: "Atılgan"),
            SpeechVoiceOption(id: "Achird", trait: "Samimi"),
            SpeechVoiceOption(id: "Zubenelgenubi", trait: "Gündelik"),
            SpeechVoiceOption(id: "Vindemiatrix", trait: "Nazik"),
            SpeechVoiceOption(id: "Sadachbia", trait: "Canlı"),
            SpeechVoiceOption(id: "Sadaltager", trait: "Bilgili"),
            SpeechVoiceOption(id: "Sulafat", trait: "Sıcak"),
        ],
        needsAPIKey: true,
        make: { model, voice, settings in
            GeminiSpeechProvider(model: model, voice: voice?.id ?? defaultVoice,
                                 apiKey: { settings.apiKey(for: "gemini") })
        }
    )

    nonisolated static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
    nonisolated static let defaultVoice = "Charon"
    /// Network round trip plus synthesis; the music stays paused meanwhile, so keep it bounded.
    nonisolated static let timeout: TimeInterval = 15

    let model: SpeechModelOption
    /// Prebuilt voice name; part of the cache key.
    let voice: String
    private let apiKey: () -> String?
    private let session: URLSession

    init(model: SpeechModelOption, voice: String = defaultVoice, apiKey: @escaping () -> String?,
         session: URLSession = .shared) {
        self.model = model
        self.voice = voice
        self.apiKey = apiKey
        self.session = session
    }

    let displayName = "Gemini"
    let prefetchesAcks = false
    var isReady: Bool { apiKey() != nil }
    var notReadyReason: String { "Gemini API key missing" }
    var cacheIdentity: String { "gemini|\(model.id)|\(voice)|\(model.style ?? "")" }

    /// Nothing to warm up; a missing key is logged once per reply by `JarvisVoice`.
    func prepare() async {}

    func synthesize(_ text: String) async throws -> Data {
        guard let key = apiKey() else { throw SpeechSynthesisError.notReady(notReadyReason) }
        let request = Self.request(text: text, model: model, voice: voice, apiKey: key)
        Self.requestCount += 1
        let number = Self.requestCount
        // Debug trace of every call: the body carries the text, never the key (that is a header).
        owLog("[Gemini] → #\(number) POST \(Self.endpoint.path) body=\(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "-")")
        let started = Date()
        let elapsed = { "\(Int(Date().timeIntervalSince(started) * 1000)) ms" }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            owLog("[Gemini] ← #\(number) cancelled after \(elapsed())")
            throw SpeechSynthesisError.cancelled
        } catch let error as URLError {
            owLog("[Gemini] ← #\(number) URLError \(error.code.rawValue) after \(elapsed()): \(error.localizedDescription)")
            if error.code == .cancelled { throw SpeechSynthesisError.cancelled }
            throw SpeechSynthesisError.network("URLError \(error.code.rawValue)")
        } catch {
            owLog("[Gemini] ← #\(number) error after \(elapsed()): \(error)")
            throw error
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard status == 200 else {
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").map { " Retry-After=\($0)" } ?? ""
            owLog("[Gemini] ← #\(number) HTTP \(status) after \(elapsed())\(retryAfter) body=\(Self.bodyForLog(data))")
            throw SpeechSynthesisError.http(status: status, code: Self.errorCode(in: data))
        }
        do {
            let audio = try Self.audio(from: data)
            let seconds = Double(audio.count - 44) / 48_000
            owLog("[Gemini] ← #\(number) HTTP 200 after \(elapsed()), \(audio.count) bytes (~\(String(format: "%.1f", seconds)) s) body=\(Self.bodyForLog(data))")
            return audio
        } catch {
            owLog("[Gemini] ← #\(number) HTTP 200 after \(elapsed()) but unusable (\(error)) body=\(Self.bodyForLog(data))")
            throw error
        }
    }

    /// Requests made this run, so the log shows how fast the quota is being spent.
    private static var requestCount = 0

    /// The response as text for the log, with base64 audio replaced by its length.
    nonisolated static func bodyForLog(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data.prefix(2000), encoding: .utf8) ?? "<\(data.count) bytes>"
        }
        func redact(_ value: Any) -> Any {
            if let object = value as? [String: Any] {
                return object.mapValues { inner -> Any in
                    if let text = inner as? String, text.count > 500 { return "<\(text.count) chars>" }
                    return redact(inner)
                }
            }
            if let array = value as? [Any] { return array.map(redact) }
            return value
        }
        let cleaned = redact(json)
        guard let out = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: out, encoding: .utf8) else { return "<\(data.count) bytes>" }
        return text
    }

    // MARK: - Wire format (static so tests can check it without a key or network)

    nonisolated static func request(text: String, model: SpeechModelOption, voice: String = defaultVoice,
                                    apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        var textPart: [String: Any] = ["type": "text", "text": text]
        if let style = model.style {
            textPart["annotations"] = [["type": "speech_metadata", "style": style]]
        }
        let body: [String: Any] = [
            "model": model.id,
            // Don't keep the reply on Google's side for later retrieval (default is to store it).
            "store": false,
            "input": [["type": "user_input", "content": [textPart]]],
            "response_format": ["type": "audio", "mime_type": "audio/wav"],
            "generation_config": ["speech_config": [["voice": voice]]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The last audio block of the model output: base64 WAV at `steps[].content[].data`.
    nonisolated static func audio(from data: Data) throws -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SpeechSynthesisError.failed("Gemini response is not JSON")
        }
        let steps = json["steps"] as? [[String: Any]] ?? []
        let block = steps
            .filter { $0["type"] as? String == "model_output" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .last { $0["type"] as? String == "audio" }
        guard let block, let encoded = block["data"] as? String,
              let audio = Data(base64Encoded: encoded) else {
            let state = (json["status"] as? String).map { " (status \($0))" } ?? ""
            throw SpeechSynthesisError.failed("Gemini response has no audio\(state)")
        }
        let mime = block["mime_type"] as? String ?? "audio/wav"
        guard mime.hasPrefix("audio/wav") || mime == "audio/x-wav", isWAV(audio) else {
            throw SpeechSynthesisError.failed("Gemini returned \(mime), expected WAV")
        }
        return audio
    }

    nonisolated static func isWAV(_ data: Data) -> Bool {
        data.count > 44
            && data.prefix(4) == Data("RIFF".utf8)
            && data.dropFirst(8).prefix(4) == Data("WAVE".utf8)
    }

    /// Only the machine-readable error code ("PERMISSION_DENIED", "RESOURCE_EXHAUSTED"),
    /// never the message: it can quote the request.
    nonisolated static func errorCode(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let error = json["error"] as? [String: Any]
        // A bad key is a plain 400 INVALID_ARGUMENT; only the details tell it apart.
        let reasons = (error?["details"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
        if reasons.contains("API_KEY_INVALID") { return "API_KEY_INVALID" }
        let code = (error?["status"] as? String) ?? (error?["code"] as? String) ?? (json["code"] as? String)
        guard let code, code.count <= 80,
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-./:".contains($0)) })
        else { return nil }
        return code
    }
}
