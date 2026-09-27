import SwiftUI
import BackgroundTasks

@main
struct LiteWrapApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Opening the app always catches up on the last 7 days.
                HealthSync.shared.syncRecent(days: 7)
            case .background:
                HealthSync.shared.scheduleRefresh()
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Both must happen before launch finishes, also when iOS wakes the app in the background.
        HealthSync.shared.registerBackgroundTask()
        HealthSync.shared.startObservingIfPaired()
        return true
    }
}
