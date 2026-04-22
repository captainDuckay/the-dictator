import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    private var permissionRequested = false

    func requestAuthorizationIfNeeded() {
        guard !permissionRequested else { return }
        permissionRequested = true

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLogger.error(AppLogger.notifications, "Notification permission request failed: \(error.localizedDescription)")
                return
            }

            AppLogger.info(AppLogger.notifications, "Notification permission granted: \(granted)")
        }
    }

    func show(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                AppLogger.error(AppLogger.notifications, "Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }
}
