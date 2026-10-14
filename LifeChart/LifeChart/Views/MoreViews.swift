import SwiftData
import SwiftUI

struct MoreView: View {
    @AppStorage("crisisPlan") private var crisisPlan = ""

    var body: some View {
        NavigationStack {
            List {
                if !crisisPlan.isEmpty {
                    Section {
                        NavigationLink { CrisisPlanView() } label: {
                            Label("My crisis plan", systemImage: "cross.case").foregroundStyle(.red)
                        }
                    }
                }
                Section("Me") {
                    NavigationLink { ProfileEditor() } label: { Label("Profile & care plan", systemImage: "person.text.rectangle") }
                    NavigationLink { MyWhyView() } label: { Label("My Why", systemImage: "sparkles") }
                    NavigationLink { GoalsView() } label: { Label("Goals", systemImage: "target") }
                    NavigationLink { FlashcardsView() } label: { Label("Flashcards", systemImage: "rectangle.stack") }
                }
                Section("Life chart") {
                    NavigationLink { MedicationsView() } label: { Label("Medication", systemImage: "pills") }
                    NavigationLink { EventsView() } label: { Label("Life events", systemImage: "flag") }
                    NavigationLink { MoodGalleryView() } label: { Label("Mood impressions", systemImage: "photo.stack") }
                }
                Section("Settings") {
                    NavigationLink { ServerSettingsView() } label: { Label("Server & Cloudflare", systemImage: "server.rack") }
                    NavigationLink { AssistantSettingsView() } label: { Label("Assistant & voice", systemImage: "waveform") }
                    NavigationLink { CalendarSettingsView() } label: { Label("Calendar & reminders", systemImage: "calendar") }
                    NavigationLink { CheckInSettingsView() } label: { Label("Check-ins", systemImage: "bell.badge") }
                }
                Section {
                    NavigationLink { AboutView() } label: { Label("About & safety", systemImage: "info.circle") }
                }
            }
            .navigationTitle("More")
        }
    }
}

// MARK: - Profile

struct ProfileEditor: View {
    @AppStorage("profileName") private var cachedName = ""
    @AppStorage("crisisPlan") private var cachedCrisisPlan = ""
    @State private var profile = ProfileDTO()
    @State private var loaded = false
    @State private var status: String?

    var body: some View {
        Form {
            Section {
                TextField("Your name", text: $profile.name)
            } footer: {
                Text("Your coach and assistant will call you by this name.")
            }
            section("About me", "What would you like your coach to know about you?", $profile.aboutMe)
            section("Care & treatment history", "Diagnoses, treatments, care team… in your own words.", $profile.careHistory)
            section("Signaleringsplan", "Early warning signs per phase and the actions you agreed with your care team.", $profile.warningSigns)
            section("Crisis plan", "Who to contact in a crisis (names, numbers) and what helps you.", $profile.crisisPlan)
            section("Coach personality", "How your coach should come across, e.g. a personality profile you like. Energetic Tony Robbins-style is the default.", $profile.coachStyle)
            Section {
                Button("Save") { Task { await save() } }.disabled(!loaded)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            } footer: {
                Text("Stored on your own server and used by your coach as background. Not shared with anyone else.")
            }
        }
        .navigationTitle("Profile")
        .task { await load() }
    }

    private func section(_ title: String, _ prompt: String, _ text: Binding<String>) -> some View {
        Section(title) {
            TextField(prompt, text: text, axis: .vertical).lineLimit(3 ... 14)
        }
    }

    private func load() async {
        do {
            profile = try await APIClient.shared.profile()
            cache()
            loaded = true
        } catch {
            status = error.localizedDescription
        }
    }

    private func save() async {
        do {
            profile = try await APIClient.shared.saveProfile(profile)
            cache()
            status = "Saved"
        } catch {
            status = error.localizedDescription
        }
    }

    private func cache() {
        cachedName = profile.name
        cachedCrisisPlan = profile.crisisPlan
        UserDefaults.standard.set(profile.myWhy, forKey: "myWhy")
    }
}

/// Always available offline, because it matters most when things are hard.
struct CrisisPlanView: View {
    @AppStorage("crisisPlan") private var crisisPlan = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(crisisPlan).font(.title3).textSelection(.enabled)
                Divider()
                Text("In acute danger, call 112. You can always call or chat with 113 Zelfmoordpreventie: 113 or 0800-0113 (free).")
                    .font(.callout)
                HStack {
                    Link("Call 113", destination: URL(string: "tel:113")!).buttonStyle(.borderedProminent)
                    Link("Call 0800-0113", destination: URL(string: "tel:08000113")!).buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle("Crisis plan")
    }
}

