import Foundation

// Golden-set evaluation of LLMCleanup against REAL local Ollama models — speed and quality
// side by side. Uses the app's own prompt, glossary, learned corrections and faithfulness
// check (read-only), so the numbers match what dictation would produce.
//
//   swiftc Tools/CleanupEval/main.swift Tools/SpotifyEval/Stubs.swift \
//     OpenWhisper/Core/LLMCleanup.swift OpenWhisper/Core/GlossaryStore.swift \
//     OpenWhisper/Core/MisheardWordDetector.swift \
//     -o /tmp/cleanup_eval && /tmp/cleanup_eval [-v] model ...

/// Raw transcript → expected words after cleanup (case and punctuation are scored separately).
let golden: [(raw: String, expected: String)] = [
    // Filler removal
    ("şey yarın toplantıya gelemeyeceğim", "yarın toplantıya gelemeyeceğim"),
    ("ee bu akşam yemeğe çıkalım mı", "bu akşam yemeğe çıkalım mı"),
    ("yani ben de tam olarak anlamadım açıkçası", "ben de tam olarak anlamadım açıkçası"),
    ("ıı dosyayı hani dün gönderdiğin dosyayı açamadım", "dosyayı dün gönderdiğin dosyayı açamadım"),
    ("raporu şey cuma gününe kadar bitirmemiz lazım", "raporu cuma gününe kadar bitirmemiz lazım"),
    ("toplantı ee saat üçte başlayacak", "toplantı saat üçte başlayacak"),
    ("bu konuyu şey yani tekrar konuşalım", "bu konuyu tekrar konuşalım"),
    ("um I think we should uh deploy tomorrow", "I think we should deploy tomorrow"),
    // TR/EN code-switching: nothing may be translated
    ("şey bu pull request'i merge etmeden önce review yapalım", "bu pull request'i merge etmeden önce review yapalım"),
    ("ee frontend tarafında bir bug var galiba", "frontend tarafında bir bug var galiba"),
    ("deploy pipeline'ı yani yine fail oldu", "deploy pipeline'ı yine fail oldu"),
    ("yarın sabah standup'ta bunu konuşuruz", "yarın sabah standup'ta bunu konuşuruz"),
    ("API response'u şey biraz yavaş geliyor", "API response'u biraz yavaş geliyor"),
    // No fillers: must come back unchanged
    ("bugün hava çok güzel dışarı çıkalım", "bugün hava çok güzel dışarı çıkalım"),
    ("annemi aradım ama telefonu açmadı", "annemi aradım ama telefonu açmadı"),
    ("bu projeyi haftaya teslim etmemiz gerekiyor", "bu projeyi haftaya teslim etmemiz gerekiyor"),
    ("Can you send me the meeting notes", "Can you send me the meeting notes"),
    // "yani" / "hani" used as real words should ideally survive, but removal is tolerated
    ("kod çalışıyor ama testler geçmiyor", "kod çalışıyor ama testler geçmiyor"),
    // Longer dictation
    ("şey arkadaşlar ee bugünkü sprint planlamasında üç ana konu var birincisi login sayfası ikincisi yani ödeme ekranı üçüncüsü de bildirimler",
     "arkadaşlar bugünkü sprint planlamasında üç ana konu var birincisi login sayfası ikincisi ödeme ekranı üçüncüsü de bildirimler"),
    ("merhaba ıı dün konuştuğumuz konu hakkında şey bir güncelleme paylaşmak istiyorum müşteri yani teklifi kabul etti",
     "merhaba dün konuştuğumuz konu hakkında bir güncelleme paylaşmak istiyorum müşteri teklifi kabul etti"),
]

func words(_ s: String) -> [String] {
    s.lowercased(with: Locale(identifier: "tr_TR"))
        .split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'’")) }
        .filter { !$0.isEmpty }
}

func warmUp(_ model: String) async -> Double {
    let start = Date()
    await LLMCleanup.warmUp(model: model)
    return Date().timeIntervalSince(start)
}

let verbose = CommandLine.arguments.contains("-v")
let models = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
var summary: [String] = []

for model in models {
    print("=== \(model) ===")
    guard await LLMCleanup.isModelInstalled(model) else { print("not installed\n"); continue }
    let load = await warmUp(model)
    let cleaner = LLMCleanup(model: model)
    var correct = 0, unchanged = 0, formatted = 0
    var latencies: [Double] = []
    for (raw, expected) in golden {
        let misheard = await MainActor.run { MisheardWordDetector.find(in: raw) }
        let start = Date()
        let out = await cleaner.cleanup(text: raw, misheard: misheard)
        let t = Date().timeIntervalSince(start)
        latencies.append(t)
        let ok = words(out) == words(expected)
        // Formatting: starts with a capital and ends with punctuation.
        let fmt = (out.first?.isUppercase ?? false) && (out.last.map { ".?!".contains($0) } ?? false)
        if ok { correct += 1 }
        if fmt { formatted += 1 }
        let fellBack = out == raw && words(raw) != words(expected)
        if fellBack { unchanged += 1 }
        if !ok || verbose {
            print("\(ok ? "✓" : "✗") \(String(format: "%.2fs", t)) \(raw)\n    got: \(out)\(fellBack ? "   [rejected → raw]" : "")\n    exp: \(expected)")
        }
    }
    let sorted = latencies.sorted()
    let mean = latencies.reduce(0, +) / Double(latencies.count)
    let line = String(format: "%@ | correct %d/%d | formatted %d/%d | fell back to raw %d | load %.1fs | median %.2fs mean %.2fs max %.2fs",
                      model, correct, golden.count, formatted, golden.count, unchanged, load,
                      sorted[sorted.count / 2], mean, sorted.last!)
    print(line + "\n")
    summary.append(line)
}

print("=== SUMMARY ===")
summary.forEach { print($0) }
