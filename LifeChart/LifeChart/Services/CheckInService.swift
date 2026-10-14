import EventKit
import Foundation
import SwiftData
import UserNotifications

/// Local check-in notifications. Everything is decided on the phone and
/// re-planned whenever the app opens, the user does something, or iOS runs a
/// background refresh:
/// - silence: no activity for 1, 2 or 3 days
/// - evening reminder when today is not logged yet
/// - follow-ups on reminders and calendar blocks the coach suggested
/// - overdue reminders
/// - several short nights according to the watch
@MainActor
final class CheckInService {
    static let shared = CheckInService()

    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private static let prefix = "checkin."

    // MARK: - Settings

    var isEnabled: Bool {
        get { defaults.object(forKey: "checkInsEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkInsEnabled") }
    }

    /// Minutes after midnight for the evening log reminder (default 21:00).
    var logReminderMinutes: Int {
        get { defaults.object(forKey: "logReminderMinutes") as? Int ?? 21 * 60 }
        set { defaults.set(newValue, forKey: "logReminderMinutes") }
    }

    var quietStartHour: Int { defaults.object(forKey: "quietStartHour") as? Int ?? 22 }
    var quietEndHour: Int { defaults.object(forKey: "quietEndHour") as? Int ?? 8 }

    private var name: String { defaults.string(forKey: "profileName") ?? "" }

    private var lastActivity: Date {
        get { defaults.object(forKey: "lastActivity") as? Date ?? .now }
        set { defaults.set(newValue, forKey: "lastActivity") }
    }

    // MARK: - Follow-ups for items the coach suggested

    struct FollowUp: Codable {
        var title: String
        var fireDate: Date
        var reminderId: String?
    }

