import SwiftData
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        tabs
            // Hide health data in the app-switcher snapshot.
            .overlay {
                if scenePhase == .background {
                    ZStack {
                        Color(.systemBackground)
                        Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                    }
                    .ignoresSafeArea()
                }
            }
    }

    private var tabs: some View {
        TabView(selection: $router.tab) {
            LogView()
                .tabItem { Label("Today", systemImage: "square.and.pencil") }
                .tag(AppTab.today)
            ChartScreen()
                .tabItem { Label("Chart", systemImage: "chart.bar.xaxis") }
                .tag(AppTab.chart)
            AssistantView()
                .tabItem { Label(AssistantSettings.name, systemImage: "waveform") }
                .tag(AppTab.assistant)
            CoachHomeView()
                .tabItem { Label("Coach", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppTab.coach)
            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
                .tag(AppTab.more)
        }
    }
}

enum AssistantSettings {
    static var name: String {
        let stored = UserDefaults.standard.string(forKey: "assistantName") ?? ""
        return stored.isEmpty ? "Jarvis" : stored
    }
}

/// Small helpers shared by several screens.
extension View {
    func card() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Persists a local change and lets sync and check-ins know about it.
@MainActor
func commit(_ context: ModelContext) {
    try? context.save()
    Task {
        await CheckInService.shared.recordActivity(context)
        await SyncService.shared.sync(context)
    }
}
