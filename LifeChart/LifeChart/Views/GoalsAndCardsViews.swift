import SwiftData
import SwiftUI

// MARK: - Goals

struct GoalsView: View {
    @Query(filter: #Predicate<Goal> { !$0.isRemoved }, sort: \Goal.createdAt) private var goals: [Goal]
    @Environment(\.modelContext) private var context
    @State private var editing: Goal?
    @State private var creating = false

    var body: some View {
        List {
            ForEach(GoalStatus.allCases) { status in
                let group = goals.filter { $0.status == status }
                if !group.isEmpty {
                    Section(status.title) {
                        ForEach(group) { goal in
                            Button { editing = goal } label: { GoalRow(goal: goal) }
                                .foregroundStyle(.primary)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                group[index].isRemoved = true
                                group[index].touch()
                            }
                            commit(context)
                        }
                    }
                }
            }
            if goals.isEmpty {
                ContentUnavailableView("No goals yet", systemImage: "target",
                                       description: Text("Add one yourself, or work one out with your coach."))
            }
        }
        .navigationTitle("Goals")
        .toolbar {
            Button("Add", systemImage: "plus") { creating = true }
        }
        .sheet(item: $editing) { goal in GoalEditor(goal: goal) }
        .sheet(isPresented: $creating) { GoalEditor(goal: nil) }
    }
}

