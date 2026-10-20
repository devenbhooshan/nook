import NookCore
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if store.onboardingStep != .done {
                OnboardingView()
                    .transition(.opacity)
            } else {
                // A hand-rolled split rather than NavigationSplitView: the sidebar is optional and starts hidden,
                // and the content runs edge to edge under the transparent title bar.
                HStack(spacing: 0) {
                    if store.showSidebar {
                        SidebarView()
                            .frame(width: 232)
                            .background(VisualEffectBackground(material: .sidebar))
                            .overlay(alignment: .trailing) { Divider().opacity(0.6) }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    ZStack {
                        if let thread = store.openThread {
                            ReaderView(thread: thread)
                                .id(thread.id)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 12)), removal: .opacity))
                        } else {
                            ThreadListView()
                                .transition(.opacity)
                        }
                    }
                    .animation(.snappy(duration: 0.18), value: store.openThread?.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor))
                }
                .ignoresSafeArea(edges: .top)
            }
        }
        .overlay {
            if store.showPalette {
                CommandPaletteView()
                    .transition(.opacity)
            }
        }
        .overlay {
            if let thread = store.reminderTarget {
                ReminderPickerView(thread: thread)
                    .transition(.opacity)
            }
        }
        .overlay {
            if store.showHelp {
                ShortcutHelpView()
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast) { store.undo() }
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.15), value: store.showPalette)
        .animation(.snappy(duration: 0.15), value: store.showHelp)
        .animation(.snappy(duration: 0.15), value: store.reminderTarget?.id)
        .sheet(item: $store.draft) { draft in
            ComposeView(draft: draft)
        }
        .background(WindowReader { store.attach(to: $0) })
        .tint(Theme.accent)
        .onAppear {
            store.openSettingsHandler = { openSettings() }
            store.openMainWindowHandler = { openWindow(id: "main") }
            store.start()
        }
        .onOpenURL { store.handle($0) }
    }
}
