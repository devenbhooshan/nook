import AppKit
import Darwin

/// Dev builds only (`NOOK_DEV=1 ./scripts/build-app.sh`): times every key press and click from the moment it happens
/// until Nook is idle again, notes the slow steps inside it, and catches the main thread freezing. Mail → Copy
/// Diagnostics (⌥⌘D) puts a plain-text report on the clipboard. It names actions and steps only, never mail content.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    static let isEnabled: Bool = {
        #if NOOK_DEV
        true
        #else
        ProcessInfo.processInfo.environment["NOOK_DEV"] == "1"
        #endif
    }()

    struct Action {
        let name: String
        let context: String
        let date: Date
        let start: TimeInterval
        var end: TimeInterval?
        var ms: Double { ((end ?? start) - start) * 1000 }
    }

    struct Span {
        let name: String
        let start: TimeInterval
        let end: TimeInterval
        let onMain: Bool
        var ms: Double { (end - start) * 1000 }
    }

    struct Freeze {
        let start: TimeInterval
        let end: TimeInterval
        let date: Date
        /// What the main thread was doing a second into the freeze: function names, innermost first.
        var stack: [String] = []
        var ms: Double { (end - start) * 1000 }
    }

    /// Ends a step when it goes out of scope: `let step = Diagnostics.step("reload"); defer { step?.end() }`.
    final class Step: @unchecked Sendable {
        let name: String
        let start = ProcessInfo.processInfo.systemUptime
        let onMain = Thread.isMainThread
        init(_ name: String) { self.name = name }
        func end() { Diagnostics.shared.record(Span(name: name, start: start, end: ProcessInfo.processInfo.systemUptime, onMain: onMain)) }
    }

    static func step(_ name: String) -> Step? { isEnabled ? Step(name) : nil }

    /// Where you are when an action starts (reader, list, search…), filled in by the store. Called on the main thread.
    var context: @MainActor () -> String = { "" }

    private let lock = NSLock()
    private var actions: [Action] = []
    private var spans: [Span] = []
    private var freezes: [Freeze] = []
    private var open: Int?
    private var started = false
    private var mainThread: thread_t = 0
    private var mainStackTop: UInt = 0
    private var mainStackSize: UInt = 0
    private let launched = Date()

    private func record(_ span: Span) {
        lock.withLock {
            spans.append(span)
            if spans.count > 4000 { spans.removeFirst(spans.count - 4000) }
        }
    }

    @MainActor func start() {
        guard Self.isEnabled, !started else { return }
        started = true
        mainThread = mach_thread_self()
        mainStackTop = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        mainStackSize = UInt(pthread_get_stacksize_np(pthread_self()))
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
            self?.begin(event)
            return event
        }
        // When the main run loop is about to sleep, whatever the last action set off has finished.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            self?.idle()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        Thread.detachNewThread { [weak self] in self?.watch() }
        // Checks the freeze report end to end: NOOK_FREEZE_TEST=1 blocks the main thread for 1.5 s after launch.
        if ProcessInfo.processInfo.environment["NOOK_FREEZE_TEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Self.blockMainThreadForTest() }
        }
    }

    @MainActor private func begin(_ event: NSEvent) {
        let name = Self.describe(event)
        let context = context()
        lock.withLock {
            if let open { actions[open].end = ProcessInfo.processInfo.systemUptime }
            // The event's own timestamp, so time spent waiting behind earlier work counts too.
            actions.append(Action(name: name, context: context, date: Date(), start: event.timestamp))
            if actions.count > 1000 { actions.removeFirst() }
            open = actions.count - 1
        }
    }

    private func idle() {
        lock.withLock {
            guard let index = open else { return }
            actions[index].end = ProcessInfo.processInfo.systemUptime
            open = nil
        }
    }

    /// Pings the main thread every 100 ms; an answer that takes over a quarter second is a freeze. One still going
    /// after a second gets the main thread's stack recorded, so the report says what it was stuck on.
    private func watch() {
        while true {
            let sent = ProcessInfo.processInfo.systemUptime
            let answered = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { answered.signal() }
            var stack: [String] = []
            if answered.wait(timeout: .now() + 1) == .timedOut {
                stack = mainStack()
                answered.wait()
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - sent > 0.25 {
                lock.withLock {
                    freezes.append(Freeze(start: sent, end: now, date: Date().addingTimeInterval(sent - now), stack: stack))
                    if freezes.count > 300 { freezes.removeFirst() }
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Pauses the main thread for a moment and walks its frame pointers. Nothing is allocated while it's paused:
    /// it could be holding the allocator's lock.
    private func mainStack() -> [String] {
        let capacity = 48
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: capacity)
        defer { frames.deallocate() }
        var count = 0
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return [] }
        let got = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &stateCount)
            }
        }
        if got == KERN_SUCCESS {
            let strip: (UInt64) -> UInt = { UInt($0 & 0x0000_7FFF_FFFF_FFFF) }
            frames[count] = strip(state.__pc); count += 1
            frames[count] = strip(state.__lr); count += 1
            var fp = UInt(state.__fp)
            let low = mainStackTop - mainStackSize, high = mainStackTop
            while count < capacity, fp >= low, fp + 16 <= high, fp % 8 == 0 {
                let pointer = UnsafePointer<UInt>(bitPattern: fp)!
                let next = pointer[0], ret = pointer[1]
                if ret == 0 { break }
                frames[count] = UInt(UInt64(ret) & 0x0000_7FFF_FFFF_FFFF); count += 1
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(mainThread)
        var names: [String] = []
        for index in 0..<count {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: frames[index]), &info) != 0 else { continue }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            let symbol = info.dli_sname.map { Self.demangle(String(cString: $0)) } ?? "?"
            names.append("\(image) · \(symbol)")
        }
        return names
    }

    @_silgen_name("swift_demangle")
    private static func swiftDemangle(_ mangled: UnsafePointer<CChar>?, _ length: Int, _ output: UnsafeMutablePointer<CChar>?, _ outputLength: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

    static func demangle(_ name: String) -> String {
        guard let result = name.withCString({ swiftDemangle($0, strlen($0), nil, nil, 0) }) else { return name }
        defer { free(result) }
        return String(cString: result)
    }

    @inline(never) static func blockMainThreadForTest() {
        Thread.sleep(forTimeInterval: 1.5)
    }

    static func describe(_ event: NSEvent) -> String {
        if event.type == .leftMouseUp {
            let p = event.locationInWindow
            let height = event.window?.contentView?.bounds.height ?? 0
            let title = event.window?.title.isEmpty == false ? event.window!.title : "window"
            return "click \(title) (\(Int(p.x)), \(Int(height - p.y)))"
        }
        var mods = ""
        let flags = event.modifierFlags
        if flags.contains(.control) { mods += "⌃" }
        if flags.contains(.option) { mods += "⌥" }
        if flags.contains(.shift) { mods += "⇧" }
        if flags.contains(.command) { mods += "⌘" }
        let names: [UInt16: String] = [
            53: "Esc", 36: "Return", 76: "Enter", 48: "Tab", 49: "Space", 51: "Delete", 117: "Fwd Delete",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        ]
        let key = names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return "key \(mods)\(key)"
    }

    // MARK: Report

    @MainActor func report(summary: String) -> String {
        let (actions, spans, freezes) = lock.withLock { (self.actions, self.spans, self.freezes) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        func ms(_ value: Double) -> String { String(format: "%6.0f ms", value) }

        /// The steps that ran while an action was in progress or soon after (a delayed reload, say).
        func steps(for action: Action) -> [Span] {
            let until = (action.end ?? action.start) + 1.0
            return spans.filter { $0.start >= action.start - 0.01 && $0.start <= until && $0.ms >= 2 }
        }

        func lines(for action: Action) -> [String] {
            var out = ["\(ms(action.ms))  \(action.name)  [\(action.context)]  \(time.string(from: action.date))"]
            let inside = steps(for: action)
            let actionEnd = action.end ?? action.start
            for span in inside.sorted(by: { $0.start < $1.start }).prefix(25) {
                let offset = (span.start - action.start) * 1000
                let late = span.start > actionEnd ? "  (after idle)" : ""
                out.append("          \(ms(span.ms))  \(span.name)\(span.onMain ? "" : " · background")  at +\(Int(offset)) ms\(late)")
            }
            let measured = inside.filter { $0.onMain && $0.start <= actionEnd }.reduce(0) { $0 + min($1.ms, action.ms) }
            if action.ms > 30 {
                out.append("          \(ms(max(0, action.ms - measured)))  not in a measured step (SwiftUI, layout, drawing)")
            }
            return out
        }

        var out: [String] = []
        out.append("Nook diagnostics · \(version) (\(build)) dev · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        out.append("Copied \(Date().formatted(date: .abbreviated, time: .standard)) · running since \(launched.formatted(date: .omitted, time: .shortened))")
        out.append(summary)
        out.append("")

        let finished = actions.filter { $0.end != nil }
        out.append("SLOWEST ACTIONS (\(finished.count) recorded)")
        for action in finished.sorted(by: { $0.ms > $1.ms }).prefix(12) { out += lines(for: action) }
        out.append("")

        out.append("FREEZES (main thread busy over 250 ms)")
        if freezes.isEmpty { out.append("  none") }
        for freeze in freezes.sorted(by: { $0.ms > $1.ms }).prefix(12) {
            let during = actions.last { $0.start <= freeze.end && ($0.end ?? .infinity) >= freeze.start }?.name ?? "no key or click"
            out.append("\(ms(freeze.ms))  freeze at \(time.string(from: freeze.date)) · during: \(during)")
            let overlapping = spans.filter { $0.onMain && $0.end >= freeze.start && $0.start <= freeze.end && $0.ms >= 5 }
            for span in overlapping.sorted(by: { $0.ms > $1.ms }).prefix(6) { out.append("          \(ms(span.ms))  \(span.name)") }
            if !freeze.stack.isEmpty {
                // Nook's own frames say what it was doing; the innermost system frame says what it was waiting on.
                let ours = freeze.stack.filter { $0.hasPrefix("Nook ·") || $0.hasPrefix("NookCore") }
                out.append("          main thread was in: \(freeze.stack.first ?? "?")")
                for frame in ours.prefix(10) { out.append("            \(frame.prefix(160))") }
            }
        }
        out.append("")

        out.append("SLOWEST STEPS")
        let grouped = Dictionary(grouping: spans, by: \.name)
        let stats = grouped.map { name, list -> (String, Double, Double, Int) in
            let times = list.map(\.ms).sorted()
            return (name, times.last ?? 0, times[times.count / 2], times.count)
        }
        for (name, worst, median, count) in stats.sorted(by: { $0.1 > $1.1 }).prefix(15) {
            out.append("  \(name): worst \(Int(worst)) ms · median \(Int(median)) ms · \(count)×")
        }
        out.append("")

        out.append("LAST 50 ACTIONS")
        for action in finished.suffix(50) {
            out.append("\(ms(action.ms))  \(action.name)  [\(action.context)]  \(time.string(from: action.date))")
        }
        return out.joined(separator: "\n")
    }
}
