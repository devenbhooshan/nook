import AppKit
import NookCore
import SwiftUI

/// The suggestions under a To or Cc field while you type an address.
///
/// ↑ and ↓ move through them, Return or Tab takes one, Escape puts them away. Keys reach the list through
/// a local monitor that's only installed while it's showing, so the field behaves normally the rest of the time.
@MainActor
final class RecipientSuggestions: ObservableObject {
    @Published private(set) var items: [Contact] = []
    @Published var selected = 0
    private var accept: ((Contact) -> Void)?
    /// The text Escape was pressed on, so the list stays away until you type something else.
    private var dismissedText: String?
    private var text = ""
    private var monitor: Any?

    func update(text: String, book: ContactBook, accept: @escaping (Contact) -> Void) {
        self.text = text
        guard text != dismissedText else { return show([]) }
        dismissedText = nil
        let (entered, typing) = Addresses.splitTyping(text)
        let present = Set(Addresses.parseList(entered).map { $0.email.lowercased() })
        self.accept = accept
        show(book.suggestions(for: typing, excluding: present))
    }

    func clear() {
        dismissedText = nil
        show([])
    }

    func choose(_ contact: Contact) {
        accept?(contact)
    }

    private func show(_ contacts: [Contact]) {
        if contacts != items {
            items = contacts
            selected = 0
        }
        if contacts.isEmpty {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        } else if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard !items.isEmpty else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (125, []): // ↓
            selected = (selected + 1) % items.count
        case (126, []): // ↑
            selected = (selected - 1 + items.count) % items.count
        case (36, []), (76, []), (48, []): // Return, Enter, Tab
            choose(items[min(selected, items.count - 1)])
        case (53, []): // Escape: hide the list, and keep the sheet open.
            dismissedText = text
            show([])
        default:
            return false
        }
        return true
    }
}

/// The dropdown itself.
struct RecipientSuggestionList: View {
    @ObservedObject var suggestions: RecipientSuggestions

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(suggestions.items.enumerated()), id: \.element.email) { index, contact in
                Button {
                    suggestions.choose(contact)
                } label: {
                    HStack(spacing: 10) {
                        Avatar(name: contact.name, email: contact.email, size: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(contact.name.isEmpty ? contact.email : contact.name)
                                .font(.system(size: 13, weight: .medium))
                            if !contact.name.isEmpty {
                                Text(contact.email)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(index == suggestions.selected ? Theme.accent.opacity(0.13) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
                .help("Add \(contact.email) (↵)")
                .onHover { inside in if inside { suggestions.selected = index } }
            }
        }
        .padding(5)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
