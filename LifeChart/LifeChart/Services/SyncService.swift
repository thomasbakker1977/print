import Foundation
import SwiftData

/// Pushes local edits to the homelab server and pulls changes made elsewhere
/// (other devices, the assistant, Garmin imports).
@MainActor
final class SyncService: ObservableObject {
    static let shared = SyncService()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?

    private let api = APIClient.shared

    private var cursor: Int {
        get { UserDefaults.standard.integer(forKey: "syncCursor") }
        set { UserDefaults.standard.set(newValue, forKey: "syncCursor") }
    }

    /// Forget the server position, e.g. after pointing the app at a new server.
    func resetCursor() {
        cursor = 0
    }

    func sync(_ context: ModelContext) async {
        guard api.isConfigured, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let entries = try context.fetch(DayEntry.pendingDescriptor)
            let medications = try context.fetch(Medication.pendingDescriptor)
            let events = try context.fetch(LifeEvent.pendingDescriptor)
            let flashcards = try context.fetch(Flashcard.pendingDescriptor)
            let goals = try context.fetch(Goal.pendingDescriptor)

            // Remember what was sent, so edits made while the request is in
            // flight stay marked for the next sync.
            let sent: [(any SyncedModel, Date)] =
                entries.map { ($0, $0.updatedAt) } + medications.map { ($0, $0.updatedAt) }
                + events.map { ($0, $0.updatedAt) } + flashcards.map { ($0, $0.updatedAt) }
                + goals.map { ($0, $0.updatedAt) }

            let request = SyncRequestDTO(
                cursor: cursor,
                entries: entries.map(\.dto),
                medications: medications.map(\.dto),
                events: events.map(\.dto),
                flashcards: flashcards.map(\.dto),
                goals: goals.map(\.dto)
            )
            let response = try await api.sync(request)

            for (model, stamp) in sent where model.updatedAt == stamp {
                var model = model
                model.needsSync = false
            }
            try merge(response.entries, as: DayEntry.self, into: context)
            try merge(response.medications, as: Medication.self, into: context)
            try merge(response.events, as: LifeEvent.self, into: context)
            try merge(response.flashcards, as: Flashcard.self, into: context)
            try merge(response.goals, as: Goal.self, into: context)
            try mergeWearables(response.wearables, into: context)
            try context.save()

            cursor = response.cursor
            lastSync = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func merge<Model: SyncedModel>(_ dtos: [Model.DTO], as _: Model.Type, into context: ModelContext) throws {
        for dto in dtos {
            let key = Model.key(of: dto)
            if let local = try context.fetch(Model.descriptor(forKey: key)).first {
                // A newer local edit that has not been sent yet wins.
                if local.needsSync && local.updatedAt.millis > Model.updatedAt(of: dto) { continue }
                local.apply(dto)
            } else {
                context.insert(Model.make(from: dto))
            }
        }
    }

    private func mergeWearables(_ dtos: [WearableDayDTO], into context: ModelContext) throws {
        for dto in dtos {
            let key = dto.day
            let descriptor = FetchDescriptor<WearableDay>(predicate: #Predicate { $0.dayKey == key })
            if let local = try context.fetch(descriptor).first {
                local.apply(dto)
            } else {
                let day = WearableDay(dayKey: dto.day)
                day.apply(dto)
                context.insert(day)
            }
        }
    }
}
