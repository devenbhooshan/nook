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
    /// `--palette` shows the command palette, `--wake-soon` makes the next reminder go off in two seconds, `--unread` turns on the unread filter, `--split <tag>` opens a tab,
    /// `--onboarding [connect|tagging]` shows an onboarding step (the assistant step by default), `--client-help` opens the Google client steps,
    /// `--keys down,space,…` presses keys once the window is up (in the compose sheet, when one is open), `--swipe` swipes back,
    /// `--notices` shows the signed-out and photo notices, `--snapshot <file.png>` saves the window, even on another Space, and `--dark` forces dark mode. Used for screenshots and for checking input handling.
    /// Queues real key events, so they go through the same monitors as typing.
    private static func pressKeys(_ keys: [String], in store: AppStore) {
        guard let main = store.mainWindow else { return }
        let codes: [String: (UInt16, String)] = [
            "down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "space": (49, " "),
            "pagedown": (121, "\u{F72D}"), "pageup": (116, "\u{F72C}"), "home": (115, "\u{F729}"), "end": (119, "\u{F72B}"),
            "j": (38, "j"), "k": (40, "k"), "esc": (53, "\u{1B}"),
            "return": (36, "\r"), "tab": (48, "\t"),
        ]
        // US key codes, so typed text and single-key shortcuts can be checked.
        let letters: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
            "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        // A beat between keys, like a person typing, so a key that opens something lands before the next one.
        for (index, entry) in keys.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(index)) {
                // Whichever window is in front by then: a key may have opened a sheet.
                press(entry, in: main.attachedSheet ?? main, codes: codes, letters: letters)
            }
        }
    }

    private static func press(_ entry: String, in window: NSWindow, codes: [String: (UInt16, String)], letters: [String: UInt16]) {
        // "cmd-shift-a" style: modifiers, then the key.
        var parts = entry.split(separator: "-").map(String.init)
        let key = parts.removeLast()
        var flags: NSEvent.ModifierFlags = []
        if parts.contains("cmd") { flags.insert(.command) }
        if parts.contains("shift") { flags.insert(.shift) }
        guard let (code, characters) = codes[key] ?? letters[key].map({ ($0, key) }) else { return }
        for down in [true, false] {
            guard let event = NSEvent.keyEvent(
                with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Clicks at a point measured in points from the top left of the window (its sheet, when one is open).
    private static func click(at point: CGPoint, in store: AppStore) {
        guard let main = store.mainWindow else { return }
        let window = main.attachedSheet ?? main
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        // Move there first and linger, the way a person does, so hover effects (tooltips) are part of the test.
        // Warping the real pointer is what makes tracking areas notice.
        let screenPoint = window.convertPoint(toScreen: location)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: mainHeight - screenPoint.y))
        if let move = NSEvent.mouseEvent(
            with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ) { NSApp.postEvent(move, atStart: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { press(at: location, in: window) }
    }

    private static func press(at location: NSPoint, in window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    /// Prints the visible windows and panels, so a test can tell whether a picker or dialog appeared.
    private static func reportWindows() {
        let names = NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))" }
        print("demo: windows=\(names.joined(separator: ","))")
        fflush(stdout)
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
        if arguments.contains("--wake-soon") { store.demoWakeSoon() }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + 0.25 * Double(keys.count)) { reportReader(store) }
        }
        if let flag = arguments.firstIndex(of: "--click"), arguments.indices.contains(flag + 1) {
            // Several points, "x,y/x,y", are clicked two seconds apart.
            for (index, point) in arguments[flag + 1].split(separator: "/").enumerated() {
                let values = point.split(separator: ",").compactMap { Double($0) }
                guard values.count == 2 else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5 + 2 * Double(index)) { click(at: CGPoint(x: values[0], y: values[1]), in: store) }
            }
        }
        if let flag = arguments.firstIndex(of: "--attach"), arguments.indices.contains(flag + 1) {
            let url = URL(fileURLWithPath: arguments[flag + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NotificationCenter.default.post(name: .nookDemoAttach, object: [url]) }
        }
        if arguments.contains("--report-windows") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { reportWindows() }
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
            // After any keys have been typed.
            let keys = arguments.firstIndex(of: "--keys").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1].split(separator: ",").count : nil } ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 3 + 0.25 * Double(keys)) { snapshot(store, to: path) }
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
            hoursAgo: Double, unread: Bool = false, starred: Bool = false, inbox: Bool = true, html: String = "", tags: [String] = [],
            files: [Attachment] = [], to: String? = nil
        ) -> (MailMessage, [String]) {
            var labels: Set<String> = []
            if to != nil { labels.insert(SystemLabel.sent) }
            if inbox { labels.insert(SystemLabel.inbox) }
            if unread { labels.insert(SystemLabel.unread) }
            if starred { labels.insert(SystemLabel.starred) }
            let message = MailMessage(
                id: id, account: account, threadId: thread ?? id, fromName: from.0, fromEmail: from.1,
                to: to ?? "Sam Rivera <\(account)>", subject: subject, snippet: String(body.replacingOccurrences(of: "\n", with: " ").prefix(120)),
                bodyHTML: html, bodyText: body, date: now.addingTimeInterval(-hoursAgo * 3600), labels: labels,
                messageIdHeader: "<\(id)@demo.example>", attachments: files
            )
            return (message, tags)
        }

        let samples: [(MailMessage, [String])] = [
            message("w1", work, thread: "launch", from: ("Priya Natarajan", "priya@acme.example"), subject: "Launch checklist for Thursday",
                    body: "Hey Sam,\n\nCan you confirm the release notes are final by tomorrow noon? Legal signed off on the privacy copy this morning.\n\nAlso — do we still want the waitlist email to go out at 9am PT?\n\nThanks,\nPriya", hoursAgo: 0.4, unread: true, tags: ["Needs Reply"],
                    files: [DemoAttachments.pdf("Release notes v3.pdf", size: 184_320), DemoAttachments.photo("launch-timeline.png", size: 412_000, hue: 0.42)]),
            message("w0", work, thread: "launch", from: ("Sam Rivera", work), subject: "Launch checklist for Thursday",
                    body: "Draft notes are in the doc. I'll do a final pass tonight.", hoursAgo: 5, inbox: false),
            message("p1", personal, from: ("Maya Chen", "maya.chen@hey.example"), subject: "Dinner Saturday?",
                    body: "We're thinking that new Sichuan place on Valencia, 7:30? Bring Alex if he's around!", hoursAgo: 1.2, unread: true, tags: ["Personal", "Needs Reply"]),
            message("p2", personal, from: ("Northwind Air", "receipts@northwind.example"), subject: "Your trip to Lisbon: booking confirmed",
                    body: "Confirmation ABX42Q. SFO → LIS, Oct 24, 6:05 PM. Seat 14A. Total charged: $642.18.", hoursAgo: 3, starred: true,
                    html: "<div style=\"font-family:-apple-system,Helvetica;max-width:560px;margin:0 auto;padding:28px;color:#1d1d1f\"><div style=\"font-size:13px;color:#86868b;letter-spacing:.06em\">NORTHWIND AIR</div><h1 style=\"font-size:26px;margin:10px 0 18px\">You're going to Lisbon ✈️</h1><table style=\"width:100%;border-collapse:collapse;font-size:14px\"><tr><td style=\"padding:10px 0;border-top:1px solid #eee;color:#86868b\">Confirmation</td><td style=\"text-align:right;border-top:1px solid #eee\"><b>ABX42Q</b></td></tr><tr><td style=\"padding:10px 0;border-top:1px solid #eee;color:#86868b\">Flight</td><td style=\"text-align:right;border-top:1px solid #eee\">SFO → LIS · Oct 24, 6:05 PM</td></tr><tr><td style=\"padding:10px 0;border-top:1px solid #eee;color:#86868b\">Seat</td><td style=\"text-align:right;border-top:1px solid #eee\">14A</td></tr><tr><td style=\"padding:10px 0;border-top:1px solid #eee;color:#86868b\">Total</td><td style=\"text-align:right;border-top:1px solid #eee\">$642.18</td></tr></table><img src=\"https://tracking.northwind.example/open.gif\" width=1 height=1></div>",
                    tags: ["Travel", "Receipt"], files: [DemoAttachments.pdf("Boarding pass ABX42Q.pdf", size: 96_200)]),
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
                    body: "Left comments on the roadmap section. I think we should cut the export feature and double down on search.", hoursAgo: 50, starred: true,
                    html: "<div dir=\"ltr\">Left comments on the roadmap section. I think we should cut the export feature and double down on search.<br><br>Alex</div><br><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">On Mon, Oct 12, 2026 at 9:14 AM Sam Rivera &lt;sam@acme.example&gt; wrote:<br></div><blockquote class=\"gmail_quote\" style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">\(String(repeating: "<p>Here's the Q4 planning doc. Comments welcome on every section, especially the roadmap and hiring plan.</p>", count: 30))</blockquote></div>",
                    files: [Attachment(partId: "1", filename: "Q4 roadmap.numbers", mimeType: "application/vnd.apple.numbers", size: 1_240_000, attachmentId: "demo-file:numbers")]),
            message("p6", personal, from: ("Dad", "rivera.senior@hey.example"), subject: "Photos from the lake",
                    body: "Finally uploaded them. The one of the dog jumping off the dock is my favorite.", hoursAgo: 75, tags: ["Personal"],
                    files: [
                        DemoAttachments.photo("IMG_2041.jpg", size: 2_310_000, hue: 0.55),
                        DemoAttachments.photo("IMG_2047.jpg", size: 1_980_000, hue: 0.08),
                        DemoAttachments.photo("IMG_2052.jpg", size: 2_640_000, hue: 0.33),
                    ]),
            message("w5", work, from: ("Figma", "no-reply@figma.example"), subject: "Priya mentioned you in Nook — Reader v3",
                    body: "@sam can we tighten the spacing between message cards?", hoursAgo: 120, tags: ["Notification"]),
            message("w6", work, from: ("Sam Rivera", work), subject: "Contract renewal terms",
                    body: "Hi Dana,\n\nAttached are our proposed terms for next year. Could you let me know by Friday whether they work on your side?\n\nThanks,\nSam",
                    hoursAgo: 20, inbox: false, to: "Dana Whitfield <dana@lumacorp.example>"),
            message("w7", work, from: ("Sam Rivera", work), subject: "Invoice #2291",
                    body: "Hi Marcus,\n\nJust checking whether invoice #2291 went through on your end. It's showing as outstanding here.\n\nSam",
                    hoursAgo: 96, to: "Marcus Bell <marcus@vendorly.example>"),
        ]

        try? repo.upsert(samples.map(\.0))
        for (message, tags) in samples {
            try? repo.setAutoTags(tags, account: message.account, messageId: message.id)
        }

        // Reminders: two waiting, a follow-up waiting, and a follow-up that just went off with no reply.
        for (account, thread, text) in [(work, "w3", "tomorrow"), (personal, "p5", "next week")] {
            if let due = ReminderTime.parse(text, now: now) {
                try? repo.setReminder(Reminder(account: account, threadId: thread, kind: .remind, due: due))
            }
        }
        let sent = now.addingTimeInterval(-20 * 3600)
        try? repo.setReminder(Reminder(account: work, threadId: "w6", kind: .followUp, due: sent.addingTimeInterval(3 * 86_400), since: sent))
        try? repo.setReminder(Reminder(
            account: work, threadId: "w7", kind: .followUp, due: now.addingTimeInterval(-600),
            since: now.addingTimeInterval(-96 * 3600), wokeAt: now.addingTimeInterval(-600)
        ))
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
    func send(raw: String, threadId: String?) async throws -> String? { threadId }
    func draftID(messageId: String) async throws -> String? { nil }
    func updateDraft(id: String, raw: String, threadId: String?) async throws {}
    func sendDraft(id: String) async throws -> String? { nil }
    func attachment(messageId: String, attachmentId: String) async throws -> Data {
        guard let data = DemoAttachments.data(for: attachmentId) else { throw GmailError.notFound }
        return data
    }
}

