import Foundation
import UserNotifications
import EventKit
import Observation

@Observable
@MainActor
final class ReminderManager {

    static let shared = ReminderManager()

    private let notificationCenter = UNUserNotificationCenter.current()
    private let eventStore = EKEventStore()
    private let storageURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("OpenWhisper")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reminders.json")
    }()

    // MARK: - Reminder Model

    struct Reminder: Codable, Identifiable {
        let id: String
        let task: String
        let fireDate: Date
        let createdAt: Date
        /// EventKit identifier of the Apple Reminders copy. Older persisted records decode
        /// without it and are matched by exact title + due date during deletion.
        let appleReminderIdentifier: String?

        init(
            id: String,
            task: String,
            fireDate: Date,
            createdAt: Date,
            appleReminderIdentifier: String? = nil
        ) {
            self.id = id
            self.task = task
            self.fireDate = fireDate
            self.createdAt = createdAt
            self.appleReminderIdentifier = appleReminderIdentifier
        }
    }

    struct DeletionRequest: Equatable, Sendable {
        let query: String?
        let deleteAll: Bool
    }

    enum DeletionResult: Equatable, Sendable {
        case confirmationRequired(matches: [String])
        case deleted(count: Int, appleVerified: Bool)
        case notFound
        case ambiguous(matches: [String])
        case cancelled
        case notConfirmed
        case confirmationExpired
        case failed
    }

    enum DeletionConfirmationDecision: Equatable, Sendable {
        case approve
        case reject
        case unclear
    }

    private struct ResolvedDeletion {
        let localMatches: [Reminder]
        let appleMatches: [EKReminder]
        let appleWasAvailable: Bool
        let displayNames: [String]
    }

    private struct PendingDeletion {
        let resolved: ResolvedDeletion
        let expiresAt: Date
    }

    private var pendingDeletion: PendingDeletion?
    private static let deletionConfirmationTimeout: TimeInterval = 45

    private(set) var reminders: [Reminder] = []

    private init() {
        loadReminders()
        purgeFiredReminders()
    }

    /// Remove reminders that have already fired (called on app launch)
    func purgeFiredReminders() {
        let before = reminders.count
        reminders.removeAll { $0.fireDate <= Date() }
        if reminders.count < before {
            saveReminders()
            owLog("[Reminders] Purged \(before - reminders.count) fired reminder(s)")
        }
    }

    // MARK: - Permission

    func requestPermission() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            owLog("[Reminders] Notification permission: \(granted)")
            return granted
        } catch {
            owLog("[Reminders] Permission error: \(error)")
            return false
        }
    }

    // MARK: - Detection

    /// Check if transcribed text is a reminder command.
    /// Matches when the sentence starts with or contains reminder keywords in English or Turkish.
    static func isReminder(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Multi-word phrases are safe to match anywhere via plain substring search — the
        // surrounding words already give them a natural boundary.
        let phraseTriggers = [
            "remind me",
            "set a reminder",
            "set reminder",
            "create a reminder",
            "add a reminder",
            "don't let me forget",
            "don't forget to",
            "bana hatırlat",
            "hatırlatıcı kur",
            "hatırlatıcı ekle",
            "bana unutturma"
        ]
        if phraseTriggers.contains(where: { lower.contains($0) }) { return true }

        // Single-word triggers MUST match as a whole word — otherwise Turkish agglutination
        // turns ordinary narration ("hatırlattım", "hatırlatmalıyım") into false positives.
        let wordTriggers = ["reminder", "remind", "hatırlatıcı", "hatırlat", "unutturma"]
        for word in wordTriggers {
            guard let re = try? NSRegularExpression(pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b") else { continue }
            let range = NSRange(lower.startIndex..., in: lower)
            if re.firstMatch(in: lower, range: range) != nil { return true }
        }
        return false
    }

    /// Recognizes only explicit reminder deletion commands. Requiring both a reminder noun and
    /// a deletion verb prevents ordinary phrases such as "dosyayı sil" from reaching EventKit.
    nonisolated static func deletionRequest(_ text: String) -> DeletionRequest? {
        let locale = Locale(identifier: "tr_TR")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased(with: locale)
        guard lowered.utf16.count == trimmed.utf16.count else { return nil }

        let reminderWord = #"(?:hatırlatıcı|anımsatıcı|reminder)\p{L}*"#
        let deletionVerb = #"(?:sil|kaldır|iptal\s+et)\p{L}*"#
        let pattern = #"^\s*(.*?)\s*\b"# + reminderWord + #"\b\s*(?:\S+\s+){0,2}?"# + deletionVerb + #"\s*[.!?]*\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) else {
            return nil
        }

        let prefixRange = match.range(at: 1)
        guard let range = Range(prefixRange, in: trimmed) else { return nil }
        var query = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        query = query.replacingOccurrences(
            of: #"^(?:jarvis|hey\s+jarvis|selam\s+jarvis)\b[\s,:;-]*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let folded = foldForMatching(query)
        let wholeCommand = foldForMatching(trimmed)
        let allWords: Set<String> = ["tum", "butun", "hepsi", "hepsini", "hepsini de", "all"]
        let deleteAll = allWords.contains(folded)
            || folded.hasPrefix("tum ")
            || folded.hasPrefix("butun ")
            || folded.hasSuffix(" hepsini")
            || wholeCommand.contains("tum hatirlatici")
            || wholeCommand.contains("butun hatirlatici")
            || wholeCommand.contains("hatirlaticilarin hepsini")

        if deleteAll { return DeletionRequest(query: nil, deleteAll: true) }
        return DeletionRequest(query: query.isEmpty ? nil : query, deleteAll: false)
    }

    nonisolated static func reminderTitle(_ title: String, matches query: String) -> Bool {
        let candidate = foldForMatching(title)
        let wanted = foldForMatching(query)
        guard !candidate.isEmpty, !wanted.isEmpty else { return false }
        if candidate == wanted || candidate.contains(wanted) || wanted.contains(candidate) {
            return true
        }

        let candidateWords = Set(candidate.split(separator: " ").map(String.init).filter { $0.count >= 3 })
        let wantedWords = Set(wanted.split(separator: " ").map(String.init).filter { $0.count >= 3 })
        guard !candidateWords.isEmpty, !wantedWords.isEmpty else { return false }
        return wantedWords.allSatisfy { wantedWord in
            candidateWords.contains { candidateWord in
                candidateWord.hasPrefix(wantedWord) || wantedWord.hasPrefix(candidateWord)
            }
        }
    }

    /// Only a short, explicit answer can authorize a pending destructive action. Negative
    /// forms are checked first so "onaylamıyorum" can never be mistaken for approval.
    nonisolated static func deletionConfirmationDecision(_ text: String) -> DeletionConfirmationDecision {
        var answer = foldForMatching(text)
        if answer.hasPrefix("jarvis ") {
            answer.removeFirst("jarvis ".count)
        }

        let rejections: Set<String> = [
            "hayir", "hayir silme", "silme", "iptal", "iptal et", "vazgec", "vazgectim",
            "onaylamiyorum", "onay vermiyorum", "reddediyorum"
        ]
        if rejections.contains(answer) { return .reject }

        let approvals: Set<String> = [
            "evet", "evet onayliyorum", "onayliyorum", "onay veriyorum", "tamam",
            "tamam sil", "sil", "devam et"
        ]
        if approvals.contains(answer) { return .approve }
        return .unclear
    }

    nonisolated private static func foldForMatching(_ text: String) -> String {
        let locale = Locale(identifier: "tr_TR")
        return text
            .lowercased(with: locale)
            .folding(options: [.diacriticInsensitive], locale: locale)
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parse & Schedule

    /// Parse reminder text and schedule a notification. Tries the deterministic Turkish
    /// relative-date parser first (fast, exact, no network dependency); only falls back to
    /// the Ollama LLM for phrasing the regex parser doesn't recognize.
    func handleReminder(text: String) async -> Bool {
        owLog("[Reminders] Processing: \(text)")

        let parsed: ParsedReminder
        if let detParsed = TurkishDateParser.parse(text) {
            owLog("[Reminders] Parsed deterministically — task: \(detParsed.task), date: \(detParsed.fireDate)")
            parsed = ParsedReminder(task: detParsed.task, fireDate: detParsed.fireDate)
        } else if let llmParsed = await parseWithOllama(text: text) {
            parsed = llmParsed
        } else {
            owLog("[Reminders] Failed to parse reminder")
            sendConfirmation(title: "Hatırlatıcı Anlaşılamadı", body: "Örnek: \"Bana 10 dakika sonra toplantıyı hatırlat\"")
            return false
        }

        owLog("[Reminders] Parsed — task: \(parsed.task), date: \(parsed.fireDate)")

        // If time is in the past, it will fire immediately — that's fine
        if parsed.fireDate <= Date() {
            owLog("[Reminders] Date is in the past, will fire immediately: \(parsed.fireDate)")
        }

        // Schedule notification
        let reminderID = UUID().uuidString
        let draft = Reminder(
            id: reminderID,
            task: parsed.task,
            fireDate: parsed.fireDate,
            createdAt: Date()
        )

        let scheduled = await scheduleNotification(reminder: draft)
        let appleIdentifier = await createAppleReminder(reminder: draft)
        let reminder = Reminder(
            id: reminderID,
            task: parsed.task,
            fireDate: parsed.fireDate,
            createdAt: draft.createdAt,
            appleReminderIdentifier: appleIdentifier
        )

        if scheduled || appleIdentifier != nil {
            reminders.append(reminder)
            saveReminders()

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            sendConfirmation(
                title: "✓ Hatırlatıcı Kuruldu",
                body: "\(reminder.task) — \(formatter.string(from: reminder.fireDate))"
            )
            owLog("[Reminders] Scheduled: \(reminder.task) at \(reminder.fireDate) (Apple Reminders: \(appleIdentifier != nil))")
        }
        // A reminder is a success if EITHER the local notification was scheduled or it landed
        // in Apple Reminders — previously this only checked `scheduled`, so a successful Apple
        // Reminders save with a failed/denied notification was silently reported as failure.
        return scheduled || appleIdentifier != nil
    }

    // MARK: - Ollama Parsing

    private struct ParsedReminder {
        let task: String
        let fireDate: Date
    }

    /// The model the user picked in Settings (AppState.ollamaModel, UserDefaults key
    /// "ollamaModel", default LLMCleanup.defaultModel). ReminderManager is a standalone singleton with no
    /// AppState reference, so it reads the same UserDefaults key directly rather than
    /// hardcoding a model that may not actually be installed (this was the root cause of
    /// reminders silently never firing — see git history).
    private var selectedOllamaModel: String {
        UserDefaults.standard.string(forKey: "ollamaModel") ?? LLMCleanup.defaultModel
    }

    /// Constrains Ollama to the two fields the parser accepts. Plain `"json"` mode only
    /// guarantees syntactically valid JSON; a schema also prevents renamed/missing fields and
    /// non-string values from reaching the defensive fallback parser below.
    static let ollamaResponseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "task": ["type": "string"],
            "datetime": ["type": "string"]
        ],
        "required": ["task", "datetime"],
        "additionalProperties": false
    ]

    /// Ask Ollama to parse task description and target fireDate from voice text
    private func parseWithOllama(text: String) async -> ParsedReminder? {
        guard let url = URL(string: "http://localhost:11434/api/generate") else { return nil }

        let now = Date()
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone.current
        let currentTime = df.string(from: now)

        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        dateOnlyFormatter.timeZone = TimeZone.current
        let currentDateStr = dateOnlyFormatter.string(from: now)
        let tomorrowDateStr = dateOnlyFormatter.string(from: tomorrow)

        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEE"
        weekdayFormatter.locale = Locale(identifier: "tr_TR")
        let currentWeekday = weekdayFormatter.string(from: now)

        let prompt = """
            Extract the task description and scheduled date/time from this voice reminder command.
            Current reference date & time: \(currentTime) (\(currentWeekday))
            Today's date: \(currentDateStr)
            Tomorrow's date: \(tomorrowDateStr)

            TURKISH & ENGLISH TIME PARSING RULES:
            - "bugün" = today (\(currentDateStr))
            - "yarın" = tomorrow (\(tomorrowDateStr))
            - Expressions like "yarın 17 ye", "yarın 17'ye", "yarın saat 17", "yarın 17:00" = tomorrow at 17:00:00 (\(tomorrowDateStr)T17:00:00)
            - Expressions like "bugün 18'de", "bugün 18 e" = today at 18:00:00 (\(currentDateStr)T18:00:00)
            - Specific dates like "17 Temmuz", "15 Ağustos" = use that specific date and current/next year.
            - "X dakika sonra" / "X saat sonra" = add X minutes/hours to reference time \(currentTime).
            - If the command does NOT mention a specific time of day, default the time to 09:00:00.

            CRITICAL TASK EXTRACTION RULES:
            - The "task" field MUST BE IN THE EXACT ORIGINAL LANGUAGE (Turkish if spoken in Turkish).
            - The "task" field MUST contain ONLY the action to be done (e.g. "Telefonu yıka", "Raporu gönder").
            - REMOVE all trigger words ("hatırlatıcı", "bana hatırlat", "hatırlatıcı kur", "remind me to", etc.) AND REMOVE all time/date expressions ("yarın 17 ye", "bugün 18'de", "10 dakika sonra", etc.).

            EXAMPLES:
            - Input: "hatırlatıcı yarın 17 ye telefonu yıka"
              -> {"task": "Telefonu yıka", "datetime": "\(tomorrowDateStr)T17:00:00"}
            - Input: "hatırlatıcı bugün 18 de markete git"
              -> {"task": "Markete git", "datetime": "\(currentDateStr)T18:00:00"}
            - Input: "bana 10 dakika sonra kahve içmeyi hatırlat"
              -> {"task": "Kahve iç", "datetime": "..."}

            Return ONLY a valid JSON object: {"task": "...", "datetime": "YYYY-MM-DDTHH:MM:SS"}.
            Voice command: "\(text)"
            """

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": selectedOllamaModel,
            "prompt": prompt,
            "stream": false,
            // qwen3 (and other "thinking" models) emit a <think>...</think> block by default,
            // which used to eat the whole num_predict budget and leave "response" empty
            // (done_reason "length") before any JSON was produced. "think": false skips that,
            // and a JSON schema makes Ollama constrain both the syntax and required fields.
            "think": false,
            "keep_alive": LLMCleanup.keepAlive,
            "format": Self.ollamaResponseSchema,
            "options": [
                "temperature": 0.1,
                "num_predict": 150
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                owLog("[Reminders] Ollama HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else { return nil }

            owLog("[Reminders] Ollama response: \(responseText)")

            guard let parsed = Self.extractJSONObject(from: responseText),
                  let task = parsed["task"],
                  let datetimeStr = parsed["datetime"] else {
                owLog("[Reminders] Could not extract task/datetime from Ollama response")
                return nil
            }

            guard let fireDate = parseDateString(datetimeStr) else {
                owLog("[Reminders] Failed to parse date: \(datetimeStr)")
                return nil
            }

            return ParsedReminder(task: task, fireDate: fireDate)
        } catch {
            owLog("[Reminders] Ollama parse error: \(error)")
            return nil
        }
    }

    /// Extract the first `{...}` JSON object from a model response and return its top-level
    /// fields as strings. Uses `[String: Any]` rather than `[String: String]` because a model
    /// can return a number or nested value for a field — that used to make the whole parse
    /// return nil instead of just coercing the value to a string. Also strips any stray
    /// `<think>...</think>` block and markdown code fences some models still emit even with
    /// "think": false / "format": "json" set on the request.
    private static func extractJSONObject(from text: String) -> [String: String]? {
        var cleaned = text
        if let thinkRange = cleaned.range(of: "<think>"), let thinkEnd = cleaned.range(of: "</think>") {
            cleaned.removeSubrange(thinkRange.lowerBound..<thinkEnd.upperBound)
        }
        cleaned = cleaned
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let openBrace = cleaned.firstIndex(of: "{"),
              let closeBrace = cleaned.lastIndex(of: "}"),
              openBrace < closeBrace else { return nil }

        let jsonSlice = String(cleaned[openBrace...closeBrace])
        guard let data = jsonSlice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var result: [String: String] = [:]
        for (key, value) in obj {
            switch value {
            case let s as String: result[key] = s
            case let n as NSNumber: result[key] = n.stringValue
            default: continue
            }
        }
        return result
    }

    private func parseDateString(_ datetimeStr: String) -> Date? {
        let clean = datetimeStr.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        for fmt in formats {
            df.dateFormat = fmt
            if let date = df.date(from: clean) {
                return date
            }
        }
        return nil
    }

    // MARK: - Notification Scheduling

    private func scheduleNotification(reminder: Reminder) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "Jarvis Hatırlatıcı"
        content.body = reminder.task
        content.sound = .default
        content.categoryIdentifier = "REMINDER"

        let triggerDate = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: reminder.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false)

        let request = UNNotificationRequest(
            identifier: reminder.id,
            content: content,
            trigger: trigger
        )

        do {
            try await notificationCenter.add(request)
            return true
        } catch {
            owLog("[Reminders] Schedule error: \(error)")
            return false
        }
    }

    // MARK: - EventKit (Apple Reminders App)

    private func createAppleReminder(reminder: Reminder) async -> String? {
        // Reuse the single shared eventStore instance rather than creating a fresh
        // EKEventStore() per call — a new store has to re-establish its authorization state
        // with the OS on every call, which can spuriously appear unauthorized/denied.
        let store = eventStore
        var granted = false
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .reminder)) ?? false
        }

        guard granted else {
            owLog("[Reminders] EventKit permission not granted")
            return nil
        }

        guard let calendar = store.defaultCalendarForNewReminders() else {
            owLog("[Reminders] No default calendar found in Apple Reminders")
            return nil
        }

        let ekReminder = EKReminder(eventStore: store)
        ekReminder.title = reminder.task
        ekReminder.calendar = calendar

        let alarm = EKAlarm(absoluteDate: reminder.fireDate)
        ekReminder.addAlarm(alarm)

        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
        ekReminder.dueDateComponents = components

        do {
            try store.save(ekReminder, commit: true)
            owLog("[Reminders] Successfully created Apple Reminder: \(reminder.task)")
            return ekReminder.calendarItemIdentifier
        } catch {
            owLog("[Reminders] Failed to save Apple Reminder: \(error)")
            return nil
        }
    }

    // MARK: - Deletion

    /// Resolves the exact records first but does not mutate anything. The returned plan is kept
    /// for a short, single-use confirmation window so later records cannot enter the deletion.
    func beginDeletion(_ request: DeletionRequest) async -> DeletionResult {
        pendingDeletion = nil
        let resolution = await resolveDeletion(request)
        switch resolution {
        case .success(let resolved):
            pendingDeletion = PendingDeletion(
                resolved: resolved,
                expiresAt: Date().addingTimeInterval(Self.deletionConfirmationTimeout)
            )
            owLog("[Reminders] Deletion awaiting confirmation for: \(resolved.displayNames.joined(separator: ", "))")
            return .confirmationRequired(matches: resolved.displayNames)
        case .failure(let result):
            return result
        }
    }

    /// Consumes the pending plan. Any answer other than an explicit approval prevents deletion;
    /// approvals after the timeout are also rejected.
    func handleDeletionConfirmation(_ text: String) async -> DeletionResult? {
        guard let pending = pendingDeletion else { return nil }
        let decision = Self.deletionConfirmationDecision(text)

        guard pending.expiresAt > Date() else {
            pendingDeletion = nil
            owLog("[Reminders] Deletion confirmation expired")
            return decision == .approve ? .confirmationExpired : nil
        }

        pendingDeletion = nil
        switch decision {
        case .approve:
            owLog("[Reminders] Deletion explicitly approved")
            return await executeDeletion(pending.resolved)
        case .reject:
            owLog("[Reminders] Deletion explicitly cancelled")
            return .cancelled
        case .unclear:
            owLog("[Reminders] Deletion not confirmed; pending plan discarded")
            return .notConfirmed
        }
    }

    /// Called when the dedicated confirmation recording closes without a usable answer. This
    /// makes the three-second listening window authoritative: a later unrelated "evet" can
    /// never approve an old deletion plan.
    @discardableResult
    func cancelPendingDeletion() -> Bool {
        guard pendingDeletion != nil else { return false }
        pendingDeletion = nil
        owLog("[Reminders] Pending deletion discarded without confirmation")
        return true
    }

    private enum DeletionResolution {
        case success(ResolvedDeletion)
        case failure(DeletionResult)
    }

    /// A non-"all" request never guesses between multiple local or Apple reminders.
    private func resolveDeletion(_ request: DeletionRequest) async -> DeletionResolution {
        if !request.deleteAll, request.query == nil, reminders.count > 1 {
            return .failure(.ambiguous(matches: reminders.map(\.task)))
        }

        let localMatches: [Reminder]
        if request.deleteAll {
            localMatches = reminders
        } else if let query = request.query {
            localMatches = reminders.filter { Self.reminderTitle($0.task, matches: query) }
        } else if reminders.count == 1 {
            localMatches = reminders
        } else {
            localMatches = []
        }

        if !request.deleteAll, localMatches.count > 1 {
            return .failure(.ambiguous(matches: localMatches.map(\.task)))
        }

        let appleFetch = await matchingAppleReminders(for: request, localMatches: localMatches)
        if !request.deleteAll, localMatches.isEmpty,
           case .available(let appleMatches) = appleFetch,
           appleMatches.count > 1 {
            return .failure(.ambiguous(matches: appleMatches.compactMap(\.title)))
        }

        let appleMatches: [EKReminder]
        let appleWasAvailable: Bool
        switch appleFetch {
        case .available(let matches):
            appleMatches = matches
            appleWasAvailable = true
        case .unavailable:
            appleMatches = []
            appleWasAvailable = false
        }

        guard !localMatches.isEmpty || !appleMatches.isEmpty else {
            return .failure(appleWasAvailable ? .notFound : .failed)
        }

        let names = Array(Set(
            localMatches.map(\.task) + appleMatches.compactMap(\.title)
        )).sorted()
        return .success(ResolvedDeletion(
            localMatches: localMatches,
            appleMatches: appleMatches,
            appleWasAvailable: appleWasAvailable,
            displayNames: names
        ))
    }

    private func executeDeletion(_ resolved: ResolvedDeletion) async -> DeletionResult {
        let localMatches = resolved.localMatches
        let appleMatches = resolved.appleMatches
        let appleWasAvailable = resolved.appleWasAvailable

        var appleDeleteSucceeded = appleWasAvailable
        if !appleMatches.isEmpty {
            do {
                for reminder in appleMatches {
                    try eventStore.remove(reminder, commit: false)
                }
                try eventStore.commit()
                owLog("[Reminders] Deleted \(appleMatches.count) Apple reminder(s)")
            } catch {
                appleDeleteSucceeded = false
                owLog("[Reminders] Failed to delete Apple reminder: \(error)")
            }
        }

        let localIDs = localMatches.map(\.id)
        if !localIDs.isEmpty {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: localIDs)
            let idSet = Set(localIDs)
            reminders.removeAll { idSet.contains($0.id) }
            saveReminders()
            owLog("[Reminders] Deleted \(localIDs.count) local reminder(s)")
        }

        let logicalCount = max(localMatches.count, appleMatches.count)
        let appleVerified = appleWasAvailable && appleDeleteSucceeded
        let body = appleVerified
            ? "\(logicalCount) hatırlatıcı silindi."
            : "Yerel hatırlatıcı silindi; Apple Hatırlatıcılar kontrol edilemedi."
        sendConfirmation(title: "Hatırlatıcı Silindi", body: body)
        return .deleted(count: logicalCount, appleVerified: appleVerified)
    }

    private enum AppleReminderFetch {
        case available([EKReminder])
        case unavailable
    }

    private func matchingAppleReminders(
        for request: DeletionRequest,
        localMatches: [Reminder]
    ) async -> AppleReminderFetch {
        var granted = false
        if #available(macOS 14.0, *) {
            granted = (try? await eventStore.requestFullAccessToReminders()) ?? false
        } else {
            granted = (try? await eventStore.requestAccess(to: .reminder)) ?? false
        }
        guard granted else {
            owLog("[Reminders] Cannot verify Apple reminder deletion — EventKit permission unavailable")
            return .unavailable
        }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let all: [EKReminder] = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        let matches: [EKReminder]
        if request.deleteAll {
            // "Tümünü sil" is deliberately scoped to Jarvis-managed reminders; it must
            // never wipe unrelated personal reminders from Apple Reminders.
            matches = all.filter { appleReminder in
                localMatches.contains { self.sameReminder($0, appleReminder) }
            }
        } else if !localMatches.isEmpty {
            matches = all.filter { appleReminder in
                localMatches.contains { self.sameReminder($0, appleReminder) }
            }
        } else if let query = request.query {
            matches = all.filter { Self.reminderTitle($0.title ?? "", matches: query) }
        } else {
            matches = []
        }
        return .available(matches)
    }

    private func sameReminder(_ local: Reminder, _ apple: EKReminder) -> Bool {
        if let identifier = local.appleReminderIdentifier,
           identifier == apple.calendarItemIdentifier {
            return true
        }
        guard Self.reminderTitle(apple.title ?? "", matches: local.task),
              Self.reminderTitle(local.task, matches: apple.title ?? "") else {
            return false
        }
        guard let components = apple.dueDateComponents,
              let appleDate = Calendar.current.date(from: components) else {
            return false
        }
        return abs(appleDate.timeIntervalSince(local.fireDate)) <= 120
    }

    // MARK: - Instant Confirmation Notification

    private func sendConfirmation(title: String, body: String) {
        let isError = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains("anlaşılamadı")
        OpenWhisperNotification.post(title: title, body: body, isError: isError, identifierPrefix: "reminder-confirmation")
    }

    // MARK: - Persistence

    private func saveReminders() {
        // Clean up past reminders
        reminders = reminders.filter { $0.fireDate > Date() }
        do {
            let data = try JSONEncoder().encode(reminders)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            owLog("[Reminders] Save error: \(error)")
        }
    }

    private func loadReminders() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            reminders = try JSONDecoder().decode([Reminder].self, from: data)
            // Clean expired
            reminders = reminders.filter { $0.fireDate > Date() }
        } catch {
            owLog("[Reminders] Load error: \(error)")
        }
    }

    // MARK: - Cleanup

    func cancelReminder(id: String) {
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [id])
        reminders.removeAll { $0.id == id }
        saveReminders()
    }

    func cancelAll() {
        notificationCenter.removeAllPendingNotificationRequests()
        reminders.removeAll()
        saveReminders()
    }
}
