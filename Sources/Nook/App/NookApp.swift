import AppKit
import NookCore
import SwiftUI

@main
struct NookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore.live()

    var body: some Scene {
        Window("Nook", id: "main") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 1140, height: 720)
        .commands { NookCommands(store: store) }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run` behave like a normal app with a Dock icon and menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
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
