import AppKit
import NookCore

/// Routes single-key shortcuts to the store. It listens to key events in the main window and stays
/// out of the way while you're typing in a text field, a sheet, or the command palette.
@MainActor
final class KeyRouter {
    private weak var store: AppStore?
    private var interpreter = ShortcutInterpreter()
    private var monitor: Any?

    init(store: AppStore) {
        self.store = store
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors are called on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let store, let window = event.window, window === store.mainWindow, window.attachedSheet == nil else { return false }
        // During onboarding the inbox isn't on screen, so shortcuts would act on mail nobody can see.
        guard store.onboardingStep == .done else { return false }
        guard !store.showPalette, store.draft == nil else { return false }
        if let responder = window.firstResponder as? NSTextView, responder.isEditable { return false }

        // Command-key shortcuts belong to the menu bar.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }

        if store.showHelp {
            store.showHelp = false
            return true
        }

        let reading = store.openThread != nil
        // In a conversation, the arrow keys scroll the message instead of switching threads.
        if reading, [ShortcutInterpreter.KeyCode.upArrow, ShortcutInterpreter.KeyCode.downArrow].contains(event.keyCode) {
            return false
        }

        guard let command = interpreter.interpret(
            characters: event.characters ?? "", keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift)
        ) else {
            // A pending "g" swallows its key, so it doesn't beep.
            return interpreter.isAwaitingSequence
        }
        // Holding a key repeats movement only. A held "e" or Delete must not archive or trash a dozen threads.
        if event.isARepeat, !command.repeatsWhenHeld { return true }
        perform(command, store: store)
        return true
    }

    private func perform(_ command: KeyCommand, store: AppStore) {
        switch command {
        case .next: store.move(by: 1)
        case .previous: store.move(by: -1)
        case .open: store.open()
        case .close: store.back()
        case .archive: store.archive()
        case .trash: store.trash()
        case .toggleStar: store.toggleStar()
        case .toggleRead: store.toggleRead()
        case .reply: store.reply(.reply)
        case .replyAll: store.reply(.replyAll)
        case .forward: store.reply(.forward)
        case .compose: store.compose()
        case .search: store.focusSearch()
        case .commandPalette: store.openPalette()
        case .tagPicker: if store.currentThread != nil { store.openPalette(.tags) }
        case .help: store.showHelp = true
        case .undo: store.undo()
        case .toggleUnreadFilter: store.toggleUnreadOnly()
        case .nextSplit: store.cycleSplit(by: 1)
        case .previousSplit: store.cycleSplit(by: -1)
        case .go(let mailbox): store.setMailbox(mailbox)
        }
    }
}
