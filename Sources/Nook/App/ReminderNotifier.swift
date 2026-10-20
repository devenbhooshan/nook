import AppKit
import NookCore
import UserNotifications

/// Shows a notification when a reminder goes off. Clicking it opens the conversation.
final class ReminderNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ReminderNotifier()

    /// Notifications need an app bundle (`swift run` has none), and demo mode never asks for the real app's permission.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, !CommandLine.arguments.contains("--demo") else { return nil }
        return .current()
    }

    func install() {
        center?.delegate = self
    }

    /// Asked the first time you set a reminder, not at launch: that's when it's clear why Nook wants to notify you.
    func requestPermission() {
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
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