// MARK: - Server

struct ServerSettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var sync: SyncService
    @State private var url = APIClient.shared.serverURL
    @State private var token = APIClient.shared.token
    @State private var clientId = APIClient.shared.accessClientId
    @State private var clientSecret = APIClient.shared.accessClientSecret
    @State private var status: String?
    @State private var garmin: GarminStatusDTO?

    var body: some View {
        Form {
            Section {
                TextField("https://lifechart.example.nl", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API token", text: $token)
            } header: {
                Text("Server")
            } footer: {
                Text("Your Cloudflare hostname for the LifeChart backend, and the LIFECHART_API_TOKEN from its .env file.")
            }
            Section {
                TextField("Client ID", text: $clientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Client secret", text: $clientSecret)
            } header: {
                Text("Cloudflare Access service token")
            } footer: {
                Text("Zero Trust → Access → Service credentials. Add it to the Access policy of your LifeChart application.")
            }
            Section {
                Button("Save & test connection") { Task { await saveAndTest() } }
                Button("Sync now") { Task { await sync.sync(context) } }
                    .disabled(sync.isSyncing)
                if let last = sync.lastSync {
                    LabeledContent("Last sync", value: last.formatted(.relative(presentation: .named)))
                }
                if let error = sync.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if let garmin {
                Section("Garmin") {
                    LabeledContent("Connected", value: garmin.enabled ? "Yes" : "Not configured on server")
                    if let last = garmin.lastSync {
                        LabeledContent("Last import", value: Date(millis: last).formatted(.relative(presentation: .named)))
                    }
                    if let error = garmin.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                    if garmin.enabled {
                        Button("Import from Garmin now") {
                            Task {
                                self.garmin = try? await APIClient.shared.refreshGarmin()
                                await sync.sync(context)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Server & Cloudflare")
        .task { garmin = try? await APIClient.shared.status().garmin }
    }

    private func saveAndTest() async {
        let changedServer = url != APIClient.shared.serverURL
        APIClient.shared.serverURL = url
        APIClient.shared.token = token
        APIClient.shared.accessClientId = clientId
        APIClient.shared.accessClientSecret = clientSecret
        if changedServer { sync.resetCursor() }
        do {
            let server = try await APIClient.shared.status()
            garmin = server.garmin
            status = "Connected. Coach \(server.coach ? "ready" : "not configured (ANTHROPIC_API_KEY)")."
            await sync.sync(context)
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - Assistant & voice

struct AssistantSettingsView: View {
    @AppStorage("assistantName") private var name = "Jarvis"
    @AppStorage("speechLanguage") private var language = SpeechLanguage.preferred.rawValue
    @AppStorage("readRepliesAloud") private var readAloud = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            } header: {
                Text("Assistant name")
            } footer: {
                Text("Say \"Hey Siri, talk to LifeChart\" to start the assistant hands-free.")
            }
            Section("Voice") {
                Picker("Speech language", selection: $language) {
                    ForEach(SpeechLanguage.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Read coach replies aloud", isOn: $readAloud)
            }
        }
        .navigationTitle("Assistant & voice")
    }
}

// MARK: - Calendar

struct CalendarSettingsView: View {
    @EnvironmentObject private var agenda: AgendaService
    @AppStorage("shareAgenda") private var shareAgenda = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Calendar", value: agenda.calendarAccess ? "Allowed" : "No access")
                LabeledContent("Reminders", value: agenda.reminderAccess ? "Allowed" : "No access")
                if !agenda.calendarAccess || !agenda.reminderAccess {
                    Button("Allow access") { Task { await agenda.requestAccess() } }
                }
            } footer: {
                Text("Works with every account on your iPhone: iCloud, Google, Outlook/Exchange.")
            }
            Section {
                Toggle("Share my agenda with the coach", isOn: $shareAgenda)
            } footer: {
                Text("A short summary of the next 7 days and open reminders is sent with each coach message so it can help you plan. Nothing is added without your tap.")
            }
        }
        .navigationTitle("Calendar & reminders")
        .onAppear { agenda.refreshStatus() }
    }
}

// MARK: - Check-ins

struct CheckInSettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var enabled = CheckInService.shared.isEnabled
    @State private var reminderTime = Date.now.startOfDay.addingTimeInterval(TimeInterval(CheckInService.shared.logReminderMinutes * 60))
    @State private var permission: String?

    var body: some View {
        Form {
            Section {
                Toggle("Check-ins", isOn: $enabled)
                DatePicker("Evening log reminder", selection: $reminderTime, displayedComponents: .hourAndMinute)
            } footer: {
                Text("Your assistant checks in when you have been quiet for a day or more, when today isn't logged in the evening, after tasks and calendar blocks you planned with the coach, and when your watch shows several short nights. No notifications between 22:00 and 08:00.")
            }
            Section {
                Button("Allow notifications") {
                    Task {
                        let granted = await CheckInService.shared.requestPermission()
                        permission = granted ? "Notifications allowed" : "Turn on notifications for LifeChart in Settings"
                        await CheckInService.shared.reschedule(context)
                    }
                }
                if let permission { Text(permission).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Check-ins")
        .onChange(of: enabled) { _, value in apply { CheckInService.shared.isEnabled = value } }
        .onChange(of: reminderTime) { _, value in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
            apply { CheckInService.shared.logReminderMinutes = (parts.hour ?? 21) * 60 + (parts.minute ?? 0) }
        }
    }

    private func apply(_ change: () -> Void) {
        change()
        Task { await CheckInService.shared.reschedule(context) }
    }
}

// MARK: - Medication

struct MedicationsView: View {
    @Query(filter: #Predicate<Medication> { !$0.isRemoved }, sort: \Medication.name) private var medications: [Medication]
    @Environment(\.modelContext) private var context
    @State private var editing: Medication?
    @State private var creating = false

    var body: some View {
        List {
            ForEach(medications) { medication in
                Button { editing = medication } label: {
                    HStack {
                        Circle().fill(Palette.medication(medication.colorIndex)).frame(width: 12, height: 12)
                        VStack(alignment: .leading) {
                            Text(medication.name).foregroundStyle(.primary)
                            Text("\(medication.defaultDose.formatted()) \(medication.unit)\(medication.active ? "" : " · stopped")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    medications[index].isRemoved = true
                    medications[index].touch()
                }
                commit(context)
            }
        }
        .overlay {
            if medications.isEmpty {
                ContentUnavailableView("No medication", systemImage: "pills",
                                       description: Text("Add what you take so you can log it each day."))
            }
        }
        .navigationTitle("Medication")
        .toolbar { Button("Add", systemImage: "plus") { creating = true } }
        .sheet(item: $editing) { MedicationEditor(medication: $0) }
        .sheet(isPresented: $creating) { MedicationEditor(medication: nil) }
    }
}

struct MedicationEditor: View {
    let medication: Medication?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var unit = "mg"
    @State private var dose = 0.0
    @State private var active = true
    @State private var colorIndex = 0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                LabeledContent("Usual dose") {
                    TextField("0", value: $dose, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Unit", text: $unit)
                Toggle("Currently taking", isOn: $active)
                Picker("Colour", selection: $colorIndex) {
                    ForEach(Palette.medication.indices, id: \.self) { index in
                        Circle().fill(Palette.medication(index)).frame(width: 16, height: 16).tag(index)
                    }
                }
                .pickerStyle(.navigationLink)
            }
            .navigationTitle(medication == nil ? "New medication" : "Medication")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let medication else { return }
                name = medication.name
                unit = medication.unit
                dose = medication.defaultDose
                active = medication.active
                colorIndex = medication.colorIndex
            }
        }
    }

    private func save() {
        let medication = self.medication ?? Medication(name: name)
        medication.name = name
        medication.unit = unit
        medication.defaultDose = dose
        medication.active = active
        medication.colorIndex = colorIndex
        medication.touch()
        if self.medication == nil { context.insert(medication) }
        commit(context)
        dismiss()
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        List {
            Section("LifeChart") {
                Text("Track your mood with the NIMH Life Chart Method, combine it with your Garmin data, and get energetic, action-oriented coaching in the spirit of Tony Robbins, grounded in Mentalization-Based Treatment, Schema Therapy and NLP coaching techniques. The coach calms down automatically when your chart shows elevated mood or short sleep.")
            }
            Section("Important") {
                Text("Your coach is an AI. It supports, but does not replace, your care team, therapist or GP. Talk to your prescriber before changing medication.")
                Text("In acute danger call 112. For suicidal thoughts, call 113 or 0800-0113 (free), or chat at 113.nl.")
            }
            Section("Your data") {
                Text("Your life chart lives on this iPhone and on your own homelab server, reached only through your Cloudflare tunnel. Photos and videos stay on this iPhone. Coach messages are processed by Anthropic's Claude API.")
            }
        }
        .navigationTitle("About & safety")
    }
}
