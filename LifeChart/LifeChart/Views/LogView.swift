import PhotosUI
import SwiftData
import SwiftUI

struct LogView: View {
    @State private var day = Date.now.startOfDay

    private var isToday: Bool { Calendar.current.isDateInToday(day) }

    var body: some View {
        NavigationStack {
            DayEditor(dayKey: DayKey.key(for: day))
                .id(DayKey.key(for: day))
                .navigationTitle(isToday ? "Today" : day.formatted(.dateTime.weekday(.wide).day().month()))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { day = day.adding(days: -1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Previous day")
                    }
                    ToolbarItem(placement: .principal) {
                        DatePicker("Day", selection: Binding(get: { day }, set: { day = $0.startOfDay }),
                                   in: ...Date.now, displayedComponents: .date)
                            .labelsHidden()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { day = day.adding(days: 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(isToday)
                            .accessibilityLabel("Next day")
                    }
                }
        }
    }
}

/// Finds or creates the entry for one day.
struct DayEditor: View {
    let dayKey: String
    @Environment(\.modelContext) private var context
    @Query private var matches: [DayEntry]

    init(dayKey: String) {
        self.dayKey = dayKey
        _matches = Query(filter: #Predicate<DayEntry> { $0.dayKey == dayKey })
    }

    var body: some View {
        if let entry = matches.first {
            EntryForm(entry: entry)
        } else {
            ProgressView().task {
                // Pull first, so a day logged elsewhere (another device, the
                // assistant) is not replaced by a blank local copy.
                await SyncService.shared.sync(context)
                guard matches.isEmpty else { return }
                context.insert(DayEntry(dayKey: dayKey))
                try? context.save()
            }
        }
    }
}

struct EntryForm: View {
    @Bindable var entry: DayEntry
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Medication> { $0.active && !$0.isRemoved }, sort: \Medication.name)
    private var medications: [Medication]
    @StateObject private var dictation = SpeechRecognizer()
    @State private var showingEventEditor = false

    var body: some View {
        Form {
            Section {
                MoodScalePicker(selection: bind(\.moodLevel))
            } header: {
                Text("Mood · NIMH Life Chart")
            } footer: {
                if let level = entry.moodLevel.flatMap(MoodLevel.init) {
                    Text(level.impairment)
                } else {
                    Text("Rate how much your mood affected your functioning today.")
                }
            }

            Section("Self-rating") {
                Toggle("Rate 0–100", isOn: Binding(
                    get: { entry.moodRating != nil },
                    set: { entry.moodRating = $0 ? 50 : nil; entry.touch() }
                ))
                if entry.moodRating != nil {
                    VStack {
                        Slider(value: Binding(get: { entry.moodRating ?? 50 },
                                              set: { entry.moodRating = $0; entry.touch() }),
                               in: 0 ... 100, step: 1)
                        HStack {
                            Text("Most depressed")
                            Spacer()
                            Text("\(Int(entry.moodRating ?? 50))").bold()
                            Spacer()
                            Text("Most elevated")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Toggle("Mixed state", isOn: bind(\.mixed))
                Stepper("Mood switches: \(entry.moodSwitches)", value: bind(\.moodSwitches), in: 0 ... 20)
            }

            Section("Sleep & symptoms") {
                Stepper(value: Binding(get: { entry.sleepHours ?? 0 },
                                       set: { entry.sleepHours = $0; entry.touch() }),
                        in: 0 ... 24, step: 0.5) {
                    LabeledContent("Sleep", value: entry.sleepHours.map { "\($0.formatted()) h" } ?? "—")
                }
                SeverityPicker(title: "Anxiety", value: bind(\.anxiety))
                SeverityPicker(title: "Irritability", value: bind(\.irritability))
                Toggle("Menstruating", isOn: bind(\.menstruating))
                LabeledContent("Weight") {
                    TextField("kg", value: bind(\.weight), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            WatchSection(dayKey: entry.dayKey) { hours in
                entry.sleepHours = hours
                entry.touch()
            }

            Section("Medication") {
                if medications.isEmpty {
                    Text("Add your medication under More → Medication.")
                        .foregroundStyle(.secondary)
                }
                ForEach(medications) { medication in
                    DoseRow(entry: entry, medication: medication)
                }
            }

            MoodMediaSection(dayKey: entry.dayKey)

            Section {
                TextField("How was your day?", text: bind(\.notes), axis: .vertical)
                    .lineLimit(3 ... 10)
                Button {
                    if dictation.isRecording {
                        dictation.stop()
                        appendDictation()
                    } else {
                        Task { await dictation.start() }
                    }
                } label: {
                    Label(dictation.isRecording ? "Stop dictation" : "Dictate",
                          systemImage: dictation.isRecording ? "stop.circle.fill" : "mic")
                }
                if dictation.isRecording, !dictation.transcript.isEmpty {
                    Text(dictation.transcript).foregroundStyle(.secondary)
                }
                if let error = dictation.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Notes")
            }

            Section {
                Button("Add life event for this day", systemImage: "flag") { showingEventEditor = true }
            }
        }
        .sheet(isPresented: $showingEventEditor) {
            EventEditor(event: nil, defaultDate: entry.date)
        }
        // Save a few seconds after the last change, and when leaving the day.
        .task(id: entry.updatedAt) {
            guard entry.needsSync else { return }
            try? await Task.sleep(for: .seconds(3))
            commit(context)
        }
        .onDisappear {
            if dictation.isRecording {
                dictation.stop()
                appendDictation()
            }
            if entry.needsSync { commit(context) }
        }
    }

    private func appendDictation() {
        let text = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entry.notes = entry.notes.isEmpty ? text : entry.notes + "\n" + text
        entry.touch()
    }

    private func bind<Value>(_ keyPath: ReferenceWritableKeyPath<DayEntry, Value>) -> Binding<Value> {
        Binding(
            get: { entry[keyPath: keyPath] },
            set: { entry[keyPath: keyPath] = $0; entry.touch() }
        )
    }
}

struct MoodScalePicker: View {
    @Binding var selection: Int?

    var body: some View {
        ForEach(MoodLevel.descending) { level in
            Button {
                selection = selection == level.rawValue ? nil : level.rawValue
            } label: {
                HStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(level.color)
                        .frame(width: 28, height: 20)
                        .overlay(Text(level.rawValue > 0 ? "+\(level.rawValue)" : "\(level.rawValue)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white))
                    Text(level.title).foregroundStyle(.primary)
                    Spacer()
                    if selection == level.rawValue {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .accessibilityAddTraits(selection == level.rawValue ? .isSelected : [])
        }
    }
}

struct SeverityPicker: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(0 ..< Severity.labels.count, id: \.self) { index in
                Text(Severity.labels[index]).tag(index)
            }
        }
    }
}

struct DoseRow: View {
    @Bindable var entry: DayEntry
    let medication: Medication

    private var index: Int? { entry.doses.firstIndex { $0.medicationId == medication.id } }

    var body: some View {
        VStack(alignment: .leading) {
            Toggle(isOn: Binding(
                get: { index != nil },
                set: { taken in
                    if taken {
                        entry.doses.append(Dose(medicationId: medication.id, amount: medication.defaultDose))
                    } else {
                        entry.doses.removeAll { $0.medicationId == medication.id }
                    }
                    entry.touch()
                }
            )) {
                HStack {
                    Circle().fill(Palette.medication(medication.colorIndex)).frame(width: 10, height: 10)
                    Text(medication.name)
                }
            }
            if let index {
                HStack {
                    Text("Dose").foregroundStyle(.secondary)
                    TextField("Amount", value: Binding(
                        get: { entry.doses[index].amount },
                        set: { entry.doses[index].amount = $0; entry.touch() }
                    ), format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                    Text(medication.unit).foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
    }
}

/// Read-only Garmin metrics for the day.
struct WatchSection: View {
    let dayKey: String
    let useSleep: (Double) -> Void
    @Query private var days: [WearableDay]

    init(dayKey: String, useSleep: @escaping (Double) -> Void) {
        self.dayKey = dayKey
        self.useSleep = useSleep
        _days = Query(filter: #Predicate<WearableDay> { $0.dayKey == dayKey })
    }

    var body: some View {
        if let day = days.first {
            Section("From your watch") {
                if let sleep = day.sleepHours {
                    LabeledContent("Sleep", value: "\(sleep.formatted()) h" + (day.sleepScore.map { " · score \($0)" } ?? ""))
                    Button("Use watch sleep") { useSleep(sleep) }
                }
                if let hrv = day.hrv {
                    LabeledContent("Overnight HRV", value: "\(hrv) ms" + (day.hrvStatus.map { " · \($0.lowercased())" } ?? ""))
                }
                if let rhr = day.restingHeartRate { LabeledContent("Resting heart rate", value: "\(rhr) bpm") }
                if let stress = day.stressAvg { LabeledContent("Average stress", value: "\(stress)") }
                if let high = day.bodyBatteryHigh {
                    LabeledContent("Body Battery", value: "\(day.bodyBatteryLow ?? 0)–\(high)")
                }
                if let steps = day.steps { LabeledContent("Steps", value: steps.formatted()) }
            }
        }
    }
}
