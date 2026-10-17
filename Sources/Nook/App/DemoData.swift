import AppKit
import NookCore

/// `Nook --demo` runs on an in-memory store filled with sample mail, with no Google account and no network.
/// Handy for working on the UI and for screenshots.
@MainActor
enum DemoData {
    static func store() -> AppStore {
        let repo = MailRepository(db: try! Database(path: ":memory:"))
        seed(repo)
        return AppStore(repo: repo, secrets: MemorySecretStore(), makeService: { _ in OfflineGmail() }, isDemo: true)
    }

    /// In demo mode: `--open <n>` opens the nth conversation, `--compose` starts a reply, `--reply-body <text>` opens a reply prefilled the way an assistant's draft arrives, `--to <text>` starts a new message with that typed in To,
    /// `--palette` shows the command palette, `--unread` turns on the unread filter, `--split <tag>` opens a tab,
    /// `--onboarding [connect|tagging]` shows an onboarding step (the assistant step by default), `--client-help` opens the Google client steps,
    /// `--keys down,space,…` presses keys once the window is up (in the compose sheet, when one is open), `--swipe` swipes back,
    /// `--notices` shows the signed-out and photo notices, `--snapshot <file.png>` saves the window, even on another Space, and `--dark` forces dark mode. Used for screenshots and for checking input handling.
    /// Queues real key events, so they go through the same monitors as typing.
    private static func pressKeys(_ keys: [String], in store: AppStore) {
        guard let main = store.mainWindow else { return }
        let window = main.attachedSheet ?? main
        let codes: [String: (UInt16, String)] = [
            "down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "space": (49, " "),
            "pagedown": (121, "\u{F72D}"), "pageup": (116, "\u{F72C}"), "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"),
            "j": (38, "j"), "k": (40, "k"), "esc": (53, "\u{1B}"),
            "return": (36, "\r"), "tab": (48, "\t"),
        ]
        for key in keys {
            guard let (code, characters) = codes[key] else { continue }
            for down in [true, false] {
                guard let event = NSEvent.keyEvent(
                    with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code
                ) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// Prints what's open and how far it's scrolled, so input handling can be checked without a screenshot.
    private static func reportReader(_ store: AppStore) {
        let offset = store.readerScrollView.map { Int($0.contentView.bounds.origin.y) }.map(String.init) ?? "none"
        print("demo: open=\(store.openThread?.subject ?? "none") scroll=\(offset)")
        fflush(stdout)
    }

    /// Draws the window (or its sheet) into a PNG. Unlike `screencapture`, this works wherever the window is.
    private static func snapshot(_ store: AppStore, to path: String) {
        guard let main = store.mainWindow, let view = (main.attachedSheet ?? main).contentView?.superview,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("demo: snapshot=\(path)")
        fflush(stdout)
    }

    /// Queues a two-finger swipe to the right over the window, as a trackpad sends it.
    private static func swipeBack(in store: AppStore) {
        guard let window = store.mainWindow, let screen = window.screen else { return }
        // CGEvent locations are measured from the top of the main screen.
        let center = CGPoint(x: window.frame.midX, y: screen.frame.maxY - window.frame.midY)
        // Fingers moving right without natural scrolling, which reports negative deltas.
        let phases: [(phase: Int64, dx: Int32)] = [(1, 0), (2, -30), (2, -40), (2, -50), (4, 0)]
        for step in phases {
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: step.dx, wheel3: 0) else { continue }
            cgEvent.location = center
            cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: step.phase)
            cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(step.dx))
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if let event = NSEvent(cgEvent: cgEvent) { NSApp.postEvent(event, atStart: false) }
        }
    }

    static func applyLaunchOptions(to store: AppStore) {
        let arguments = CommandLine.arguments
        guard arguments.contains("--demo") else { return }
        if arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if let flag = arguments.firstIndex(of: "--open"), arguments.indices.contains(flag + 1),
           let index = Int(arguments[flag + 1]), store.threads.indices.contains(index) {
            store.open(store.threads[index])
        }
        if arguments.contains("--compose") { store.reply(.reply) }
        if let flag = arguments.firstIndex(of: "--reply-body"), arguments.indices.contains(flag + 1), let thread = store.currentThread {
            // The way an assistant's draft arrives: a nook:// link that opens a prefilled reply.
            store.handle(NookURL.reply(account: thread.account, threadId: thread.threadId, body: arguments[flag + 1], all: false).url)
        }
        if let flag = arguments.firstIndex(of: "--to"), arguments.indices.contains(flag + 1) {
            store.handle(NookURL.compose(from: nil, to: arguments[flag + 1], cc: "", subject: "", body: "").url)
        }
        if arguments.contains("--palette") { store.openPalette() }
        if arguments.contains("--unread") { store.toggleUnreadOnly() }
        if arguments.contains("--settings") {
            // Same path as the "Sign in again…" button, so it can be checked without clicking.
            DispatchQueue.main.async { store.openSettings() }
        }
        if let flag = arguments.firstIndex(of: "--split"), arguments.indices.contains(flag + 1) {
            store.setSplit(.tag(arguments[flag + 1]))
        }
        if let flag = arguments.firstIndex(of: "--keys"), arguments.indices.contains(flag + 1) {
            let keys = arguments[flag + 1].split(separator: ",").map(String.init)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { pressKeys(keys, in: store) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { reportReader(store) }
        }
        if arguments.contains("--swipe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { swipeBack(in: store) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { reportReader(store) }
        }
        if arguments.contains("--notices") {
            // After the first sync, which would otherwise clear them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { store.showDemoAccountProblems() }
        }
        if let flag = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(flag + 1) {
            let path = arguments[flag + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { snapshot(store, to: path) }
        }
        if let flag = arguments.firstIndex(of: "--onboarding") {
            let name = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : ""
            switch name {
            case "connect": store.showDemoOnboarding(.connectAccount)
            case "tagging": store.restartOnboarding(at: .setUpTagging)
            default: store.restartOnboarding(at: .connectAssistant)
            }
        }
    }

    /// `--windowed` (any mode) leaves full screen, so screenshots of the window work.
    static func applyWindowOptions(to window: NSWindow) {
        if CommandLine.arguments.contains("--demo"), CommandLine.arguments.contains("--close-window") {
            // Closes the window shortly after launch, to check the app keeps running without it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { window.performClose(nil) }
        }
        guard CommandLine.arguments.contains("--windowed") else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        window.setContentSize(NSSize(width: 1140, height: 720))
        window.center()
    }

    /// `--demo --tooltips` shows every icon tooltip at once, for checking them in screenshots.
    static let showAllTooltips = CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--tooltips")

    /// `--demo --client-help` opens the Google client steps, for screenshots of the first onboarding step.
    static let showClientHelp = CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--client-help")

    static func seed(_ repo: MailRepository) {
        let personal = "sam@hey.example"
        let work = "sam@acme.example"
        try? repo.addAccount(email: personal, name: "Sam Rivera")
        try? repo.addAccount(email: work, name: "Sam Rivera")
        try? repo.setHistoryId("1", for: personal)
        try? repo.setHistoryId("1", for: work)

        let now = Date()
        func message(
            _ id: String, _ account: String, thread: String? = nil, from: (String, String), subject: String, body: String,
            hoursAgo: Double, unread: Bool = false, starred: Bool = false, inbox: Bool = true, html: String = "", tags: [String] = []
        ) -> (MailMessage, [String]) {
            var labels: Set<String> = []
            if inbox { labels.insert(SystemLabel.inbox) }
            if unread { labels.insert(SystemLabel.unread) }
            if starred { labels.insert(SystemLabel.starred) }
            let message = MailMessage(
                id: id, account: account, threadId: thread ?? id, fromName: from.0, fromEmail: from.1,
                to: "Sam Rivera <\(account)>", subject: subject, snippet: String(body.replacingOccurrences(of: "\n", with: " ").prefix(120)),
                bodyHTML: html, bodyText: body, date: now.addingTimeInterval(-hoursAgo * 3600), labels: labels,
                messageIdHeader: "<\(id)@demo.example>"
            )
            return (message, tags)
        }

        let samples: [(MailMessage, [String])] = [
            message("w1", work, thread: "launch", from: ("Priya Natarajan", "priya@acme.example"), subject: "Launch checklist for Thursday",
                    body: "Hey Sam,\n\nCan you confirm the release notes are final by tomorrow noon? Legal signed off on the privacy copy this morning.\n\nAlso — do we still want the waitlist email to go out at 9am PT?\n\nThanks,\nPriya", hoursAgo: 0.4, unread: true, tags: ["Needs Reply"]),
            message("w0", work, thread: "launch", from: ("Sam Rivera", work), subject: "Launch checklist for Thursday",
                    body: "Draft notes are in the doc. I'll do a final pass tonight.", hoursAgo: 5, inbox: false),
            message("p1", personal, from: ("Maya Chen", "maya.chen@hey.example"), subject: "Dinner Saturday?",
                    body: "We're thinking that new Sichuan place on Valencia, 7:30? Bring Alex if he's around!", hoursAgo: 1.2, unread: true, tags: ["Personal", "Needs Reply"]),
            message("p2", personal, from: ("Northwind Air", "receipts@northwind.example"), subject: "Your trip to Lisbon: booking confirmed",
                    body: "Confirmation ABX42Q. SFO → LIS, Oct 24, 6:05 PM. Seat 14A. Total charged: $642.18.", hoursAgo: 3, starred: true,
                    html: "<div style=\"font-family:-apple-system,Helvetica;max-width:560px;margin:0 auto;padding:28px;color:#1d1d1f\"><div style=\"font-size:13px;color:#86868b;letter-spacing:.06em\">NORTHWIND AIR</div><h1 style=\"font-size:26px;margin:10px 0 18px\">You're going to Lisbon ✈️</h1><table style=\"width:100%;border-collapse:collapse;font-size:14px\"><tr><td style=\"padding:10px 0;border-top:1px solid #eee;color:#86868b\">Confirmation</td><td style=\"text-align:right;border-top:1px solid #eee\"><b>ABX42Q</b></td></tr><tr><td style=\"padding:10px 0;border-top:1px solid #eee;color:#86868b\">Flight</td><td style=\"text-align:right;border-top:1px solid #eee\">SFO → LIS · Oct 24, 6:05 PM</td></tr><tr><td style=\"padding:10px 0;border-top:1px solid #eee;color:#86868b\">Seat</td><td style=\"text-align:right;border-top:1px solid #eee\">14A</td></tr><tr><td style=\"padding:10px 0;border-top:1px solid #eee;color:#86868b\">Total</td><td style=\"text-align:right;border-top:1px solid #eee\">$642.18</td></tr></table><img src=\"https://tracking.northwind.example/open.gif\" width=1 height=1></div>",
                    tags: ["Travel", "Receipt"]),
            message("w2", work, from: ("GitHub", "notifications@github.example"), subject: "[acme/nook] PR #482: Speed up incremental sync",
                    body: "jordan-lee requested your review on this pull request. 4 files changed, +212 −87.", hoursAgo: 4, unread: true, tags: ["Notification"]),
            message("p3", personal, from: ("The Margin", "hello@themargin.example"), subject: "Issue 112: Why local-first software is having a moment",
                    body: themarginIssue, hoursAgo: 7, tags: ["Newsletter"]),
            message("w3", work, from: ("Jordan Lee", "jordan@acme.example"), subject: "1:1 moved to 3pm",
                    body: "Conflict with the board prep — moved our 1:1 to 3pm. Same link.", hoursAgo: 9, tags: ["Calendar"]),
            message("p4", personal, from: ("First Harbor Bank", "alerts@firstharbor.example"), subject: "Your September statement is ready",
                    body: "Your statement for account ending 4471 is now available. Balance: $3,204.55.", hoursAgo: 26, tags: ["Finance"]),
            message("p5", personal, from: ("Lumen Store", "orders@lumen.example"), subject: "Your order has shipped",
                    body: "Order #88213: Desk lamp (Walnut). Arriving Friday.", hoursAgo: 30, tags: ["Receipt"]),
            message("w4", work, from: ("Alex Kim", "alex@acme.example"), subject: "Re: Q4 planning doc",
                    body: "Left comments on the roadmap section. I think we should cut the export feature and double down on search.", hoursAgo: 50, starred: true),
            message("p6", personal, from: ("Dad", "rivera.senior@hey.example"), subject: "Photos from the lake",
                    body: "Finally uploaded them. The one of the dog jumping off the dock is my favorite.", hoursAgo: 75, tags: ["Personal"]),
            message("w5", work, from: ("Figma", "no-reply@figma.example"), subject: "Priya mentioned you in Nook — Reader v3",
                    body: "@sam can we tighten the spacing between message cards?", hoursAgo: 120, tags: ["Notification"]),
        ]

        try? repo.upsert(samples.map(\.0))
        for (message, tags) in samples {
            try? repo.setAutoTags(tags, account: message.account, messageId: message.id)
        }
    }
}

/// A Gmail stand-in that accepts every change and never has anything new.
struct OfflineGmail: GmailService {
    func profile() async throws -> GmailProfile { GmailProfile(emailAddress: "", historyId: "1") }
    func listMessageIDs(query: String, limit: Int) async throws -> [String] { [] }
    func message(id: String, format: GmailMessageFormat) async throws -> GmailMessage { throw GmailError.notFound }
    func history(since historyId: String) async throws -> GmailHistory { GmailHistory(records: [], historyId: historyId) }
    func modifyThread(id: String, add: [String], remove: [String]) async throws {}
    func modifyMessage(id: String, add: [String], remove: [String]) async throws {}
    func trashThread(id: String) async throws {}
    func untrashThread(id: String) async throws {}
    func send(raw: String, threadId: String?) async throws {}
    func draftID(messageId: String) async throws -> String? { nil }
    func updateDraft(id: String, raw: String, threadId: String?) async throws {}
    func sendDraft(id: String) async throws {}
}

/// A full-length newsletter, so the demo has a conversation long enough to scroll.
private let themarginIssue = """
This week: CRDTs in production, a field guide to sync engines, and why your data should outlive the apps you use.

1. CRDTs grow up

Five years ago, conflict-free replicated data types were a conference-talk curiosity. This year three of the editors you probably use every day quietly switched to them. The pitch hasn't changed: every device keeps a full copy, edits merge without a server deciding who wins, and going offline is just a long pause between syncs.

What changed is the engineering. Compact encodings cut document history by an order of magnitude, and garbage collection finally works without breaking peers that were offline for a month. If you dismissed CRDTs as too heavy in 2021, it's worth another look.

2. A field guide to sync engines

Most apps that feel instant share a pattern: write locally first, show the change immediately, and reconcile with the server in the background. The hard parts are the edges. What happens when the server rejects a change you already showed? When two devices rename the same folder? When a phone comes back after six weeks in a drawer?

We talked to four teams who have shipped sync engines and asked what they would do differently. The common answer: keep a log of operations, not just the latest state, and make every operation safe to apply twice.

3. Your data should outlive your apps

The best test of a tool is what happens when you stop using it. Can you take your notes, mail and photos with you, in a format something else can read? Local-first software makes that the default: the files are on your disk, and the app is a lens over them.

That doesn't mean giving up the cloud. It means the cloud becomes a convenience for backup and sharing, rather than the only place your work exists.

4. Reading list

- An interview with the team behind a local-first spreadsheet that syncs over plain files.
- A gentle introduction to vector clocks, with diagrams.
- Why SQLite keeps turning up as an application file format.
- A case study on migrating two million users from a server-first data model.

5. From the inbox

Last week we asked how you back up your mail. Most of you said "I don't," and a few of you said "I export it once a year and hope." One reader keeps a nightly encrypted copy on a USB drive taped inside their desk. We admire the commitment.

That's it for this week. Reply to this email with what you're building; we read every one.

The Margin
"""
