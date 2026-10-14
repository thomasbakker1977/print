import Foundation
import SwiftData

/// A locally stored record that syncs with the server.
protocol SyncedModel: PersistentModel {
    associatedtype DTO: Codable
    var updatedAt: Date { get set }
    var needsSync: Bool { get set }
    var isRemoved: Bool { get set }
    var dto: DTO { get }
    func apply(_ dto: DTO)
    static func make(from dto: DTO) -> Self
    static func key(of dto: DTO) -> String
    static func updatedAt(of dto: DTO) -> Int64
    static var pendingDescriptor: FetchDescriptor<Self> { get }
    static func descriptor(forKey key: String) -> FetchDescriptor<Self>
}

extension DayEntry: SyncedModel {
    var dto: DayEntryDTO {
        DayEntryDTO(
            day: dayKey, updatedAt: updatedAt.millis, deleted: isRemoved, moodLevel: moodLevel,
            moodRating: moodRating, mixed: mixed, moodSwitches: moodSwitches, sleepHours: sleepHours,
            anxiety: anxiety, irritability: irritability, menstruating: menstruating, weight: weight,
            notes: notes, doses: doses
        )
    }

    func apply(_ dto: DayEntryDTO) {
        moodLevel = dto.moodLevel
        moodRating = dto.moodRating
        mixed = dto.mixed
        moodSwitches = dto.moodSwitches
        sleepHours = dto.sleepHours
        anxiety = dto.anxiety
        irritability = dto.irritability
        menstruating = dto.menstruating
        weight = dto.weight
        notes = dto.notes
        doses = dto.doses
        isRemoved = dto.deleted
        updatedAt = Date(millis: dto.updatedAt)
        needsSync = false
    }

    static func make(from dto: DayEntryDTO) -> DayEntry {
        let entry = DayEntry(dayKey: dto.day)
        entry.apply(dto)
        return entry
    }

    static func key(of dto: DayEntryDTO) -> String { dto.day }
    static func updatedAt(of dto: DayEntryDTO) -> Int64 { dto.updatedAt }

