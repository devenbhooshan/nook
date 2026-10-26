import NookCore
import SwiftUI

struct TagPill: View {
    let name: String
    let colorIndex: Int
    var compact = false

    var body: some View {
        let color = Theme.color(colorIndex)
        Text(name)
            .font(.system(size: compact ? 10.5 : 11.5, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 1.5 : 3)
            .background(color.opacity(0.13), in: Capsule())
    }
}

struct Avatar: View {
    let name: String
    let email: String
    var size: CGFloat = 32

    @ObservedObject private var photos = AvatarImages.shared

    var body: some View {
        // Initials always, with the photo on top when there's a real one. A missing or broken photo leaves the initials.
        let color = Theme.color(for: email)
        Text(Addresses.initials(name: name, email: email))
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.15), in: Circle())
            .overlay {
                if let photo = photos.image(for: email) {
                    Image(nsImage: photo)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                }
            }
    }
}

/// A keyboard key, for hints.
struct KeyCap: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct AccountDot: View {
    let colorIndex: Int
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(Theme.color(colorIndex)).frame(width: size, height: size)
    }

    /// A colored dot for AppKit menus, which tint template images. This one isn't a template, so it keeps its color.
    static func menuImage(colorIndex: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor(Theme.color(colorIndex)).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// A borderless icon button. Hovering shows what it does and its shortcut, quickly, in Nook's own tooltip:
/// the system tooltip takes about two seconds to appear, which is too slow to teach anyone a shortcut.
struct IconButton: View {
    let systemImage: String
    let title: String
    var shortcut: String?
    var isActive = false
    /// Where the tooltip lines up. Use `.trailing` for buttons at the right edge of the window, so it stays on screen.
    var tooltipAlignment: HorizontalAlignment = .center
    let action: () -> Void

    @State private var hovering = false
    @State private var showTooltip = DemoData.showAllTooltips

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? Theme.accent : (hovering ? .primary : .secondary))
                .frame(width: 30, height: 28)
                .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
        .task(id: hovering) {
            guard hovering else {
                showTooltip = DemoData.showAllTooltips
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.12)) { showTooltip = true } }
        }
        .overlay(alignment: Alignment(horizontal: tooltipAlignment, vertical: .bottom)) {
            if showTooltip {
                Tooltip(title: title, shortcut: shortcut)
                    .fixedSize()
                    .offset(y: 34)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .zIndex(showTooltip ? 1 : 0)
    }
}

/// A small label with an action's name and shortcut.
struct Tooltip: View {
    let title: String
    var shortcut: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium))
            if let shortcut { KeyCap(shortcut) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

struct ToastView: View {
    let toast: Toast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if toast.isError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(toast.message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            if toast.canUndo {
                Button(action: onUndo) {
                    HStack(spacing: 6) {
                        Text("Undo").font(.system(size: 13, weight: .semibold))
                        KeyCap("Z")
                    }
                }
                .buttonStyle(.quiet)
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

/// The translucent sidebar material.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Reads the hosting `NSWindow` so the key router can tell which window an event belongs to.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Finds the `NSScrollView` a SwiftUI `ScrollView` is built on. Place it inside the scroll view's content.
struct EnclosingScrollViewReader: NSViewRepresentable {
    let onScrollView: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView { onScrollView(scrollView) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// The window's top row. Nook hides the system toolbar, so this leaves room for the traffic lights
/// when the sidebar is hidden, and carries the sidebar toggle.
struct TopBar<Leading: View, Trailing: View>: View {
    @EnvironmentObject private var store: AppStore
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if !store.showSidebar {
                IconButton(systemImage: "sidebar.left", title: "Show sidebar", shortcut: "⌘\\") {
                    withAnimation(.snappy(duration: 0.2)) { store.showSidebar = true }
                }
            }
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.leading, store.showSidebar || store.isFullScreen ? 14 : 80)
        .padding(.trailing, 14)
        // Centered on the traffic lights, which sit about 16pt below the top of the window.
        .frame(height: 32)
        .padding(.top, 1)
        .padding(.bottom, 8)
        // Tooltips hang below the bar; keep it above the content that follows it.
        .zIndex(1)
    }
}

/// Content that spans the window, with the list's side margins.
struct ContentColumn<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
    }
}

// MARK: - Button styles
//
// Every custom control in Nook uses one of these, so they all behave the same way: a pointing-hand cursor
// on hover, visible feedback while pressed, and a clearly dimmed look when disabled.

/// Borderless controls: icon buttons, rows, tabs, chips. Their own views draw any hover background.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration)
    }

    private struct QuietButtonBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .pointerStyle(isEnabled ? .link : nil)
        }
    }
}

/// Text that acts like a link: accent color, underlined on hover.
struct TextLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextLinkBody(configuration: configuration)
    }

    private struct TextLinkBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.accent)
                .underline(hovering && isEnabled)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .pointerStyle(isEnabled ? .link : nil)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

extension ButtonStyle where Self == TextLinkButtonStyle {
    static var textLink: TextLinkButtonStyle { TextLinkButtonStyle() }
}

extension View {
    /// For things that are clickable without being a `Button` (rows with tap gestures): show the pointing hand.
    func clickable() -> some View {
        pointerStyle(.link)
    }
}
