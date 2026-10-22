import AppKit
import Contacts
import Foundation

/// WhatsApp by voice, read-only: who wrote, and what. The chats come from `WhatsAppStore`;
/// the Mac's Contacts only help to find the chat a spoken name means. Nothing is sent.
enum WhatsAppController {
    /// How much of one message the flow bar shows and Jarvis says.
    private static let messageLimit = 160
    /// Chats read out for "okunmamışlar"; the rest are only counted.
    private static let unreadChatsRead = 3

    /// "WhatsApp'ta okunmamış var mı": how many people and groups wrote, then the newest
    /// unread messages of the first few chats, people before groups. Archived chats are left
    /// out, as in WhatsApp's own badge.
    static func unreadSummary() async -> String {
        await read { url in
            let unread = try WhatsAppStore.chats(at: url).filter { $0.unread > 0 && !$0.isArchived }
            guard !unread.isEmpty else { return "Okunmamış WhatsApp mesajı yok" }
            let people = unread.filter { !$0.isGroup }
            let groups = unread.filter(\.isGroup)
            var items: [String] = []
            for chat in (people + groups).prefix(unreadChatsRead) {
                let incoming = try WhatsAppStore.messages(in: chat.id, limit: 8, at: url).filter { !$0.fromMe }
                let newest = Array(incoming.prefix(min(chat.unread, 2)).reversed())
                if newest.isEmpty {
                    owLog("[WhatsApp] nothing readable in an unread chat; newest kinds: \(try WhatsAppStore.messageKinds(in: chat.id, limit: 12, at: url))")
                    items.append(spokenName(chat))
                } else {
                    items.append(line(for: chat, newest))
                }
            }
            let counts = [people.isEmpty ? nil : "\(people.count) kişiden", groups.isEmpty ? nil : "\(groups.count) gruptan"]
                .compactMap { $0 }.joined(separator: " ve ")
            return "\(counts) okunmamış mesaj — \(items.joined(separator: " · "))"
        }
    }

    /// "Ali ne yazdı": the newest messages from the chat `name` means, with when they came.
    static func latest(from name: String) async -> String {
        let contacts = await matchingContacts(name)
        return await read { url in
            guard let (chat, _) = WhatsAppStore.bestChat(for: name, in: try WhatsAppStore.chats(at: url), contacts: contacts)
            else { return "WhatsApp'ta \(name) adında sohbet bulunamadı" }
            return try latest(in: chat, at: url)
        }
    }

    /// The newest messages of these chats, one line each: after "Dilayım'dan mesaj var,
    /// okuyayım mı?" is answered yes.
    static func latest(inChats ids: [Int64]) async -> String {
        await read { url in
            let chats = try WhatsAppStore.chats(at: url)
            return try ids.compactMap { id in try chats.first { $0.id == id }.map { try latest(in: $0, at: url) } }
                .joined(separator: " · ")
        }
    }

    private static func latest(in chat: WhatsAppStore.Chat, at url: URL) throws -> String {
        let recent = try WhatsAppStore.messages(in: chat.id, limit: 12, at: url)
        guard let newestIncoming = recent.first(where: { !$0.fromMe }) else {
            owLog("[WhatsApp] no readable message from them; newest kinds: \(try WhatsAppStore.messageKinds(in: chat.id, limit: 20, at: url))")
            return "\(spokenName(chat)) sohbetinde ondan gelen mesaj yok"
        }
        // The last burst: up to three of their messages from the same hour.
        let burst = recent.filter { !$0.fromMe && newestIncoming.date.timeIntervalSince($0.date) < 3600 }
        var text = line(for: chat, Array(burst.prefix(3).reversed()), when: true)
        if recent.first?.fromMe == true { text += " · Son mesaj senden" }
        return text
    }

    /// "Ali, bugün 14:05 — selam. Akşam geliyor musun" or, in a group, "Aile — Annem: …".
    private static func line(for chat: WhatsAppStore.Chat, _ messages: [WhatsAppStore.Message], when: Bool = false) -> String {
        let body = messages.map { message -> String in
            let text = shortened(message.text)
            guard chat.isGroup, let sender = message.sender else { return text }
            return "\(sender): \(text)"
        }.joined(separator: chat.isGroup ? " · " : ". ")
        guard when, let date = messages.last?.date else { return "\(spokenName(chat)): \(body)" }
        return "\(spokenName(chat)), \(spokenTime(date)) — \(body)"
    }

    /// The chat name without emoji, which the voice would spell out ("Dilayimmm❤️❤️" → "Dilayimmm").
    static func spokenName(_ chat: WhatsAppStore.Chat) -> String {
        let kept = chat.name.unicodeScalars.filter { scalar in
            !(scalar.properties.isEmojiPresentation || scalar.properties.isEmojiModifier
              || (scalar.properties.isEmoji && scalar.value > 0x238C) || scalar.value == 0xFE0F || scalar.value == 0x200D)
        }
        let name = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? chat.name : name
    }

    private static func shortened(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return flat.count > messageLimit ? String(flat.prefix(messageLimit)) + "…" : flat
    }

    /// "bugün 14:05", "dün 21:40", "salı 09:15", "12 Ekim".
    static func spokenTime(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "bugün \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "dün \(time)"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 6 {
            formatter.dateFormat = "EEEE HH:mm"
            return formatter.string(from: date).lowercased(with: Locale(identifier: "tr_TR"))
        }
        formatter.dateFormat = "d MMMM"
        return formatter.string(from: date)
    }

    /// Runs `body` off the main thread and turns the store's failures into statuses.
    private static func read(_ body: @escaping @Sendable (URL) throws -> String) async -> String {
        let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
            Result { try body(WhatsAppStore.defaultURL) }
        }.value
        switch result {
        case .success(let status): return status
        case .failure(let error): return await status(for: error)
        }
    }

    /// What to say when the store could not be read.
    static func status(for error: Error) async -> String {
        switch error {
        case WhatsAppStore.Failure.notInstalled:
            return "Bu Mac'te WhatsApp verisi yok"
        case WhatsAppStore.Failure.noAccess:
            await openFullDiskAccessSettings()
            return "WhatsApp okunamadı: Jarvis'e Tam Disk Erişimi ver, ayarları açtım"
        default:
            owLog("[WhatsApp] read failed: \(error)")
            return "WhatsApp verisi okunamadı"
        }
    }

    @MainActor
    private static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Contacts

    /// Contacts cards whose name or nickname has every spoken word at the start of one of its
    /// words. Asks for Contacts access the first time; without it the chat names alone are used.
    static func matchingContacts(_ name: String) async -> [WhatsAppStore.Contact] {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: break
        case .notDetermined:
            guard (try? await store.requestAccess(for: .contacts)) == true else { return [] }
        default:
            return []
        }
        return await Task.detached(priority: .userInitiated) {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                        CNContactOrganizationNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let request = CNContactFetchRequest(keysToFetch: keys)
            var found: [WhatsAppStore.Contact] = []
            try? store.enumerateContacts(with: request) { contact, _ in
                let fullName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                let names = [fullName, contact.nickname, contact.organizationName].filter { !$0.isEmpty }
                guard names.contains(where: { MailController.senderMatches($0, name: name) }) else { return }
                let phones = contact.phoneNumbers.map { $0.value.stringValue.filter(\.isNumber) }
                found.append(WhatsAppStore.Contact(fullName: fullName.isEmpty ? names[0] : fullName, phones: phones))
            }
            return found
        }.value
    }
}
