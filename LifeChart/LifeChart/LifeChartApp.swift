import AppIntents
import BackgroundTasks
import SwiftData
import SwiftUI
import UserNotifications

enum AppTab: Hashable {
    case today, chart, coach, assistant, goals, more
}

/// App-wide navigation, so notifications and Siri can open the right screen.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    @Published var tab: AppTab = .today
    /// A message the assistant sends as soon as its screen appears.
    @Published var assistantPrompt: String?
    /// Start listening hands-free when the assistant appears.
    @Published var startListening = false

    func openAssistant(prompt: String? = nil, listen: Bool = false) {
        assistantPrompt = prompt
        startListening = listen && prompt == nil
        tab = .assistant
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let kind = response.notification.request.content.userInfo["kind"] as? String
        await MainActor.run {
            AppRouter.shared.openAssistant(prompt: kind.flatMap { CheckInService.prompts[$0] })
        }
    }
}

@main
struct LifeChartApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    static let refreshTaskId = "nl.lifechart.app.refresh"  // also in Info.plist

    /// iOS encrypts app data at rest; it stays readable after first unlock so
    /// background refresh can plan check-ins.
    static let opened: Result<ModelContainer, Error> = Result {
        // On a fresh install this folder does not exist yet; creating it first
        // avoids Core Data's noisy (but harmless) recovery messages.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let schema = Schema(allModelTypes)
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)])
    }

    /// Never crash on a database problem: show what happened and keep the data file.
    let container: ModelContainer = (try? LifeChartApp.opened.get())
        ?? (try! ModelContainer(for: Schema(allModelTypes),
                                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))

    var body: some Scene {
        WindowGroup {
            Group {
                if case let .failure(error) = Self.opened {
                    ContentUnavailableView(
                        "LifeChart could not open its data",
                        systemImage: "exclamationmark.triangle",
                        description: Text("Your data has not been deleted. Please update the app or contact support.\n\n\(error.localizedDescription)")
                    )
                } else {
                    ContentView()
                }
            }
            .environmentObject(AppRouter.shared)
            .environmentObject(SyncService.shared)
            .environmentObject(AgendaService.shared)
            // Hide health data in the app switcher.
            .overlay {
                if scenePhase != .active {
                    ZStack {
                        Color(.systemBackground)
                        Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            let context = container.mainContext
            switch phase {
            case .active:
                Task {
                    await SyncService.shared.sync(context)
                    await CheckInService.shared.recordActivity(context)
                }
            case .background:
                Task { await SyncService.shared.sync(context) }
                Self.scheduleRefresh()
            default:
                break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskId)) { [container] in
            await Self.refresh(container)
        }
    }

    /// Background refresh: pull new Garmin data and changes, then re-plan check-ins.
    @MainActor
    static func refresh(_ container: ModelContainer) async {
        scheduleRefresh()
        let context = container.mainContext
        await SyncService.shared.sync(context)
        await CheckInService.shared.reschedule(context)
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = .now.addingTimeInterval(3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}

// MARK: - Siri & Shortcuts

struct TalkToAssistantIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to my assistant"
    static let description = IntentDescription("Opens LifeChart's assistant and starts listening.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openAssistant(listen: true)
        return .result()
    }
}

struct MorningBriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "Morning briefing"
    static let description = IntentDescription("Your sleep, today's agenda and goals, read aloud.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openAssistant(prompt: "Give me my morning briefing.")
        return .result()
    }
}

struct EveningCheckInIntent: AppIntent {
    static let title: LocalizedStringResource = "Evening check-in"
    static let description = IntentDescription("Log your day by talking it through.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.openAssistant(prompt: "Let's do my evening check-in.")
        return .result()
    }
}

struct LifeChartShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToAssistantIntent(),
            phrases: ["Talk to \(.applicationName)", "Open my assistant in \(.applicationName)"],
            shortTitle: "Assistant",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: MorningBriefingIntent(),
            phrases: ["Morning briefing in \(.applicationName)", "Start my day with \(.applicationName)"],
            shortTitle: "Morning briefing",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: EveningCheckInIntent(),
            phrases: ["Evening check-in in \(.applicationName)", "Log my day in \(.applicationName)"],
            shortTitle: "Evening check-in",
            systemImageName: "moon.stars"
        )
    }
}
