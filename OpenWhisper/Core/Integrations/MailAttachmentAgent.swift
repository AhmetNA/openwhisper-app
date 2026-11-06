import AppKit
import Foundation

/// "Mustafa'ya gönderdiğim eki bul": the cloud model searches the sent mail with tools, picks
/// the attachment the user means and opens it. A few steps at most; the model only sees the
/// recipients, subjects and attachment names of the sent mail it searched for.
enum MailAttachmentAgent {
    static let maxSteps = 4

    static let searchTool = "search_sent_mail"
    static let openTool = "open_attachment"

    static let tools: [[String: Any]] = [
        ["type": "function", "function": [
            "name": searchTool,
            "description": "Gönderilen mailler arasında, alıcısının adı ya da adresi kişiye uyan ekli mailleri en yeniden eskiye listeler.",
            "parameters": [
                "type": "object",
                "properties": ["person": ["type": "string", "description": "Alıcının adı ya da soyadı, eksiz yalın hali (\"Ayşe'ye\" → \"Ayşe\")."]],
                "required": ["person"],
            ] as [String: Any],
        ] as [String: Any]],
        ["type": "function", "function": [
            "name": openTool,
            "description": "Bir gönderilen mailin ekini İndirilenler'e kaydedip açar.",
            "parameters": [
                "type": "object",
                "properties": [
                    "message_id": ["type": "integer", "description": "search_sent_mail sonucundaki id."],
                    "attachment": ["type": "string", "description": "Ekin adı, listedeki gibi."],
                ],
                "required": ["message_id", "attachment"],
            ] as [String: Any],
        ] as [String: Any]],
    ]

    static func systemPrompt(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy EEEE"
        return """
        Kullanıcı mailde birine gönderdiği bir eki istiyor. Araçlarla bul ve aç.
        - Önce search_sent_mail ile kişiyi ara. Ad yanlış duyulmuş olabilir; sonuç yoksa bir kez benzer bir yazımla ya da yalnız soyadıyla dene.
        - Kullanıcı dosya türü, adı, konu ya da zaman söylediyse ona uyanı seç; söylemediyse en yeni maildeki asıl dosyayı seç. \
        image.png, imza logoları ve uzun rastgele adlı resimler genelde mail içi görsellerdir, asıl ek değildir.
        - Seçtiğin eki open_attachment ile aç. Emin olamıyorsan da en olası olanı aç.
        - Bulamadıysan bunu tek kısa Türkçe cümleyle söyle. Markdown kullanma.
        Bugün: \(formatter.string(from: now)).
        """
    }

    /// What the tools found and did during one request.
    struct State {
        var found: [Int: MailController.SentWithAttachments] = [:]
        /// Set once an attachment is open; the request ends there.
        var answer: String?
    }

    /// The sentence Jarvis says.
    static func run(_ request: String) async -> String {
        guard let (client, model) = CloudLLM.client() else {
            return L("Ekleri bulmak için Ayarlar'da Bulut LLM gerekiyor", "Finding attachments needs the cloud LLM in Settings")
        }
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt(now: Date())],
            ["role": "user", "content": request],
        ]
        var state = State()
        for step in 1...maxSteps {
            var body = CloudChatClient.completionBody(model: model, messages: messages, maxTokens: 300, thinkingOff: client.thinkingOff)
            if step < maxSteps { body["tools"] = tools }
            let message: [String: Any]
            do {
                message = try await complete(client, body: body)
            } catch {
                owLog("[MailAgent] Step \(step) failed: \(ChatFallback.describe(error))")
                return L("Eki şu an arayamadım", "Couldn't search for the attachment right now")
            }
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            guard !calls.isEmpty else {
                let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                owLog("[MailAgent] Done in \(step) steps without opening: '\(text)'")
                return text.isEmpty ? L("Eki bulamadım", "Couldn't find the attachment") : text
            }
            messages.append(["role": "assistant", "content": message["content"] as? String ?? "", "tool_calls": calls])
            for call in calls {
                let function = call["function"] as? [String: Any]
                let name = function?["name"] as? String ?? ""
                let arguments = (function?["arguments"] as? String).flatMap {
                    try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                } ?? [:]
                let result = await perform(name, arguments: arguments, state: &state)
                owLog("[MailAgent] \(name) \(arguments) → \(result.prefix(300))")
                // Once it is open there is nothing left to decide; a last model turn only to
                // word the answer took ~5 s.
                if let answer = state.answer {
                    owLog("[MailAgent] Done in \(step) steps")
                    return answer
                }
                messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": result])
            }
        }
        return L("Eki bulamadım", "Couldn't find the attachment")
    }

    private static func perform(_ tool: String, arguments: [String: Any], state: inout State) async -> String {
        switch tool {
        case searchTool:
            let person = (arguments["person"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !person.isEmpty else { return "Kişi adı boş." }
            guard let found = await MailController.sentWithAttachments(to: person) else {
                return "Mail'e erişilemedi."
            }
            for mail in found { state.found[mail.id] = mail }
            return describe(found, person: person)
        case openTool:
            let id = (arguments["message_id"] as? Int) ?? Int(arguments["message_id"] as? String ?? "")
            let attachment = arguments["attachment"] as? String ?? ""
            guard let id, !attachment.isEmpty else { return "message_id ve attachment gerekli." }
            guard let url = await MailController.saveSentAttachment(messageID: id, name: attachment) else {
                return "Bu ek kaydedilemedi; id ve adı listedeki gibi mi?"
            }
            let didOpen = await MainActor.run { NSWorkspace.shared.open(url) }
            guard didOpen else { return "\(url.lastPathComponent) İndirilenler'e kaydedildi ama açılamadı." }
            state.answer = openedAnswer(file: attachment, mail: state.found[id])
            return "Açıldı: \(url.path)"
        default:
            return "Böyle bir araç yok."
        }
    }

    static func openedAnswer(file: String, mail: MailController.SentWithAttachments?) -> String {
        // Said without the extension, as `openFile` does.
        let file = (file as NSString).deletingPathExtension
        guard let mail else { return L("\(file) açıldı", "Opened \(file)") }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: CommandLanguage.isEnglish ? "en_US" : "tr_TR")
        formatter.dateFormat = "d MMMM"
        let first = mail.recipients.components(separatedBy: "; ").first ?? mail.recipients
        let name = MailController.displayName(first)
        return L("\(file) açıldı; \(formatter.string(from: mail.date)) günü gönderilmiş, alıcı \(name)",
                 "Opened \(file), sent to \(name) on \(formatter.string(from: mail.date))")
    }

    static func describe(_ found: [MailController.SentWithAttachments], person: String) -> String {
        guard !found.isEmpty else { return "\(person) adına uyan alıcıya gönderilmiş ekli mail yok." }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateFormat = "d MMMM yyyy HH:mm"
        return found.prefix(10).map { mail in
            "id \(mail.id) · \(formatter.string(from: mail.date)) · alıcı: \(mail.recipients) · konu: \(mail.subject) · ekler: \(mail.attachments.joined(separator: ", "))"
        }.joined(separator: "\n")
    }

    /// One whole answer: its text and tool calls.
    private static func complete(_ client: CloudChatClient, body: [String: Any]) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: client.request(path: "chat/completions", body: body, timeout: 20))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            owLog("[MailAgent] HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
            throw LLMError.http(status)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let message = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            throw LLMError.malformed
        }
        return message
    }
}
