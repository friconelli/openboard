import AppKit
import UserNotifications

/// macOS notifications: Claude finished, Claude asks for a permission, a terminal session went
/// from working to waiting. Clicking one opens the chat. Like OpenChamber, nothing is shown for
/// the chat you are looking at while the app is in front.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let enabledKey = "notificationsEnabled"
    /// Set by the app: called with a chat id when a notification is clicked.
    var onOpenChat: ((String) -> Void)?
    /// The chat currently on screen, to stay quiet about it while the app is active.
    var visibleChatID: String?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter needs a real app bundle (not `swift run`).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func start() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(chatID: String, title: String, body: String, sound: Bool = true) {
        guard isEnabled, let center else { return }
        if NSApp.isActive && visibleChatID == chatID { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["chat": chatID]
        content.threadIdentifier = chatID
        if sound { content.sound = .default }
        center.add(UNNotificationRequest(identifier: "\(chatID)-\(UUID().uuidString)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["chat"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let id { self.onOpenChat?(id) }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}
