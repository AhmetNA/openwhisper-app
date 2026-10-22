import Foundation

/// Watches WhatsApp Desktop's database for messages from people, so Jarvis can say
/// "Dilayım'dan mesaj var, okuyayım mı?". Read-only and local like `WhatsAppStore`; groups,
/// archived chats and chats already read elsewhere are left out.
@MainActor
final class WhatsAppWatcher {
    struct Announcement: Equatable {
        /// The chats to read on a yes, newest burst first.
        let chatIDs: [Int64]
        let text: String
    }

    var onAnnounce: ((Announcement) -> Void)?

    static let pollInterval: TimeInterval = 5
    /// "Selam", "nasılsın", "akşam?" in a row are announced once, this long after the first.
    static let burstWait: TimeInterval = 4
    /// Older messages showing up now are history WhatsApp is syncing, not news.
    static let maxAge: TimeInterval = 120
    /// Chats read out at most; the rest are only counted.
    static let chatsRead = 3

    private var timer: Timer?
    private var lastSeen: Int64?
    private var collected: [WhatsAppStore.Arrival] = []
    private var firstCollectedAt: Date?
    private var polling = false

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastSeen = nil
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        owLog("[WhatsApp] watching for new messages")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        collected = []
        firstCollectedAt = nil
    }

    private func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        do {
            guard let seen = lastSeen else {
                // Only what arrives from now on is news.
                lastSeen = try await Task.detached(priority: .utility) { try WhatsAppStore.newestMessageID() }.value
                return
            }
            let new = try await Task.detached(priority: .utility) { try WhatsAppStore.arrivals(after: seen) }.value
            if let last = new.last { lastSeen = last.messageID }
            let now = Date()
            let fresh = new.filter { $0.readable && now.timeIntervalSince($0.date) < Self.maxAge }
            if !fresh.isEmpty {
                collected += fresh
                if firstCollectedAt == nil { firstCollectedAt = now }
            }
            guard let first = firstCollectedAt, now.timeIntervalSince(first) >= Self.burstWait else { return }
            let batch = collected
            collected = []
            firstCollectedAt = nil
            let chats = try await Task.detached(priority: .utility) { try WhatsAppStore.chats() }.value
            if let announcement = Self.announcement(for: batch, chats: chats) {
                owLog("[WhatsApp] new messages in \(announcement.chatIDs.count) chat(s)")
                onAnnounce?(announcement)
            }
        } catch {
            // Without Full Disk Access every poll would fail the same way.
            owLog("[WhatsApp] watching stopped: \(error)")
            stop()
        }
    }

    /// The announcement for messages that arrived together: people only, still unread, newest
    /// chat first. Nil when none of them is worth saying.
    static func announcement(for arrivals: [WhatsAppStore.Arrival], chats: [WhatsAppStore.Chat]) -> Announcement? {
        var order: [Int64] = []
        var counts: [Int64: Int] = [:]
        for arrival in arrivals.reversed() {
            if counts[arrival.chatID] == nil { order.append(arrival.chatID) }
            counts[arrival.chatID, default: 0] += 1
        }
        let people = worthSaying(order, in: chats)
        guard !people.isEmpty else { return nil }
        return Announcement(chatIDs: people.prefix(chatsRead).map(\.id),
                            text: text(for: people) { counts[$0.id] ?? 1 })
    }

    /// The chats that wrote while the screen was locked, said once it is unlocked: those still
    /// unread now, with WhatsApp's own unread count.
    static func missedAnnouncement(_ chatIDs: [Int64], chats: [WhatsAppStore.Chat]) -> Announcement? {
        let people = worthSaying(chatIDs, in: chats)
        guard !people.isEmpty else { return nil }
        return Announcement(chatIDs: people.prefix(chatsRead).map(\.id),
                            text: "Sen yokken " + text(for: people) { max($0.unread, 1) })
    }

    /// People only, not archived, still unread (a chat read on the phone is no news).
    private static func worthSaying(_ ids: [Int64], in chats: [WhatsAppStore.Chat]) -> [WhatsAppStore.Chat] {
        ids.compactMap { id in chats.first { $0.id == id } }
            .filter { !$0.isGroup && !$0.isArchived && $0.unread != 0 }
    }

    private static func text(for people: [WhatsAppStore.Chat], count: (WhatsAppStore.Chat) -> Int) -> String {
        let names = people.map(WhatsAppController.spokenName)
        switch people.count {
        case 1:
            let n = count(people[0])
            return n == 1 ? "\(ablative(names[0])) mesaj var, okuyayım mı?" : "\(ablative(names[0])) \(n) mesaj var, okuyayım mı?"
        case 2:
            return "\(names[0]) ve \(ablative(names[1])) mesaj var, okuyayım mı?"
        default:
            return "\(people.count) kişiden yeni mesaj var, okuyayım mı?"
        }
    }

    /// "Dilayım" → "Dilayım'dan", "Mehmet" → "Mehmet'ten", "Ayşe" → "Ayşe'den".
    static func ablative(_ name: String) -> String {
        let lower = name.lowercased(with: Locale(identifier: "tr_TR"))
        let back = Set("aıou"), front = Set("eiöü")
        let lastVowel = lower.last { back.contains($0) || front.contains($0) }
        let vowel = lastVowel.map { back.contains($0) } ?? false ? "a" : "e"
        let hard = lower.last.map { "çfhkpsşt".contains($0) } ?? false
        return "\(name)'\(hard ? "t" : "d")\(vowel)n"
    }
}
