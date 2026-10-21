import AppKit
import NookCore
import UserNotifications

/// Shows a notification when a reminder goes off. Clicking it opens the conversation.
final class ReminderNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ReminderNotifier()

    /// Notifications need an app bundle (`swift run` has none), and demo mode never asks for the real app's permission.
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && !CommandLine.arguments.contains("--demo")
    }

    /// Set once Nook has asked to notify you. Until then it leaves the notification system alone: once an app uses it,
    /// macOS shows that app's Dock badge only with badge permission, so touching it early would hide the unread count.
    private static let askedKey = "notifications.asked"

    private var center: UNUserNotificationCenter? {
        available && UserDefaults.standard.bool(forKey: Self.askedKey) ? .current() : nil
    }

    func install() {
        center?.delegate = self
    }

    /// Asked the first time you set a reminder, not at launch: that's when it's clear why Nook wants to notify you.
    /// Badges are part of it, so the unread count on the Dock icon keeps showing.
    func requestPermission() {
        guard available else { return }
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            // The badge was set before permission arrived; set it again so it shows.
            DispatchQueue.main.async { AppStore.current?.refreshDockBadge() }
        }
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
