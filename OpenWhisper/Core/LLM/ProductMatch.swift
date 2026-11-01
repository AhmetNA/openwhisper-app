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
        let regex = try! NSRegularExpression(pattern: #"(?i)(?<![a-z0-9])[a-z]{1,6}[- ]?\d{3,7}[a-z]{0,2}(?:[/_-]\d{1,4}[a-z]{0,2})?(?![a-z0-9])"#)
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
        return brand + " " + model
    }

    static func matches(product: String, title: String) -> Bool {
        if let model = modelCodes(in: product).first {
            let target = normalized(model)
            // Compare whole parsed codes, not substrings and not codes in recommendation text.
            let candidates = Set(modelCodes(in: title).map(normalized))
            let brand = product.split(separator: " ").first.map(String.init) ?? ""
            let brandMatches = !brand.allSatisfy(\.isLetter) || normalized(title).contains(normalized(brand))
            return candidates == [target] && brandMatches
        }
        // Non-coded products still need their distinctive name; ignore grammatical/catalog
        // filler and word order, but retain color, size and quantity tokens.
        let tokens = product.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { normalized(String($0)) }
            .filter { !["kadin", "erkek", "renk", "ve", "icin"].contains($0) && !$0.isEmpty }
        let candidate = normalized(title)
        return !tokens.isEmpty && tokens.allSatisfy { candidate.contains($0) }
    }
}
