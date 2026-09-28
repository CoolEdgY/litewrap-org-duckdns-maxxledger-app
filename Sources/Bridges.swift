import UIKit
import SafariServices
import UserNotifications

/// Small native helpers the web page can call through the `litewrap` bridge.
enum UIHelpers {
    static var keyWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }

    static func topViewController() -> UIViewController? {
        var vc = keyWindow?.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        return vc
    }

    /// Other websites open in an in-app Safari sheet.
    static func openInSafari(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let top = topViewController() else {
            UIApplication.shared.open(url)
            return
        }
        top.present(SFSafariViewController(url: url), animated: true)
    }
}

/// {type:'haptic', style:'light'|'medium'|'heavy'|'success'|'warning'|'error'}
enum Haptics {
    static func play(_ style: String) {
        switch style {
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

/// Local notifications: {type:'notify'}, {type:'notifyCancel'}, {type:'notifyPermission'}
enum Notifier {
    static func schedule(id: String, at: Date, title: String, body: String, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false)
        // Same identifier replaces the earlier one.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancel(_ id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }
}