/// Sample files for the demo, drawn on demand so nothing is bundled.
enum DemoAttachments {
    private static var nextPart = 0

    @MainActor static func pdf(_ name: String, size: Int) -> Attachment {
        nextPart += 1
        return Attachment(partId: "\(nextPart)", filename: name, mimeType: "application/pdf", size: size, attachmentId: "demo-pdf:\(name)")
    }

    @MainActor static func photo(_ name: String, size: Int, hue: Double) -> Attachment {
        nextPart += 1
        let type = name.hasSuffix(".png") ? "image/png" : "image/jpeg"
        return Attachment(partId: "\(nextPart)", filename: name, mimeType: type, size: size, attachmentId: "demo-photo:\(hue)")
    }

    static func data(for id: String) -> Data? {
        if id.hasPrefix("demo-pdf:") { return pdfData(title: String(id.dropFirst("demo-pdf:".count))) }
        if id.hasPrefix("demo-photo:") { return photoData(hue: Double(id.dropFirst("demo-photo:".count)) ?? 0.5) }
        if id.hasPrefix("demo-file:") { return Data("Sample file".utf8) }
        return nil
    }

    /// A one-page document with a title and some ruled lines of "text".
    private static func pdfData(title: String) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(box)
        context.setFillColor(NSColor(calibratedRed: 0.18, green: 0.61, blue: 0.48, alpha: 1).cgColor)
        context.fill(CGRect(x: 56, y: 700, width: 220, height: 26))
        context.setFillColor(NSColor(white: 0.82, alpha: 1).cgColor)
        for line in 0..<22 {
            let width: CGFloat = line % 5 == 4 ? 300 : 500
            context.fill(CGRect(x: 56, y: 640 - CGFloat(line) * 24, width: width, height: 9))
        }
        context.endPDFPage()
        context.closePDF()
        _ = title
        return data as Data
    }

    /// A soft landscape: sky, sun and two hills.
    private static func photoData(hue: Double) -> Data? {
        let width = 1200, height = 800
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let sky = [NSColor(hue: hue, saturation: 0.35, brightness: 0.98, alpha: 1).cgColor,
                   NSColor(hue: hue, saturation: 0.6, brightness: 0.75, alpha: 1).cgColor] as CFArray
        if let gradient = CGGradient(colorsSpace: nil, colors: sky, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        }
        context.setFillColor(NSColor(hue: 0.12, saturation: 0.5, brightness: 1, alpha: 0.9).cgColor)
        context.fillEllipse(in: CGRect(x: 820, y: 520, width: 150, height: 150))
        context.setFillColor(NSColor(hue: hue + 0.2, saturation: 0.45, brightness: 0.5, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: -300, y: -500, width: 1300, height: 900))
        context.setFillColor(NSColor(hue: hue + 0.25, saturation: 0.5, brightness: 0.38, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 400, y: -600, width: 1300, height: 900))
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
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