struct GoalRow: View {
    let goal: Goal

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.title).font(.body.weight(.medium))
                Spacer()
                Text("\(goal.progress)%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(goal.progress), total: 100)
            if !goal.area.isEmpty || goal.targetDateKey != nil {
                Text([goal.area, goal.targetDateKey.map { "by \($0)" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct GoalEditor: View {
    let goal: Goal?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var details = ""
    @State private var area = ""
    @State private var hasTarget = false
    @State private var target = Date.now.adding(days: 30)
    @State private var status = GoalStatus.active
    @State private var progress = 0.0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Goal", text: $title)
                TextField("What success looks like, first steps, link to your Why", text: $details, axis: .vertical)
                    .lineLimit(3 ... 8)
                TextField("Life area (health, work, relationships…)", text: $area)
                Toggle("Target date", isOn: $hasTarget)
                if hasTarget { DatePicker("Target", selection: $target, displayedComponents: .date) }
                Picker("Status", selection: $status) {
                    ForEach(GoalStatus.allCases) { Text($0.title).tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Progress: \(Int(progress))%")
                    Slider(value: $progress, in: 0 ... 100, step: 5)
                }
            }
            .navigationTitle(goal == nil ? "New goal" : "Goal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let goal else { return }
                title = goal.title
                details = goal.details
                area = goal.area
                hasTarget = goal.targetDateKey != nil
                target = goal.targetDateKey.flatMap(DayKey.date(from:)) ?? target
                status = goal.status
                progress = Double(goal.progress)
            }
        }
    }

    private func save() {
        let target = hasTarget ? DayKey.key(for: target) : nil
        let goal = self.goal ?? Goal(title: title)
        goal.title = title
        goal.details = details
        goal.area = area
        goal.targetDateKey = target
        goal.status = status
        goal.progress = Int(progress)
        goal.touch()
        if self.goal == nil { context.insert(goal) }
        commit(context)
        dismiss()
    }
}

// MARK: - My Why

struct MyWhyView: View {
    private var cachedWhy: String {
        get { ProtectedStore.get("myWhy") }
        nonmutating set { ProtectedStore.set("myWhy", newValue) }
    }
    @State private var profile = ProfileDTO()
    @State private var loaded = false
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                TextField("To … so that …", text: $profile.myWhy, axis: .vertical)
                    .lineLimit(3 ... 10)
            } header: {
                Text("My Why")
            } footer: {
                Text("What drives you. Work it out with your coach in \"Find my Why\", then refine it here.")
            }
            Section {
                Button("Save") { Task { await save() } }.disabled(!loaded)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("My Why")
        .task {
            profile.myWhy = cachedWhy
            do {
                profile = try await APIClient.shared.profile()
                cachedWhy = profile.myWhy
                loaded = true
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func save() async {
        do {
            profile = try await APIClient.shared.saveProfile(profile)
            cachedWhy = profile.myWhy
            status = "Saved"
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - Flashcards

struct FlashcardsView: View {
    @Query(filter: #Predicate<Flashcard> { !$0.isRemoved }, sort: \Flashcard.createdAt, order: .reverse)
    private var cards: [Flashcard]
    @Environment(\.modelContext) private var context
    @State private var creating = false

    var body: some View {
        List {
            if cards.isEmpty {
                ContentUnavailableView("No flashcards yet", systemImage: "rectangle.stack",
                                       description: Text("Your coach can write one with you when a familiar pattern shows up."))
            }
            ForEach(cards) { card in
                NavigationLink { FlashcardDetail(card: card) } label: { Text(card.title) }
            }
            .onDelete { offsets in
                for index in offsets {
                    cards[index].isRemoved = true
                    cards[index].touch()
                }
                commit(context)
            }
        }
        .navigationTitle("Flashcards")
        .toolbar { Button("Add", systemImage: "plus") { creating = true } }
        .sheet(isPresented: $creating) {
            NavigationStack { FlashcardDetail(card: nil) }
        }
    }
}

struct FlashcardDetail: View {
    let card: Flashcard?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var trigger = ""
    @State private var schema = ""
    @State private var reality = ""
    @State private var action = ""

    var body: some View {
        Form {
            TextField("Title", text: $title)
            field("Right now I feel… because…", text: $trigger)
            field("This is probably my … schema / mode", text: $schema)
            field("But the reality is…", text: $reality)
            field("So instead I will…", text: $action)
        }
        .navigationTitle(card == nil ? "New flashcard" : "Flashcard")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save).disabled(title.isEmpty)
            }
        }
        .onAppear {
            guard let card else { return }
            title = card.title
            trigger = card.trigger
            schema = card.schemaText
            reality = card.reality
            action = card.action
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        Section(label) {
            TextField(label, text: text, axis: .vertical).lineLimit(2 ... 8)
        }
    }

    private func save() {
        let card = self.card ?? Flashcard(title: title)
        card.title = title
        card.trigger = trigger
        card.schemaText = schema
        card.reality = reality
        card.action = action
        card.touch()
        if self.card == nil { context.insert(card) }
        commit(context)
        dismiss()
    }
}

// MARK: - Life events

struct EventsView: View {
    @Query(filter: #Predicate<LifeEvent> { !$0.isRemoved }, sort: \LifeEvent.dateKey, order: .reverse)
    private var events: [LifeEvent]
    @Environment(\.modelContext) private var context
    @State private var editing: LifeEvent?
    @State private var creating = false

    var body: some View {
        List {
            if events.isEmpty {
                ContentUnavailableView("No life events", systemImage: "flag",
                                       description: Text("Note things that happened, good or bad, that may affect your mood."))
            }
            ForEach(events) { event in
                Button { editing = event } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(event.title).foregroundStyle(.primary)
                            Text(event.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(event.impact > 0 ? "+\(event.impact)" : "\(event.impact)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    events[index].isRemoved = true
                    events[index].touch()
                }
                commit(context)
            }
        }
        .navigationTitle("Life events")
        .toolbar { Button("Add", systemImage: "plus") { creating = true } }
        .sheet(item: $editing) { event in EventEditor(event: event, defaultDate: event.date) }
        .sheet(isPresented: $creating) { EventEditor(event: nil, defaultDate: .now) }
    }
}

struct EventEditor: View {
    let event: LifeEvent?
    let defaultDate: Date
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date = Date.now
    @State private var impact = 0
    @State private var details = ""
    @State private var reflecting = false

    private static let impactLabels = [
        -4: "Very negative", -3: "Negative", -2: "Somewhat negative", -1: "Slightly negative", 0: "Neutral",
        1: "Slightly positive", 2: "Somewhat positive", 3: "Positive", 4: "Very positive",
    ]

    var body: some View {
        NavigationStack {
            Form {
                TextField("What happened?", text: $title)
                DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                Stepper(value: $impact, in: -4 ... 4) {
                    LabeledContent("Impact", value: Self.impactLabels[impact] ?? "")
                }
                TextField("Details", text: $details, axis: .vertical).lineLimit(3 ... 8)
                if event != nil {
                    Section {
                        Button("Reflect on this with my coach", systemImage: "eye") { reflecting = true }
                    } footer: {
                        Text("Explore what this event meant, what you learned and what it says about your purpose.")
                    }
                }
            }
            .navigationTitle(event == nil ? "New life event" : "Life event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationDestination(isPresented: $reflecting) {
                ReflectView(prompt: "I'd like to reflect on this event: \(title) (\(DayKey.key(for: date)), impact \(impact)). \(details)")
            }
            .onAppear {
                date = defaultDate
                guard let event else { return }
                title = event.title
                date = event.date
                impact = event.impact
                details = event.details
            }
        }
    }

    private func save() {
        let event = self.event ?? LifeEvent(dateKey: DayKey.key(for: date), title: title)
        event.title = title
        event.dateKey = DayKey.key(for: date)
        event.impact = impact
        event.details = details
        event.touch()
        if self.event == nil { context.insert(event) }
        commit(context)
        dismiss()
    }
}

/// Opens a "Reflect on an event" conversation that starts with the event.
struct ReflectView: View {
    let prompt: String

    var body: some View {
        ChatView(mode: .reflect, conversationId: nil, initialMessage: prompt)
    }
}
