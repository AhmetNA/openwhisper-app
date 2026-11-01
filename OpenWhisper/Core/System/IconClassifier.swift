import AppKit
import CoreML
import Vision

/// Icons named by what they show ("mikrofona bas", "çarpıya tıkla", "üç noktaya bas"): a small
/// model trained on Mac windows (root repo, tools/ui_harvest) says which button on screen is
/// which icon, whatever its accessibility label says (often English, often nothing).
enum IconClassifier {
    /// What the user calls an icon → the model's class. Longer phrases first: "geri sar" is
    /// previous, "geri" back; "dosya ekle" attach, "ekle" add.
    private static let spokenClasses: [(String, [String])] = [
        ("previous", ["geri sar", "önceki"]), ("next", ["ileri sar", "sonraki"]),
        ("fullscreen", ["tam ekran", "büyüt"]), ("attach", ["dosya ekle", "ataç", "ataş"]),
        ("more", ["üç nokta", "daha fazla", "seçenekler"]), ("sidebar", ["kenar çubuğu", "yan menü", "menü"]),
        ("help", ["soru işareti", "yardım"]),
        ("close", ["çarpı", "kapat"]), ("minimize", ["küçült"]), ("microphone", ["mikrofon", "sesle"]),
        ("send", ["gönder", "yolla"]), ("search", ["arama", "ara", "büyüteç"]), ("settings", ["ayar", "dişli"]),
        ("add", ["artı", "yeni", "ekle"]), ("back", ["geri"]), ("forward", ["ileri"]), ("share", ["paylaş"]),
        ("delete", ["sil", "çöp"]), ("download", ["indir"]), ("refresh", ["yenile"]), ("edit", ["düzenle", "kalem"]),
        ("play", ["oynat", "başlat"]), ("pause", ["duraklat"]), ("stop", ["durdur"]), ("info", ["bilgi"]),
        ("favorite", ["yıldız", "favori", "kalp", "beğen"]), ("notifications", ["bildirim", "zil"]),
        ("copy", ["kopyala"]), ("filter", ["filtre", "sırala"]), ("emoji", ["emoji"]), ("camera", ["kamera", "video"]),
        ("account", ["hesap", "profil"]), ("view_mode", ["görünüm", "liste", "ızgara"]), ("shuffle", ["karıştır"]),
        ("repeat", ["tekrarla"]), ("volume", ["ses"]),
    ]

    /// The icon class the request names, or nil when it names none.
    static func iconClass(for said: String) -> String? {
        let text = ScreenActions.spokenName(said)
        let words = text.replacingOccurrences(of: "'", with: " ").split(separator: " ").map(String.init)
        for (name, keys) in spokenClasses {
            for key in keys {
                if key.contains(" ") ? text.contains(key) : words.contains(where: { $0 == key || (key.count >= 3 && $0.hasPrefix(key)) }) {
                    return name
                }
            }
        }
        return nil
    }

    private static let model: VNCoreMLModel? = {
        guard let url = Bundle.module.url(forResource: "IconClassifier", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: url) else {
            owLog("[Icons] Model missing")
            return nil
        }
        return try? VNCoreMLModel(for: model)
    }()

    /// Among `frames` (screen points) in `image` (the window at `windowFrame`), the one most
    /// like `iconClass`: its index and the model's confidence. Nil when none is likely enough
    /// or two are equally likely.
    static func best(_ iconClass: String, among frames: [CGRect], in image: CGImage, windowFrame: CGRect) -> (index: Int, confidence: Float)? {
        guard let model, !frames.isEmpty else { return nil }
        let scale = CGFloat(image.width) / windowFrame.width
        var scores: [(index: Int, confidence: Float)] = []
        for (index, frame) in frames.enumerated() {
            // As in training: 3 pt around the control, letterboxed to 64×64.
            let local = frame.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY).insetBy(dx: -3, dy: -3)
            let rect = CGRect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard rect.width >= 20, rect.height >= 20, let crop = image.cropping(to: rect).flatMap(letterboxed) else { continue }
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFit
            try? VNImageRequestHandler(cgImage: crop).perform([request])
            let confidence = (request.results as? [VNClassificationObservation])?.first { $0.identifier == iconClass }?.confidence ?? 0
            scores.append((index, confidence))
        }
        let ranked = scores.sorted { $0.confidence > $1.confidence }
        guard let top = ranked.first, top.confidence >= 0.5 else { return nil }
        if ranked.count > 1, ranked[1].confidence > top.confidence - 0.1 {
            owLog(String(format: "[Icons] Two buttons look like %@ (%.2f, %.2f); none pressed", iconClass, top.confidence, ranked[1].confidence))
            return nil
        }
        return top
    }

    private static func letterboxed(_ source: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let corner = NSBitmapImageRep(cgImage: source).colorAt(x: 0, y: 0) ?? .gray
        context.setFillColor(corner.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let fit = 64 / CGFloat(max(source.width, source.height))
        let size = CGSize(width: CGFloat(source.width) * fit, height: CGFloat(source.height) * fit)
        context.draw(source, in: CGRect(x: (64 - size.width) / 2, y: (64 - size.height) / 2, width: size.width, height: size.height))
        return context.makeImage()
    }
}
