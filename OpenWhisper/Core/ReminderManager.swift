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
    }

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
        let triggers = [
            "reminder",
            "remind",
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
            "hatırlatıcı",
            "hatırlat",
            "bana unutturma",
            "unutturma"
        ]
        return triggers.contains(where: {
            lower.hasPrefix($0) || lower.contains("reminder") || lower.contains("remind") || lower.contains("hatırlat") || lower.contains("unutturma")
        })
    }

    // MARK: - Parse & Schedule

    /// Parse reminder text using Ollama and schedule a notification
    func handleReminder(text: String) async -> Bool {
        owLog("[Reminders] Processing: \(text)")

        // Parse via Ollama
        guard let parsed = await parseWithOllama(text: text) else {
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
        let reminder = Reminder(
            id: UUID().uuidString,
            task: parsed.task,
            fireDate: parsed.fireDate,
            createdAt: Date()
        )

        let scheduled = await scheduleNotification(reminder: reminder)
        let savedApple = await createAppleReminder(reminder: reminder)

        if scheduled || savedApple {
            reminders.append(reminder)
            saveReminders()

            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            sendConfirmation(
                title: "✓ Hatırlatıcı Kuruldu",
                body: "\(reminder.task) — \(formatter.string(from: reminder.fireDate))"
            )
            owLog("[Reminders] Scheduled: \(reminder.task) at \(reminder.fireDate) (Apple Reminders: \(savedApple))")
        }
        return scheduled
    }

    // MARK: - Ollama Parsing

    private struct ParsedReminder {
        let task: String
        let fireDate: Date
    }

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
            "model": "qwen2.5:3b",
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": 0.1,
                "num_predict": 100
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else { return nil }

            owLog("[Reminders] Ollama response: \(responseText)")

            // Extract JSON from response (handle possible markdown wrapping)
            let cleanedResponse = responseText
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let responseData = cleanedResponse.data(using: .utf8),
                  let parsed = try JSONSerialization.jsonObject(with: responseData) as? [String: String],
                  let task = parsed["task"],
                  let datetimeStr = parsed["datetime"] else { return nil }

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
        content.title = "OpenWhisper Reminder"
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

    private func createAppleReminder(reminder: Reminder) async -> Bool {
        let store = EKEventStore()
        var granted = false
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .reminder)) ?? false
        }

        guard granted else {
            owLog("[Reminders] EventKit permission not granted")
            return false
        }

        guard let calendar = store.defaultCalendarForNewReminders() else {
            owLog("[Reminders] No default calendar found in Apple Reminders")
            return false
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
            return true
        } catch {
            owLog("[Reminders] Failed to save Apple Reminder: \(error)")
            return false
        }
    }

    // MARK: - Instant Confirmation Notification

    private func sendConfirmation(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "confirmation-\(UUID().uuidString)",
            content: content,
            trigger: nil // fires immediately
        )

        notificationCenter.add(request) { error in
            if let error = error {
                owLog("[Reminders] Confirmation notification error: \(error)")
            }
        }
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
