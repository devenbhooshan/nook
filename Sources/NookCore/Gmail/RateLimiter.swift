import Foundation

/// Work nobody is waiting on: loading older mail, downloading attachments ahead of time. It leaves part of the
/// quota free, so what someone opened (an email's images, a send) isn't queued behind thousands of downloads.
public enum GmailPriority {
    @TaskLocal public static var background = false
}

/// A token bucket that keeps Gmail calls under Google's per-user quota.
///
/// Gmail allows 15,000 quota units per user per minute (250 a second), and each method has a cost:
/// fetching a message is 5 units, sending is 100. Pacing requests here is much cheaper than hitting
/// the limit and backing off, which can stall a first sync for a minute at a time.
public actor RateLimiter {
    public typealias Sleep = @Sendable (TimeInterval) async -> Void

    private let unitsPerSecond: Double
    private let capacity: Double
    private var available: Double
    private var lastRefill: Date
    private let now: @Sendable () -> Date
    private let sleep: Sleep

    /// - Parameters:
    ///   - unitsPerSecond: The steady rate. Defaults to 125, half of Gmail's 250, leaving room for anything
    ///     else using the account and for Google counting a little differently than documented.
    ///   - burst: How many units can go out at once after a quiet spell.
    public init(
        unitsPerSecond: Double = 125,
        burst: Double = 250,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping Sleep = { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    ) {
        self.unitsPerSecond = unitsPerSecond
        self.capacity = burst
        self.available = burst
        self.now = now
        self.lastRefill = now()
        self.sleep = sleep
    }

    private func refill() {
        let current = now()
        available = min(capacity, available + current.timeIntervalSince(lastRefill) * unitsPerSecond)
        lastRefill = current
    }

    /// Waits until `cost` units are available, then spends them. Background work waits until spending them would
    /// still leave `reserve` free for what someone's waiting on.
    public func acquire(_ cost: Int) async {
        if GmailPriority.background {
            let reserve = capacity * 0.4
            while true {
                refill()
                // A little slack, and a floor on the wait: rounding could otherwise leave it a hair short forever,
                // retrying with waits too small to matter.
                if available - Double(cost) >= reserve - 0.01 { break }
                await sleep(max(0.01, (reserve + Double(cost) - available) / unitsPerSecond))
            }
            available -= Double(cost)
            return
        }
        refill()
        // Reserve before waiting, so callers that arrive while this one sleeps queue up behind it.
        available -= Double(cost)
        if available < 0 {
            await sleep(-available / unitsPerSecond)
        }
    }
}

/// Gmail's quota cost for each method (https://developers.google.com/gmail/api/reference/quota).
enum GmailQuota {
    static func cost(method: String, path: String) -> Int {
        switch (method, path) {
        case (_, "profile"): 1
        case (_, "history"): 2
        case ("POST", "messages/send"), ("POST", "drafts/send"): 100
        case ("PUT", let p) where p.hasPrefix("drafts/"): 15
        case ("POST", let p) where p.hasPrefix("threads/"): 10
        default: 5
        }
    }
}
