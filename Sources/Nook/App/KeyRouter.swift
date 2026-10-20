import AppKit
import NookCore

/// Routes single-key shortcuts to the store. It listens to key events in the main window and stays
/// out of the way while you're typing in a text field, a sheet, or the command palette.
///
/// It also handles the reader's keyboard scrolling and the swipe back to the list.
@MainActor
final class KeyRouter {
    private weak var store: AppStore?
    private var interpreter = ShortcutInterpreter()
    private var monitor: Any?
    private var swipeMonitor: Any?
    private var backSwipe = BackSwipe()
    private var swipeHandled = false
    /// Where an in-flight scroll animation is headed, so quick presses add up instead of starting from mid-animation.
    private var scrollTarget: (scrollView: NSScrollView, fromTop: Double)?

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
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { self?.handleSwipe(event) }
            return event
        }
    }

    /// Two-finger swipe right on a trackpad (or one finger on a Magic Mouse) goes back, as in Safari.
    /// Follows the "Swipe between pages" setting in System Settings.
    private func handleSwipe(_ event: NSEvent) {
        guard let store, store.openThread != nil, let window = event.window ?? NSApp.keyWindow, window === store.mainWindow,
              window.attachedSheet == nil, store.draft == nil, !store.showPalette, store.reminderTarget == nil else { return }

        if event.type == .swipe {
            // Three-finger swipes, when the system is set to use them. A positive deltaX is the "back" direction.
            if event.deltaX > 0 { store.closeThread() }
            return
        }
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return }
        switch event.phase {
        case .began:
            backSwipe.begin()
            swipeHandled = false
        case .changed:
            guard !swipeHandled else { return }
            // Measure the fingers' direction, whatever the natural-scrolling setting.
            let direction: Double = event.isDirectionInvertedFromDevice ? 1 : -1
            if backSwipe.add(deltaX: event.scrollingDeltaX * direction, deltaY: event.scrollingDeltaY * direction) {
                swipeHandled = true
                store.closeThread()
            }
        default:
            break
        }
    }

    /// Scrolls the open conversation. Returns false when there's nothing to scroll.
    private func scrollReader(_ event: NSEvent, store: AppStore) -> Bool {
        guard let scrollView = store.readerScrollView, let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let viewport = clip.bounds.height
        guard let step = ReaderScroll.forKey(event.keyCode, shift: event.modifierFlags.contains(.shift), viewportHeight: viewport) else {
            return false
        }
        let contentHeight = document.frame.height
        // Distance from the top, whichever way the document's coordinates run.
        let current = document.isFlipped ? clip.bounds.origin.y : contentHeight - viewport - clip.bounds.origin.y
        let fromTop = scrollTarget.flatMap { $0.scrollView === scrollView ? $0.fromTop : nil } ?? current
        let target = step.offset(from: fromTop, contentHeight: contentHeight, viewportHeight: viewport)
        let y = document.isFlipped ? target : contentHeight - viewport - target
        scrollTarget = (scrollView, target)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = event.isARepeat ? 0.06 : 0.12
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                scrollView.reflectScrolledClipView(clip)
                // A newer press may have retargeted it; only the last animation clears the target.
                if self?.scrollTarget?.scrollView === scrollView, self?.scrollTarget?.fromTop == target { self?.scrollTarget = nil }
            }
        }
        return true
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let store, let window = event.window, window === store.mainWindow, window.attachedSheet == nil else { return false }
        // During onboarding the inbox isn't on screen, so shortcuts would act on mail nobody can see.
        guard store.onboardingStep == .done else { return false }
        guard !store.showPalette, store.reminderTarget == nil, store.draft == nil else { return false }
        if let responder = window.firstResponder as? NSTextView, responder.isEditable { return false }

        // Command-key shortcuts belong to the menu bar. Option is allowed: some keyboard layouts need it to type "#".
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return false }
        guard let characters = ShortcutInterpreter.shortcutCharacters(
            characters: event.characters,
            ignoringModifiers: event.charactersIgnoringModifiers,
            option: event.modifierFlags.contains(.option)
        ) else { return false }

        if store.showHelp {
            store.showHelp = false
            return true
        }

        // In a conversation, the arrow keys, Space, Page Up/Down, Home and End scroll it. j and k still switch threads.
        if store.openThread != nil, !interpreter.isAwaitingSequence,
           ReaderScroll.forKey(event.keyCode, shift: false, viewportHeight: 0) != nil {
            return scrollReader(event, store: store)
        }

        guard let command = interpreter.interpret(
            characters: characters, keyCode: event.keyCode, shift: event.modifierFlags.contains(.shift)
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
        case .remind: store.showReminderPicker()
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
