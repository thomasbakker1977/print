import SwiftData
import SwiftUI

/// The hands-free assistant: listen → think → speak → listen again.
struct AssistantView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.modelContext) private var context
    @StateObject private var chat = ChatModel(mode: .assistant, conversationId: AssistantView.todaysConversation)
    @StateObject private var speech = SpeechRecognizer()
    @StateObject private var speaker = Speaker()
    @State private var handsFree = false

    /// One assistant conversation per day keeps context without growing forever.
    static var todaysConversation: String? {
        let stored = UserDefaults.standard.dictionary(forKey: "assistantConversation") as? [String: String]
        return stored?[DayKey.today]
    }

    private enum Phase { case idle, listening, thinking, speaking }

    private var phase: Phase {
        if speech.isRecording { return .listening }
        if chat.isStreaming { return .thinking }
        if speaker.isSpeaking { return .speaking }
        return .idle
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                transcript
                orb
                Text(statusText).font(.callout).foregroundStyle(.secondary)
                if let error = speech.errorMessage ?? chat.error {
                    Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                quickActions
            }
            .padding()
            .navigationTitle(AssistantSettings.name)
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            chat.onReplyFinished = { reply in
                speaker.speak(reply) {
                    if handsFree { listen() }
                }
            }
            chat.onDataChanged = { Task { await SyncService.shared.sync(context) } }
            speech.onSilence = { text in
                Task { await send(text) }
            }
            await chat.load()
            handleRouter()
        }
        .onChange(of: router.assistantPrompt) { _, _ in handleRouter() }
        .onChange(of: router.startListening) { _, _ in handleRouter() }
        .onChange(of: chat.conversationId) { _, id in
            guard let id else { return }
            UserDefaults.standard.set([DayKey.today: id], forKey: "assistantConversation")
        }
        .onDisappear { stopAll() }
    }

    private var statusText: String {
        switch phase {
        case .idle: handsFree ? "Paused" : "Tap to talk to \(AssistantSettings.name)"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .speaking: "Speaking… tap to interrupt"
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach($chat.items) { $item in
                        MessageBubble(item: $item, isStreaming: chat.isStreaming && item.id == chat.items.last?.id)
                            .id(item.id)
                    }
                    if speech.isRecording, !speech.transcript.isEmpty {
                        Text(speech.transcript)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .id("live")
                    }
                }
            }
            .onChange(of: chat.items.last?.text) { _, _ in
                if let last = chat.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var orb: some View {
        Button {
            switch phase {
            case .idle:
                handsFree = true
                listen()
            case .speaking:
                speaker.stop()
                listen()
            case .listening, .thinking:
                stopAll()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(orbColor.gradient)
                    .frame(width: 120, height: 120)
                    .scaleEffect(phase == .listening ? 1.08 : 1)
                    .animation(phase == .listening ? .easeInOut(duration: 0.8).repeatForever() : .default, value: phase)
                Image(systemName: orbIcon).font(.system(size: 40)).foregroundStyle(.white)
            }
        }
        .accessibilityLabel(statusText)
    }

    private var orbColor: Color {
        switch phase {
        case .idle: .accentColor
        case .listening: .red
        case .thinking: .purple
        case .speaking: .teal
        }
    }

    private var orbIcon: String {
        switch phase {
        case .idle: "waveform"
        case .listening: "mic.fill"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        }
    }

    private var quickActions: some View {
        HStack {
            quick("Morning briefing", "sun.max") { await send("Give me my morning briefing.", spoken: true) }
            quick("Evening check-in", "moon.stars") { await send("Let's do my evening check-in.", spoken: true) }
            quick("How am I doing?", "chart.line.uptrend.xyaxis") {
                await send("How have I been doing this week compared to my goals?", spoken: true)
            }
        }
    }

    private func quick(_ title: String, _ icon: String, action: @escaping () async -> Void) -> some View {
        Button {
            handsFree = true
            Task { await action() }
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .labelStyle(VerticalLabelStyle())
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(phase == .thinking)
    }

    private func listen() {
        speaker.stop()
        Task { await speech.start(silenceTimeout: 1.6) }
    }

    private func send(_ text: String, spoken: Bool = true) async {
        speech.stop()
        await chat.send(text, spoken: spoken)
    }

    private func stopAll() {
        handsFree = false
        speech.stop()
        speaker.stop()
    }

    private func handleRouter() {
        if let prompt = router.assistantPrompt {
            router.assistantPrompt = nil
            handsFree = true
            Task { await send(prompt) }
        } else if router.startListening {
            router.startListening = false
            handsFree = true
            listen()
        }
    }
}

struct VerticalLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon.font(.title3)
            configuration.title
        }
    }
}
