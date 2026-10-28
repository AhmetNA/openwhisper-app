import Foundation

/// Scenes: one sentence that does several things ("çalışma modu"). They live in
/// `<ApplicationSupport>/OpenWhisper/sahneler.txt`, one per line:
///
///     Çalışma modu: Safari sola; Claude sağa; Odak kısayolunu çalıştır; Spotify'da odak çal
///
/// Each step is a voice command Jarvis already knows, run in order. Read on every use, so an
/// edit counts at once.
enum SceneStore {
    struct Scene: Equatable {
        let name: String
        let steps: [String]
    }

    static var fileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("OpenWhisper/sahneler.txt")
    }

    /// Written once when the file is missing: developer mode as it used to be built in, and
    /// an example scene left as a comment.
    static let initialContents = """
        # Sahneler: "çalışma modu" deyince adımlar sırayla çalışır.
        # Her satır bir sahne. Adın ardından iki nokta, adımlar noktalı virgülle ayrılır.
        # Adımlar Jarvis'e söylediğin komutlardır. # ile başlayan satırlar okunmaz.
        # Rahatsız Etmeyin için Kısayollar'da Odak'ı açan bir kısayol yap ve adını adım olarak yaz.

        Developer modu: müziğin sesini 40 yap; ChatGPT'yi aç; beğenilen şarkıları çal; Claude Code'da yeni session aç
        # Çalışma modu: Safari sola; Claude sağa; Odak kısayolunu çalıştır; Spotify'da odak çal

        """

    static func load() -> [Scene] {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? initialContents.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [Scene] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let steps = line[line.index(after: colon)...].split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return name.isEmpty || steps.isEmpty ? nil : Scene(name: name, steps: steps)
        }
    }
}
