import Foundation

// Wire format shared with the homelab backend (backend/app/schemas.py).
// `updatedAt` is epoch milliseconds; the newest write wins.

struct DayEntryDTO: Codable {
    var day: String
    var updatedAt: Int64
    var deleted: Bool
    var moodLevel: Int?
    var moodRating: Double?
    var mixed: Bool
    var moodSwitches: Int
    var sleepHours: Double?
    var anxiety: Int
    var irritability: Int
    var menstruating: Bool
    var weight: Double?
    var notes: String
    var doses: [Dose]
}

struct MedicationDTO: Codable {
    var id: String
    var updatedAt: Int64
    var deleted: Bool
    var name: String
    var unit: String
    var defaultDose: Double
    var active: Bool
    var colorIndex: Int
}

struct LifeEventDTO: Codable {
    var id: String
    var updatedAt: Int64
    var deleted: Bool
    var date: String
    var title: String
    var impact: Int
    var details: String
}

struct FlashcardDTO: Codable {
    var id: String
    var updatedAt: Int64
    var deleted: Bool
    var title: String
    var trigger: String
    var schemaText: String
    var reality: String
    var action: String
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, updatedAt, deleted, title, trigger, reality, action, createdAt
        case schemaText = "schema"
    }
}

struct GoalDTO: Codable {
    var id: String
    var updatedAt: Int64
    var deleted: Bool
    var title: String
    var details: String
    var area: String
    var targetDate: String?
    var status: String
    var progress: Int
    var createdAt: Int64
}

struct WearableDayDTO: Codable {
    var day: String
    var updatedAt: Int64
    var sleepHours: Double?
    var sleepScore: Int?
    var restingHeartRate: Int?
    var hrv: Int?
    var hrvStatus: String?
    var stressAvg: Int?
    var bodyBatteryHigh: Int?
    var bodyBatteryLow: Int?
    var steps: Int?
}

struct SyncRequestDTO: Codable {
    var cursor: Int
    var entries: [DayEntryDTO]
    var medications: [MedicationDTO]
    var events: [LifeEventDTO]
    var flashcards: [FlashcardDTO]
    var goals: [GoalDTO]
}

struct SyncResponseDTO: Codable {
    var cursor: Int
    var entries: [DayEntryDTO]
    var medications: [MedicationDTO]
    var events: [LifeEventDTO]
    var flashcards: [FlashcardDTO]
    var goals: [GoalDTO]
    var wearables: [WearableDayDTO]
}

struct ProfileDTO: Codable, Equatable {
    var aboutMe: String = ""
    var careHistory: String = ""
    var warningSigns: String = ""
    var crisisPlan: String = ""
    var myWhy: String = ""
}

struct GarminStatusDTO: Codable {
    var enabled: Bool
    var lastSync: Int64?
    var lastError: String?
}

struct ServerStatusDTO: Codable {
    var coach: Bool
    var garmin: GarminStatusDTO
    var cursor: Int
}

// MARK: - Coach

enum CoachMode: String, Codable, CaseIterable, Identifiable {
    case talk, perspective, why, review, reflect, assistant

    /// The modes offered as coaching conversations; the assistant has its own screen.
    static var coaching: [CoachMode] { [.talk, .perspective, .why, .reflect, .review] }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .talk: "Talk it through"
        case .perspective: "Make sense of a moment"
        case .why: "Find my Why"
        case .review: "Review & advice"
        case .reflect: "Reflect on an event"
        case .assistant: "Assistant"
        }
    }

    var subtitle: String {
        switch self {
        case .talk: "Vent, think out loud or plan your day."
        case .perspective: "Slow down, rewind and see a situation from more sides."
        case .why: "Discover what really drives you."
        case .review: "Look back on your weeks and goals, and decide what's next."
        case .reflect: "Find the meaning, lessons and vision in something that happened."
        case .assistant: "Hands-free: log your day, briefings, reminders."
        }
    }

    var systemImage: String {
        switch self {
        case .talk: "bubble.left.and.bubble.right"
        case .perspective: "arrow.uturn.backward.circle"
        case .why: "sparkles"
        case .review: "chart.line.uptrend.xyaxis"
        case .reflect: "eye"
        case .assistant: "waveform"
        }
    }
}

struct ChatRequestDTO: Codable {
    var conversationId: String?
    var message: String
    var mode: CoachMode
    var spoken: Bool
    var localTime: String
    var agenda: String
    var assistantName: String
}

/// Something the coach proposes; the user decides whether to add it.
struct Suggestion: Codable, Hashable {
    var kind: String
    var title: String
    var due: String?
    var notes: String?
    var start: String?
    var end: String?
    var trigger: String?
    var schema: String?
    var reality: String?
    var action: String?
    var details: String?
    var area: String?
    var targetDate: String?
}

struct ChatMessageDTO: Codable {
    var role: String
    var content: String
    var createdAt: Int64
    var suggestions: [Suggestion]
}

struct ConversationDTO: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var mode: CoachMode
    var createdAt: Int64
    var updatedAt: Int64
}

struct ConversationDetailDTO: Codable {
    var id: String
    var title: String
    var mode: CoachMode
    var createdAt: Int64
    var updatedAt: Int64
    var messages: [ChatMessageDTO]
}

enum ChatEvent {
    case conversation(id: String)
    case text(String)
    case suggestion(Suggestion)
    /// Something the assistant already recorded, e.g. "Logged moodLevel -1 for 2026-10-14".
    case action(String)
    case failure(String)
    case done
}
