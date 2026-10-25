import Foundation

/// The spoken recap owns its destination. Never resolve "there" against a newer history row.
enum WorkResume {
    struct Context: Sendable {
        let work: GreetingBriefing.Work?
        let summary: String
        let createdAt: Date

        func isFresh(now: Date = Date()) -> Bool {
            (0...900).contains(now.timeIntervalSince(createdAt))
        }
    }

    enum Action: Equatable { case resume, repeatSummary, cancel }

    /// Whole utterances only: appended dictation, sends and unrelated commands keep their routes.
    static func action(_ text: String) -> Action? {
        var phrase = text.lowercased(with: Locale(identifier: "tr_TR"))
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        let fillers = ["hey jarvis", "jarvis", "tamam", "peki", "evet", "hadi", "haydi", "şimdi",
                       "aa", "ha", "orası doğru", "doğru", "hatırladım", "o zaman", "lütfen"]
        var changed = true
        while changed {
            changed = false
            for filler in fillers where phrase.hasPrefix(filler + " ") {
                phrase = String(phrase.dropFirst(filler.count + 1))
                changed = true
            }
        }
        if ["boş ver", "boşver", "vazgeç", "iptal", "istemiyorum", "devam etmeyelim", "gerek yok", "hayır"].contains(phrase) {
            return .cancel
        }
        if phrase.range(of: #"^(?:(?:özeti|son çalışmayı|ne yaptığımızı) )?(?:tekrar|bir daha|yeniden) (?:anlat|özetle|söyle|hatırlat)(?:ır mısın)?$"#,
                        options: .regularExpression) != nil { return .repeatSummary }
        let destination = #"(?:(?:kaldığımız yerden|kaldığım yerden|oradan|buradan|buna|ona|bu işe|o işe|bu projeye|o projeye|bu sohbete|o sohbete) )?"#
        if phrase == "devam" || phrase.range(of: "^" + destination + #"devam (?:edelim|et|etsene|edebiliriz|edebilir miyiz)$"#,
                        options: .regularExpression) != nil { return .resume }
        if phrase.range(of: #"^(?:oraya|buraya|kaldığımız yere|kaldığım yere|o işe|bu işe|o projeye|bu projeye|o sohbete|bu sohbete) (?:(?:tekrar|yeniden|geri|bir daha) )?(?:dönelim|dön|bakalım|bak|geçelim|geç|bakabilir miyiz|dönebilir miyiz|geçebilir miyiz)$"#,
                        options: .regularExpression) != nil { return .resume }
        return nil
    }

    static func destination(_ context: Context, candidates: [CloudSessionNavigation.Candidate],
                            now: Date = Date()) -> CloudSessionNavigation.Candidate? {
        guard context.isFresh(now: now), let work = context.work, work.agent != nil,
              let id = work.sessionID else { return nil }
        return candidates.first { $0.id == id }
    }
}
