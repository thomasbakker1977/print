import SwiftData
import SwiftUI

struct ChatItem: Identifiable {
    let id = UUID()
    let role: String
    var text: String
    var suggestions: [Suggestion] = []
    var added: Set<Int> = []
    var actions: [String] = []
    var attachment: String?
}

/// One coach conversation, streamed from the homelab server.
@MainActor
final class ChatModel: ObservableObject {
    @Published var items: [ChatItem] = []
    @Published var isStreaming = false
    @Published var error: String?
    @Published private(set) var conversationId: String?
    let mode: CoachMode

    var onReplyFinished: ((String) -> Void)?
    /// Called when the assistant changed data on the server, so the phone can sync.
    var onDataChanged: (() -> Void)?

    init(mode: CoachMode, conversationId: String? = nil) {
        self.mode = mode
        self.conversationId = conversationId
    }

    func load() async {
        guard let conversationId, items.isEmpty else { return }
        do {
            let detail = try await APIClient.shared.conversation(conversationId)
            items = detail.messages.map {
                ChatItem(role: $0.role, text: $0.content, suggestions: $0.suggestions)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func send(_ text: String, spoken: Bool, images: [String] = []) async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isStreaming else { return }
        error = nil
        items.append(ChatItem(role: "user", text: message, attachment: images.first))
        items.append(ChatItem(role: "assistant", text: ""))
        let index = items.count - 1
        isStreaming = true
        defer { isStreaming = false }

        let shareAgenda = UserDefaults.standard.object(forKey: "shareAgenda") as? Bool ?? true
        let agenda = shareAgenda ? await AgendaService.shared.summary() : ""
        let request = ChatRequestDTO(
            conversationId: conversationId,
            message: message,
            mode: mode,
            spoken: spoken,
            localTime: LocalTime.now,
            agenda: agenda,
            assistantName: AssistantSettings.name,
            images: images.map { ImageDTO(mediaType: "image/jpeg", data: $0) }
        )
        do {
            for try await event in APIClient.shared.chat(request) {
                switch event {
                case let .conversation(id):
                    conversationId = id
                case let .text(chunk):
                    items[index].text += chunk
                case let .suggestion(suggestion):
                    items[index].suggestions.append(suggestion)
                case let .action(summary):
                    items[index].actions.append(summary)
                    onDataChanged?()
                case let .failure(message):
                    error = message
                case .done:
                    break
                }
            }
            items[index].text = items[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            onReplyFinished?(items[index].text)
        } catch {
            self.error = error.localizedDescription
            if items[index].text.isEmpty { items.remove(at: index) }
        }
    }
}

struct CoachHomeView: View {
    @State private var conversations: [ConversationDTO] = []
    @State private var error: String?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !APIClient.shared.isConfigured {
                    Section {
                        Label("Connect your homelab server under More → Server to start coaching.",
                              systemImage: "server.rack")
                    }
                }
                Section("Start a conversation") {
                    ForEach(CoachMode.coaching) { mode in
                        NavigationLink(value: ChatRoute(mode: mode, conversationId: nil)) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(mode.title)
                                    Text(mode.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: mode.systemImage)
                            }
                        }
                    }
                }
                Section {
                    NavigationLink { FlashcardsView() } label: { Label("My flashcards", systemImage: "rectangle.stack") }
                    NavigationLink { GoalsView() } label: { Label("My goals", systemImage: "target") }
                    NavigationLink { MyWhyView() } label: { Label("My Why", systemImage: "sparkles") }
                }
                if !conversations.isEmpty {
                    Section("Earlier conversations") {
                        ForEach(conversations) { conversation in
                            NavigationLink(value: ChatRoute(mode: conversation.mode, conversationId: conversation.id)) {
                                VStack(alignment: .leading) {
                                    Text(conversation.title).lineLimit(1)
                                    Text("\(conversation.mode.title) · \(Date(millis: conversation.updatedAt).formatted(.relative(presentation: .named)))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            let removed = offsets.map { conversations[$0] }
                            conversations.remove(atOffsets: offsets)
                            Task { for c in removed { try? await APIClient.shared.deleteConversation(c.id) } }
                        }
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .navigationTitle("Coach")
            .navigationDestination(for: ChatRoute.self) { route in
                ChatView(mode: route.mode, conversationId: route.conversationId)
            }
            .task { await reload() }
            .refreshable { await reload() }
            .onAppear {
                // A photo chosen in "Mood impressions" opens a new conversation.
                if CoachAttachment.pending != nil, path.isEmpty {
                    path.append(ChatRoute(mode: .talk, conversationId: nil))
                }
            }
        }
    }

    private func reload() async {
        guard APIClient.shared.isConfigured else { return }
        do {
            conversations = try await APIClient.shared.conversations()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ChatRoute: Hashable {
    let mode: CoachMode
    let conversationId: String?
}

struct ChatView: View {
    @StateObject private var chat: ChatModel
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var speaker = Speaker()
    @Environment(\.modelContext) private var context
    @AppStorage("readRepliesAloud") private var readAloud = false
    @State private var draft = ""
    @State private var spokenDraft = false
    @State private var attachment: MoodMedia?
    @Query(sort: \MoodMedia.createdAt, order: .reverse) private var media: [MoodMedia]
    private let initialMessage: String?

    init(mode: CoachMode, conversationId: String?, initialMessage: String? = nil) {
        _chat = StateObject(wrappedValue: ChatModel(mode: mode, conversationId: conversationId))
        self.initialMessage = initialMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if chat.items.isEmpty {
                            Text(chat.mode.subtitle)
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach($chat.items) { $item in
                            MessageBubble(item: $item, isStreaming: chat.isStreaming && item.id == chat.items.last?.id)
                                .id(item.id)
                        }
                        if let error = chat.error {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding()
                }
                .onChange(of: chat.items.last?.text) { _, _ in
                    if let last = chat.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            inputBar
        }
        .navigationTitle(chat.mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    readAloud.toggle()
                    if !readAloud { speaker.stop() }
                } label: {
                    Image(systemName: readAloud ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .accessibilityLabel(readAloud ? "Stop reading replies aloud" : "Read replies aloud")
            }
        }
        .task {
            await chat.load()
            chat.onReplyFinished = { [weak speaker] reply in
                if UserDefaults.standard.bool(forKey: "readRepliesAloud") { speaker?.speak(reply) }
            }
            chat.onDataChanged = { Task { await SyncService.shared.sync(context) } }
            if let id = CoachAttachment.pending {
                attachment = media.first { $0.id == id }
                CoachAttachment.pending = nil
            }
            if let initialMessage, chat.items.isEmpty {
                await chat.send(initialMessage, spoken: false)
            }
        }
        .onDisappear {
            speech.stop()
            speaker.stop()
            Task { await CheckInService.shared.recordActivity(context) }
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let attachment {
                HStack {
                    MediaThumbnail(media: attachment).frame(width: 44, height: 44)
                    Text("This photo will be shared with your coach for this message.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { self.attachment = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .accessibilityLabel("Remove photo")
                }
            }
            if speech.isRecording {
                Text(speech.transcript.isEmpty ? "Listening…" : speech.transcript)
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error = speech.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom) {
                Button {
                    if speech.isRecording {
                        speech.stop()
                        draft = speech.transcript
                        spokenDraft = true
                        send()
                    } else {
                        speaker.stop()
                        Task { await speech.start() }
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(speech.isRecording ? .red : .accentColor)
                }
                .accessibilityLabel(speech.isRecording ? "Stop and send" : "Speak")

                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { _, _ in if !speech.isRecording { spokenDraft = false } }

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || chat.isStreaming)
                .accessibilityLabel("Send")
            }
        }
        .padding()
    }

    private func send() {
        let text = draft
        let spoken = spokenDraft
        let images = attachment.flatMap(MediaStore.attachment(for:)).map { [$0] } ?? []
        draft = ""
        spokenDraft = false
        attachment = nil
        Task { await chat.send(text, spoken: spoken, images: images) }
    }
}

struct MessageBubble: View {
    @Binding var item: ChatItem
    let isStreaming: Bool
    @Environment(\.modelContext) private var context
    @State private var error: String?

    private var isUser: Bool { item.role == "user" }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
            if let attachment = item.attachment, let data = Data(base64Encoded: attachment), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if item.text.isEmpty && isStreaming {
                ProgressView().padding(12)
            } else if !item.text.isEmpty {
                Text(LocalizedStringKey(item.text))
                    .textSelection(.enabled)
                    .padding(12)
                    .background(isUser ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 16))
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.text }
                        if !isUser {
                            Button("Save as My Why", systemImage: "sparkles") { saveWhy(item.text) }
                        }
                    }
            }
            ForEach(item.actions, id: \.self) { action in
                Label(action, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            ForEach(Array(item.suggestions.enumerated()), id: \.offset) { index, suggestion in
                SuggestionCard(suggestion: suggestion, added: item.added.contains(index)) {
                    add(suggestion, index: index)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func add(_ suggestion: Suggestion, index: Int) {
        do {
            switch suggestion.kind {
            case "task":
                try AgendaService.shared.addReminder(suggestion)
                if let due = suggestion.due.flatMap(AgendaService.parse) {
                    CheckInService.shared.addFollowUp(title: suggestion.title, at: due.addingTimeInterval(2 * 3600))
                }
            case "event":
                try AgendaService.shared.addEvent(suggestion)
                if let end = suggestion.end.flatMap(AgendaService.parse) {
                    CheckInService.shared.addFollowUp(title: suggestion.title, at: end.addingTimeInterval(15 * 60))
                }
            case "flashcard":
                let card = Flashcard(title: suggestion.title, trigger: suggestion.trigger ?? "",
                                     schemaText: suggestion.schema ?? "", reality: suggestion.reality ?? "",
                                     action: suggestion.action ?? "")
                card.touch()
                context.insert(card)
                commit(context)
            case "goal":
                let goal = Goal(title: suggestion.title, details: suggestion.details ?? "",
                                area: suggestion.area ?? "", targetDateKey: suggestion.targetDate)
                goal.touch()
                context.insert(goal)
                commit(context)
            default:
                return
            }
            item.added.insert(index)
            error = nil
            Task { await CheckInService.shared.reschedule(context) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveWhy(_ text: String) {
        Task {
            guard var profile = try? await APIClient.shared.profile() else { return }
            profile.myWhy = text
            if let saved = try? await APIClient.shared.saveProfile(profile) {
                UserDefaults.standard.set(saved.myWhy, forKey: "myWhy")
            }
        }
    }
}

struct SuggestionCard: View {
    let suggestion: Suggestion
    let added: Bool
    let add: () -> Void

    private var icon: String {
        switch suggestion.kind {
        case "task": "checklist"
        case "event": "calendar.badge.plus"
        case "flashcard": "rectangle.stack.badge.plus"
        default: "target"
        }
    }

    private var actionTitle: String {
        switch suggestion.kind {
        case "task": "Add to Reminders"
        case "event": "Add to Calendar"
        case "flashcard": "Save flashcard"
        default: "Add goal"
        }
    }

    private var detail: String? {
        switch suggestion.kind {
        case "task": suggestion.due
        case "event": [suggestion.start, suggestion.end].compactMap { $0 }.joined(separator: " – ")
        case "flashcard": suggestion.reality
        default: suggestion.details
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(suggestion.title, systemImage: icon).font(.subheadline.bold())
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
            Button(added ? "Added" : actionTitle, systemImage: added ? "checkmark" : "plus", action: add)
                .buttonStyle(.bordered)
                .disabled(added)
        }
        .card()
    }
}