    static var pendingDescriptor: FetchDescriptor<DayEntry> {
        FetchDescriptor(predicate: #Predicate { $0.needsSync })
    }

    static func descriptor(forKey key: String) -> FetchDescriptor<DayEntry> {
        FetchDescriptor(predicate: #Predicate { $0.dayKey == key })
    }
}

extension Medication: SyncedModel {
    var dto: MedicationDTO {
        MedicationDTO(
            id: id, updatedAt: updatedAt.millis, deleted: isRemoved, name: name, unit: unit,
            defaultDose: defaultDose, active: active, colorIndex: colorIndex
        )
    }

    func apply(_ dto: MedicationDTO) {
        name = dto.name
        unit = dto.unit
        defaultDose = dto.defaultDose
        active = dto.active
        colorIndex = dto.colorIndex
        isRemoved = dto.deleted
        updatedAt = Date(millis: dto.updatedAt)
        needsSync = false
    }

    static func make(from dto: MedicationDTO) -> Medication {
        let medication = Medication(name: dto.name)
        medication.id = dto.id
        medication.apply(dto)
        return medication
    }

    static func key(of dto: MedicationDTO) -> String { dto.id }
    static func updatedAt(of dto: MedicationDTO) -> Int64 { dto.updatedAt }

    static var pendingDescriptor: FetchDescriptor<Medication> {
        FetchDescriptor(predicate: #Predicate { $0.needsSync })
    }

    static func descriptor(forKey key: String) -> FetchDescriptor<Medication> {
        FetchDescriptor(predicate: #Predicate { $0.id == key })
    }
}

extension LifeEvent: SyncedModel {
    var dto: LifeEventDTO {
        LifeEventDTO(
            id: id, updatedAt: updatedAt.millis, deleted: isRemoved, date: dateKey, title: title,
            impact: impact, details: details
        )
    }

    func apply(_ dto: LifeEventDTO) {
        dateKey = dto.date
        title = dto.title
        impact = dto.impact
        details = dto.details
        isRemoved = dto.deleted
        updatedAt = Date(millis: dto.updatedAt)
        needsSync = false
    }

    static func make(from dto: LifeEventDTO) -> LifeEvent {
        let event = LifeEvent(dateKey: dto.date, title: dto.title)
        event.id = dto.id
        event.apply(dto)
        return event
    }

    static func key(of dto: LifeEventDTO) -> String { dto.id }
    static func updatedAt(of dto: LifeEventDTO) -> Int64 { dto.updatedAt }

    static var pendingDescriptor: FetchDescriptor<LifeEvent> {
        FetchDescriptor(predicate: #Predicate { $0.needsSync })
    }

    static func descriptor(forKey key: String) -> FetchDescriptor<LifeEvent> {
        FetchDescriptor(predicate: #Predicate { $0.id == key })
    }
}

extension Flashcard: SyncedModel {
    var dto: FlashcardDTO {
        FlashcardDTO(
            id: id, updatedAt: updatedAt.millis, deleted: isRemoved, title: title, trigger: trigger,
            schemaText: schemaText, reality: reality, action: action, createdAt: createdAt.millis
        )
    }

    func apply(_ dto: FlashcardDTO) {
        title = dto.title
        trigger = dto.trigger
        schemaText = dto.schemaText
        reality = dto.reality
        action = dto.action
        createdAt = Date(millis: dto.createdAt)
        isRemoved = dto.deleted
        updatedAt = Date(millis: dto.updatedAt)
        needsSync = false
    }

    static func make(from dto: FlashcardDTO) -> Flashcard {
        let card = Flashcard(title: dto.title)
        card.id = dto.id
        card.apply(dto)
        return card
    }

    static func key(of dto: FlashcardDTO) -> String { dto.id }
    static func updatedAt(of dto: FlashcardDTO) -> Int64 { dto.updatedAt }

    static var pendingDescriptor: FetchDescriptor<Flashcard> {
        FetchDescriptor(predicate: #Predicate { $0.needsSync })
    }

    static func descriptor(forKey key: String) -> FetchDescriptor<Flashcard> {
        FetchDescriptor(predicate: #Predicate { $0.id == key })
    }
}

extension Goal: SyncedModel {
    var dto: GoalDTO {
        GoalDTO(
            id: id, updatedAt: updatedAt.millis, deleted: isRemoved, title: title, details: details,
            area: area, targetDate: targetDateKey, status: statusRaw, progress: progress,
            createdAt: createdAt.millis
        )
    }

    func apply(_ dto: GoalDTO) {
        title = dto.title
        details = dto.details
        area = dto.area
        targetDateKey = dto.targetDate
        statusRaw = dto.status
        progress = dto.progress
        createdAt = Date(millis: dto.createdAt)
        isRemoved = dto.deleted
        updatedAt = Date(millis: dto.updatedAt)
        needsSync = false
    }

    static func make(from dto: GoalDTO) -> Goal {
        let goal = Goal(title: dto.title)
        goal.id = dto.id
        goal.apply(dto)
        return goal
    }

    static func key(of dto: GoalDTO) -> String { dto.id }
    static func updatedAt(of dto: GoalDTO) -> Int64 { dto.updatedAt }

    static var pendingDescriptor: FetchDescriptor<Goal> {
        FetchDescriptor(predicate: #Predicate { $0.needsSync })
    }

    static func descriptor(forKey key: String) -> FetchDescriptor<Goal> {
        FetchDescriptor(predicate: #Predicate { $0.id == key })
    }
}

extension WearableDay {
    func apply(_ dto: WearableDayDTO) {
        sleepHours = dto.sleepHours
        sleepScore = dto.sleepScore
        restingHeartRate = dto.restingHeartRate
        hrv = dto.hrv
        hrvStatus = dto.hrvStatus
        stressAvg = dto.stressAvg
        bodyBatteryHigh = dto.bodyBatteryHigh
        bodyBatteryLow = dto.bodyBatteryLow
        steps = dto.steps
        updatedAt = Date(millis: dto.updatedAt)
    }
}
