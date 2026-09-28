import SwiftUI
import BackgroundTasks
import UserNotifications

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
                // Never keep the screen on when the app isn't in front.
                UIApplication.shared.isIdleTimerDisabled = false
            default:
                break
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Both must happen before launch finishes, also when iOS wakes the app in the background.
        HealthSync.shared.registerBackgroundTask()
        HealthSync.shared.startObservingIfPaired()
        return true
    }

    // When the app is in front, the page shows its own timer: no banner.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([])
    }

    // Tapping a notification just opens the app where it was.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
