import EventKit
import Foundation

/// Reads the user's calendars and reminders (iCloud, Google, Outlook/Exchange —
/// whatever is set up on the iPhone) and adds items the coach proposes.
/// Calendar data never leaves the phone except as the short agenda summary
/// sent with a coach message, and only when the user has turned that on
/// (More → Calendar & reminders; off by default).
@MainActor
final class AgendaService: ObservableObject {
    static let shared = AgendaService()

    private let store = EKEventStore()

    @Published private(set) var calendarAccess = false
    @Published private(set) var reminderAccess = false

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        _ = try? await store.requestFullAccessToReminders()
        refreshStatus()
    }

    /// A plain-text overview of the coming days for the coach.
    func summary(days: Int = 7) async -> String {
        refreshStatus()
        var lines: [String] = []
        let now = Date.now

        if calendarAccess {
            let end = now.startOfDay.adding(days: days + 1)
            let predicate = store.predicateForEvents(withStart: now.startOfDay, end: end, calendars: nil)
            let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            lines.append("Calendar, next \(days) days:")
            if events.isEmpty { lines.append("- nothing scheduled") }
            for event in events.prefix(60) {
                let when = event.isAllDay
                    ? "\(Self.day.string(from: event.startDate)) all day"
                    : "\(Self.dayTime.string(from: event.startDate))–\(Self.time.string(from: event.endDate))"
                var line = "- \(when): \(event.title ?? "Busy")"
                if let location = event.location, !location.isEmpty { line += " @ \(location)" }
                lines.append(line)
            }
        }

        if reminderAccess {
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: now.adding(days: 14), calendars: nil
            )
            let reminders: [String] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { reminders in
                    let items = (reminders ?? []).prefix(40).map { reminder -> String in
                        var line = "- \(reminder.title ?? "Untitled")"
                        if let components = reminder.dueDateComponents,
                           let due = Calendar.current.date(from: components) {
                            line += " (due \(Self.dayTime.string(from: due)))"
                        }
                        return line
                    }
                    continuation.resume(returning: Array(items))
                }
            }
            lines.append("Open reminders (due within 2 weeks or undated):")
            lines.append(contentsOf: reminders.isEmpty ? ["- none"] : reminders)
        }
        return lines.joined(separator: "\n")
    }

    func addReminder(_ suggestion: Suggestion) throws {
        guard reminderAccess else { throw AgendaError.noAccess("Reminders") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = suggestion.title
        reminder.notes = suggestion.notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due = suggestion.due, let date = Self.parse(due) {
            let components: Set<Calendar.Component> = due.count > 10
                ? [.year, .month, .day, .hour, .minute]
                : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(components, from: date)
            if due.count > 10 { reminder.addAlarm(EKAlarm(absoluteDate: date)) }
        }
        try store.save(reminder, commit: true)
    }

    func addEvent(_ suggestion: Suggestion) throws {
        guard calendarAccess else { throw AgendaError.noAccess("Calendar") }
        guard let start = suggestion.start.flatMap(Self.parse),
              let end = suggestion.end.flatMap(Self.parse), end > start
        else { throw AgendaError.invalidDates }
        let event = EKEvent(eventStore: store)
        event.title = suggestion.title
        event.notes = suggestion.notes
        event.startDate = start
        event.endDate = end
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }

    /// Parses the coach's local "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM" strings.
    static func parse(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE yyyy-MM-dd"
        return formatter
    }()

    private static let dayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

enum AgendaError: LocalizedError {
    case noAccess(String)
    case invalidDates

    var errorDescription: String? {
        switch self {
        case let .noAccess(what): "LifeChart has no access to \(what). Allow it in More → Calendar & reminders."
        case .invalidDates: "The suggested time could not be read."
        }
    }
}