    private var followUps: [FollowUp] {
        get {
            guard let data = defaults.data(forKey: "followUps") else { return [] }
            return (try? JSONDecoder().decode([FollowUp].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "followUps") }
    }

    private var notifiedKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: "notifiedCheckIns") ?? []) }
        set { defaults.set(Array(newValue.suffix(200)), forKey: "notifiedCheckIns") }
    }

    func addFollowUp(title: String, at date: Date, reminderId: String? = nil) {
        followUps = followUps.filter { $0.fireDate > .now } + [FollowUp(title: title, fireDate: date, reminderId: reminderId)]
    }

    // MARK: - Planning

    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Call when the user logs, chats or opens the app.
    func recordActivity(_ context: ModelContext) async {
        lastActivity = .now
        await reschedule(context)
    }

    func reschedule(_ context: ModelContext) async {
        // One-off nudges (overdue tasks, sleep) stay pending until they fire.
        let oneOff = [Self.prefix + "overdue", Self.prefix + "sleep"]
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) && !oneOff.contains($0) }
        )
        guard isEnabled else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        let hello = name.isEmpty ? "Hey" : "Hey \(name)"
        scheduleLogReminders(context, hello: hello)
        scheduleSilenceCheckIns(hello: hello)
        await scheduleFollowUps(hello: hello)
        await scheduleOverdueNudge(hello: hello)
        scheduleSleepSignal(context, hello: hello)
    }

    private func scheduleLogReminders(_ context: ModelContext, hello: String) {
        let todayKey = DayKey.today
        let descriptor = FetchDescriptor<DayEntry>(predicate: #Predicate { $0.dayKey == todayKey })
        let loggedToday = (try? context.fetch(descriptor).first)?.moodLevel != nil
        let todayAt = Date.now.startOfDay.addingTimeInterval(TimeInterval(logReminderMinutes * 60))

        if !loggedToday, todayAt > .now {
            schedule("log.today", at: todayAt,
                     title: "How was today?",
                     body: "\(hello), take a minute to log your mood. You can just say it to me.",
                     prompt: "Let's do my evening check-in.")
        }
        // Tomorrow's reminder is re-planned (or dropped) as soon as tomorrow is logged.
        schedule("log.tomorrow", at: todayAt.adding(days: 1),
                 title: "How was today?",
                 body: "\(hello), take a minute to log your mood. You can just say it to me.",
                 prompt: "Let's do my evening check-in.")
    }

    private func scheduleSilenceCheckIns(hello: String) {
        let messages = [
            (1, "Checking in", "\(hello), I haven't heard from you since yesterday. How are you doing?",
             "I haven't checked in for a day. Ask me how I'm doing."),
            (2, "Thinking of you", "\(hello), it's been two days. No pressure, just a quick word on how things are?",
             "I've been quiet for two days. Check in with me gently."),
            (3, "Still here for you", "\(hello), three quiet days. If things are hard, it may help to reach out to someone from your plan. I'm here too.",
             "I've been quiet for three days. Check how I'm doing and whether I should reach out to someone from my crisis plan."),
        ]
        for (days, title, body, prompt) in messages {
            schedule("silence.\(days)", at: allowed(lastActivity.addingTimeInterval(TimeInterval(days) * 86400)),
                     title: title, body: body, prompt: prompt)
        }
    }

    private func scheduleFollowUps(hello: String) async {
        let store = EKEventStore()
        var remaining: [FollowUp] = []
        for followUp in followUps where followUp.fireDate > .now.addingTimeInterval(-86400) {
            if let id = followUp.reminderId, let reminder = store.calendarItem(withIdentifier: id) as? EKReminder,
               reminder.isCompleted {
                continue
            }
            remaining.append(followUp)
            guard followUp.fireDate > .now else { continue }
            schedule("followup.\(Int(followUp.fireDate.timeIntervalSince1970)).\(abs(followUp.title.hashValue))",
                     at: allowed(followUp.fireDate),
                     title: followUp.title,
                     body: "\(hello), how did \"\(followUp.title)\" go?",
                     prompt: "Ask me how \"\(followUp.title)\" went.")
        }
        followUps = remaining
    }

    private func scheduleOverdueNudge(hello: String) async {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        let store = EKEventStore()
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: .now.adding(days: -3), ending: .now.addingTimeInterval(-2 * 3600), calendars: nil
        )
        let overdue: [(String, String)] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map { ($0.calendarItemIdentifier, $0.title ?? "a task") })
            }
        }
        let fresh = overdue.filter { !notifiedKeys.contains("overdue.\($0.0)") }
        guard !fresh.isEmpty else { return }
        let titles = fresh.prefix(2).map { "\"\($0.1)\"" }.joined(separator: " and ")
        schedule("overdue", at: allowed(.now.addingTimeInterval(60)),
                 title: "Still on your list",
                 body: "\(hello), \(titles) didn't happen yet. Want to do it now, reschedule or let it go?",
                 prompt: "Help me with my overdue tasks: \(titles).")
        notifiedKeys.formUnion(fresh.map { "overdue.\($0.0)" })
    }

    private func scheduleSleepSignal(_ context: ModelContext, hello: String) {
        let keys = [DayKey.today, DayKey.key(for: .now.adding(days: -1))]
        let descriptor = FetchDescriptor<WearableDay>(predicate: #Predicate { keys.contains($0.dayKey) })
        let nights = (try? context.fetch(descriptor)) ?? []
        let short = nights.filter { ($0.sleepHours ?? 24) < 5.5 }
        let key = "sleep.\(DayKey.today)"
        guard short.count >= 2, !notifiedKeys.contains(key) else { return }
        schedule("sleep", at: allowed(.now.addingTimeInterval(60)),
                 title: "Short nights",
                 body: "\(hello), your watch shows two short nights in a row. Worth a look at your signaleringsplan together?",
                 prompt: "My watch shows two short nights. Let's check this against my signaleringsplan.")
        notifiedKeys.insert(key)
    }

    // MARK: - Helpers

    /// Moves a time out of the night-time quiet hours.
    private func allowed(_ date: Date) -> Date {
        let hour = Calendar.current.component(.hour, from: date)
        let inQuiet = quietStartHour > quietEndHour
            ? (hour >= quietStartHour || hour < quietEndHour)
            : (hour >= quietStartHour && hour < quietEndHour)
        guard inQuiet else { return date }
        var morning = Calendar.current.date(bySettingHour: quietEndHour, minute: 0, second: 0, of: date) ?? date
        if morning < date { morning = morning.adding(days: 1) }
        return morning
    }

    private func schedule(_ id: String, at date: Date, title: String, body: String, prompt: String) {
        guard date > .now else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["prompt": prompt]
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: Self.prefix + id, content: content, trigger: trigger))
    }
}
