import AppKit
import NookCore
import UserNotifications

/// Shows a notification when a reminder goes off. Clicking it opens the conversation.
final class ReminderNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ReminderNotifier()

    /// Notifications need an app bundle (`swift run` has none), and demo mode never asks for the real app's permission.
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && !CommandLine.arguments.contains("--demo")
    }

    private var center: UNUserNotificationCenter? { available ? .current() : nil }

    /// Whether macOS shows the Dock badge. Once an app is in the notification system, the badge needs badge
    /// permission; Settings offers a way to turn it on when it's off.
    @MainActor @Published private(set) var badgesAllowed = true

    /// Asks at launch for notifications with badges (so the unread count on the Dock icon shows),
    /// and reads back what you allowed.
    func install() {
        guard let center else { return }
        center.delegate = self
        // Asked every launch: it only prompts the first time, and it adds badges for anyone who allowed
        // notifications before Nook asked for them (macOS otherwise treats the app as never badging).
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in self.refreshBadgeSetting() }
    }

    /// Reads the badge permission again, e.g. after you change it in System Settings.
    func refreshBadgeSetting() {
        center?.getNotificationSettings { settings in
            self.publishBadgeSetting(settings.badgeSetting)
        }
    }

    private func publishBadgeSetting(_ setting: UNNotificationSetting) {
        DispatchQueue.main.async {
            self.badgesAllowed = setting == .enabled
            // The badge may have been set before permission arrived; set it again so it shows.
            AppStore.current?.refreshDockBadge()
        }
    }

    /// Kept for callers that ask when you set a reminder; permission is already requested at launch.
    func requestPermission() {
        refreshBadgeSetting()
    }

    /// Opens Nook's page in System Settings → Notifications.
    @MainActor func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        NSWorkspace.shared.open(url)
    }

    func notify(_ reminder: Reminder, subject: String, from: String) {
        let content = UNMutableNotificationContent()
        let subject = subject.isEmpty ? "(no subject)" : subject
        switch reminder.kind {
        case .remind:
            content.title = "Reminder: \(subject)"
            content.body = from.isEmpty ? "From your inbox" : "From \(from)"
        case .followUp:
            content.title = "No reply: \(subject)"
            content.body = reminder.since.map { "You wrote \($0.formatted(.relative(presentation: .named)))" } ?? "Nobody has replied yet"
        }
        content.sound = .default
        content.userInfo = ["account": reminder.account, "threadId": reminder.threadId]
        guard let center else {
            if CommandLine.arguments.contains("--demo") {
                print("demo: notification=\(content.title) | \(content.body)")
                fflush(stdout)
            }
            return
        }
        let request = UNNotificationRequest(identifier: "reminder-\(reminder.account)-\(reminder.threadId)", content: content, trigger: nil)
        center.add(request) { _ in }
    }

    /// Show it even while Nook is in front: you asked to be reminded.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let account = info["account"] as? String, let threadId = info["threadId"] as? String {
            DispatchQueue.main.async {
                AppStore.current?.showMainWindow()
                AppStore.current?.handle(NookURL.open(account: account, threadId: threadId).url)
            }
        }
        completionHandler()
    }
}
