import AppKit
import NookCore
import SwiftUI

@main
struct NookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore.live()

    init() {
        // Command-line values like the "3" in `--open 3` would otherwise be treated as files to open, and an app
        // launched to open files doesn't show its window.
        // Only ever registered, never saved: a saved copy of this key makes macOS's file picker service drop its
        // connection to Nook, so attaching files silently fails. Clear one if an earlier build or `defaults write` left it.
        UserDefaults.standard.removeObject(forKey: "NSTreatUnknownArgumentsAsOpen")
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": false])
    }

    var body: some Scene {
        Window("Nook", id: "main") {
            RootView()
                .environmentObject(store)
                // Demo mode keeps its settings in a separate suite, so it never changes your real ones.
                .defaultAppStorage(store.defaults)
                .frame(minWidth: 860, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1140, height: 720)
        // Always open the inbox at launch. Otherwise quitting with the window closed brings Nook back with
        // no window, and nothing for the Dock icon to reopen.
        .restorationBehavior(.disabled)
        .commands { NookCommands(store: store) }

        Settings {
            SettingsView()
                .environmentObject(store)
                // Demo mode keeps its settings in a separate suite, so it never changes your real ones.
                .defaultAppStorage(store.defaults)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for the life of the app so App Nap doesn't stall the sync timer while the window is hidden.
    private var syncActivity: NSObjectProtocol?

    /// Set before launch finishes, so clicking a reminder that launched Nook still opens it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        ReminderNotifier.shared.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run` behave like a normal app with a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        syncActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Keeping mail in sync"
        )
        // The window normally starts the store when it appears. If it hasn't appeared after a moment, start syncing
        // anyway: a mail app has to sync with no window open. (Starting before the window exists stops SwiftUI showing it.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { AppStore.current?.start() }
    }

    /// Files written for Quick Look and dragging are copies of your mail; don't leave them behind.
    func applicationWillTerminate(_ notification: Notification) {
        AttachmentFiles.clearTemporaryFiles()
    }

    /// A mail app keeps syncing with its window closed. Quit with ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open brings the inbox back. SwiftUI doesn't reopen a closed
    /// `Window` scene on its own, so ask it to through the `openWindow` action the root view handed over.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            MainActor.assumeIsolated { AppStore.current?.showMainWindow() }
        }
        return true
    }
}

struct NookCommands: Commands {
    @ObservedObject var store: AppStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { store.compose() }
                .keyboardShortcut("n")
        }
        CommandMenu("Mail") {
            Button("Command Palette…") { store.openPalette() }
                .keyboardShortcut("k")
            Button("Search") { store.focusSearch() }
                .keyboardShortcut("f")
            Button("Sync Now") { store.syncNow() }
                .keyboardShortcut("r")
            Divider()
            Button("All Accounts") { store.setScope(nil) }
                .keyboardShortcut("0")
            ForEach(Array(store.accounts.prefix(9).enumerated()), id: \.element.email) { index, account in
                Button(account.email) { store.setScope(account.email) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
            Button(store.showSidebar ? "Hide Sidebar" : "Show Sidebar") {
                withAnimation(.snappy(duration: 0.2)) { store.showSidebar.toggle() }
            }
            .keyboardShortcut("\\")
            Button("Keyboard Shortcuts") { store.showHelp = true }
                .keyboardShortcut("/")
        }
    }
}
