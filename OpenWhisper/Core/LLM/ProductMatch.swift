import Foundation

/// Merchant titles contain marketing copy; the manufacturer's full model code is the
/// useful identity. Keep suffixes: EP5543/80 and EP5543/90 must never be merged.
enum ProductMatch {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    static func modelCodes(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"(?i)(?<![a-z0-9])[a-z]{1,6}-?\d{2,7}[a-z]{0,2}(?:[/_-]\d{1,4}[a-z]{0,2})?(?![a-z0-9])"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func primaryPageModel(in lines: [String]) -> String? {
        // Query/tracking IDs and marketplace catalog IDs are not manufacturer models.
        let text = lines.first { $0.hasPrefix("Safari sekmesi:") } ?? ""
        guard let range = text.range(of: #"https?://[^\s]+"#, options: .regularExpression),
              let url = URL(string: String(text[range])) else { return nil }
        let slug = url.path.components(separatedBy: "-p-")[0]
        return modelCodes(in: slug).first
    }

    static func searchName(_ product: String) -> String {
        guard let model = modelCodes(in: product).first else { return product }
        let brand = product.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map(String.init) ?? ""
        if normalized(model).count <= 4 {
            return product.replacingOccurrences(of: "™", with: "").split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { !filler.contains(normalized(String($0))) }.joined(separator: " ")
        }
        return brand + " " + model
    }

    private static let filler: Set<String> = ["kablosuz", "sarjli", "dikey", "supurge", "supurgesi", "sari", "nikel", "gri", "tm"]
    private static func words(_ text: String) -> Set<String> {
        Set(text.replacingOccurrences(of: "™", with: "").split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { normalized(String($0)) })
    }
    private static func isAccessory(_ text: String) -> Bool {
        words(text).contains { word in ["yedek", "filtr", "filter", "boru", "baslik", "batarya", "uyumlu", "hepa", "aksesuar"].contains(where: word.hasPrefix) }
    }

    /// Discovery can open an unnamed-code candidate; every merchant is checked again below.
    static func candidateMatches(product: String, title: String) -> Bool {
        if matches(product: product, title: title) { return true }
        guard modelCodes(in: title).isEmpty, !isAccessory(title) else { return false }
        let codes = Set(modelCodes(in: product).map(normalized))
        let required = words(product).subtracting(codes).subtracting(["siyah", "beyaz", "renk", "kadin", "erkek"])
        return required.count >= 3 && required.isSubset(of: words(title))
    }

    static func matches(product: String, title: String) -> Bool {
        guard !words(title).contains(where: { $0.hasPrefix("karsilastir") || $0 == "vs" }) else { return false }
        if let model = modelCodes(in: product).first {
            let target = normalized(model)
            // Compare whole parsed codes, not substrings and not codes in recommendation text.
            let candidates = Set(modelCodes(in: title).map(normalized))
            let brand = product.split(separator: " ").first.map(String.init) ?? ""
            let brandMatches = !brand.allSatisfy(\.isLetter) || normalized(title).contains(normalized(brand))
            guard candidates == [target] && brandMatches else { return false }
            if target.count <= 4 {
                let variants: Set<String> = ["plus", "pro", "max", "extra", "fluffy", "motorhead"]
                guard words(product).intersection(variants) == words(title).intersection(variants) else { return false }
                let required = words(product).subtracting(filler).subtracting([normalized(brand), target])
                return required.isSubset(of: words(title).subtracting(filler)) && !isAccessory(title)
            }
            return !isAccessory(title) || isAccessory(product)
        }
        // Non-coded products still need their distinctive name; ignore grammatical/catalog
        // filler and word order, but retain color, size and quantity tokens.
        let tokens = product.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { normalized(String($0)) }
            .filter { !["kadin", "erkek", "renk", "ve", "icin"].contains($0) && !$0.isEmpty }
        let candidate = normalized(title)
        return !tokens.isEmpty && tokens.allSatisfy { candidate.contains($0) }
    }
}
