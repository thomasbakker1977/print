import Foundation
import SwiftData

/// Everything the user records is stored on the phone first and synced to the
/// homelab server when it is reachable. `needsSync` marks local edits that the
/// server has not seen yet; `isRemoved` is a tombstone so deletions sync too.

struct Dose: Codable, Hashable {
    var medicationId: String
    var amount: Double
}

@Model
final class DayEntry {
    @Attribute(.unique) var dayKey: String
    /// NIMH Life Chart severity, -4 (severe depression) ... +4 (severe mania). nil = not rated.
    var moodLevel: Int?
    /// Daily self-rating 0-100 where 50 is balanced.
    var moodRating: Double?
    var mixed: Bool = false
    var moodSwitches: Int = 0
    var sleepHours: Double?
    var anxiety: Int = 0
    var irritability: Int = 0
    var menstruating: Bool = false
    var weight: Double?
    var notes: String = ""
    var doses: [Dose] = []
    var updatedAt: Date = Date.now
    var needsSync: Bool = false
    var isRemoved: Bool = false

    init(dayKey: String) {
        self.dayKey = dayKey
    }

    var date: Date { DayKey.date(from: dayKey) ?? .distantPast }

    func touch() {
        updatedAt = .now
        needsSync = true
    }
}

@Model
final class Medication {
    @Attribute(.unique) var id: String
    var name: String
    var unit: String
    var defaultDose: Double
    var active: Bool = true
    var colorIndex: Int = 0
    var updatedAt: Date = Date.now
    var needsSync: Bool = false
    var isRemoved: Bool = false

    init(name: String, unit: String = "mg", defaultDose: Double = 0, colorIndex: Int = 0) {
        self.id = UUID().uuidString
        self.name = name
        self.unit = unit
        self.defaultDose = defaultDose
        self.colorIndex = colorIndex
    }

    func touch() {
        updatedAt = .now
        needsSync = true
    }
}

@Model
final class LifeEvent {
    @Attribute(.unique) var id: String
    var dateKey: String
    var title: String
    /// -4 (very negative) ... +4 (very positive)
    var impact: Int
    var details: String
    var updatedAt: Date = Date.now
    var needsSync: Bool = false
    var isRemoved: Bool = false

    init(dateKey: String, title: String, impact: Int = 0, details: String = "") {
        self.id = UUID().uuidString
        self.dateKey = dateKey
        self.title = title
        self.impact = impact
        self.details = details
    }

    var date: Date { DayKey.date(from: dateKey) ?? .distantPast }

    func touch() {
        updatedAt = .now
        needsSync = true
    }
}

/// A Schema Therapy flashcard to read when a familiar pattern is triggered.
@Model
final class Flashcard {
    @Attribute(.unique) var id: String
    var title: String
    var trigger: String
    var schemaText: String
    var reality: String
    var action: String
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var needsSync: Bool = false
    var isRemoved: Bool = false

    init(title: String, trigger: String = "", schemaText: String = "", reality: String = "", action: String = "") {
        self.id = UUID().uuidString
        self.title = title
        self.trigger = trigger
        self.schemaText = schemaText
        self.reality = reality
        self.action = action
    }

    func touch() {
        updatedAt = .now
        needsSync = true
    }
}

enum GoalStatus: String, CaseIterable, Identifiable {
    case active, paused, achieved, dropped
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@Model
final class Goal {
    @Attribute(.unique) var id: String
    var title: String
    var details: String
    var area: String
    var targetDateKey: String?
    var statusRaw: String = GoalStatus.active.rawValue
    var progress: Int = 0
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var needsSync: Bool = false
    var isRemoved: Bool = false

    init(title: String, details: String = "", area: String = "", targetDateKey: String? = nil) {
        self.id = UUID().uuidString
        self.title = title
        self.details = details
        self.area = area
        self.targetDateKey = targetDateKey
    }

    var status: GoalStatus {
        get { GoalStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    func touch() {
        updatedAt = .now
        needsSync = true
    }
}

/// Daily metrics from the user's Garmin watch, imported by the server. Read-only on the phone.
@Model
final class WearableDay {
    @Attribute(.unique) var dayKey: String
    var sleepHours: Double?
    var sleepScore: Int?
    var restingHeartRate: Int?
    var hrv: Int?
    var hrvStatus: String?
    var stressAvg: Int?
    var bodyBatteryHigh: Int?
    var bodyBatteryLow: Int?
    var steps: Int?
    var updatedAt: Date = Date.now

    init(dayKey: String) {
        self.dayKey = dayKey
    }

    var date: Date { DayKey.date(from: dayKey) ?? .distantPast }
}

enum MediaKind: String {
    case photo, video
}

/// A photo or video the user captured to show how a day felt. The file lives
/// in the app's private storage on the phone and is never synced.
@Model
final class MoodMedia {
    @Attribute(.unique) var id: String
    var dayKey: String
    var kindRaw: String
    var fileName: String
    var caption: String = ""
    var createdAt: Date = Date.now

    init(dayKey: String, kind: MediaKind, fileName: String, caption: String = "") {
        self.id = UUID().uuidString
        self.dayKey = dayKey
        self.kindRaw = kind.rawValue
        self.fileName = fileName
        self.caption = caption
    }

    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .photo }
    var url: URL { MediaStore.url(for: fileName) }
    var date: Date { DayKey.date(from: dayKey) ?? .distantPast }
}

enum DayKey {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func key(for date: Date) -> String {
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func date(from key: String) -> Date? {
        formatter.timeZone = .current
        return formatter.date(from: key)
    }

    static var today: String { key(for: .now) }
}

extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    func adding(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    var millis: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }

    init(millis: Int64) {
        self.init(timeIntervalSince1970: Double(millis) / 1000)
    }
}

let allModelTypes: [any PersistentModel.Type] = [
    DayEntry.self, Medication.self, LifeEvent.self, Flashcard.self, Goal.self, WearableDay.self,
    MoodMedia.self,
]
