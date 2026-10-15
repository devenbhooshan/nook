import Foundation

/// Decides how tall to make a message's web view from the heights the page reports.
///
/// The view is sized to its content, so content sized to the view (`min-height: 100vh`, say) feeds back on itself:
/// each resize makes the page taller by the same amount, forever. That shows up as the same growth reported again
/// and again, each right after the last resize. After a few rounds the height stops growing. Ordinary growth, such as
/// images arriving, comes in uneven steps or at a slower pace and is always followed.
public struct ContentHeight: Sendable {
    public private(set) var height: Double = 0
    private var lastGrowth: Double?
    private var lastChange: Date?
    private var repeats = 0
    private var stopped = false

    static let repeatsBeforeStopping = 4
    /// Feedback rounds follow each other within a frame or two; anything slower is the page genuinely changing.
    static let feedbackWindow: TimeInterval = 0.25

    public init() {}

    /// Takes a reported content height. Returns the new height for the view, or nil to leave it as it is.
    public mutating func report(_ value: Double, at now: Date = Date()) -> Double? {
        let new = ceil(value)
        guard new > 0, abs(new - height) > 1 else { return nil }
        let growth = new - height
        let quick = lastChange.map { now.timeIntervalSince($0) < Self.feedbackWindow } ?? false
        if growth > 0, quick, let last = lastGrowth, abs(growth - last) <= 2 {
            repeats += 1
        } else {
            repeats = 0
        }
        lastGrowth = growth > 0 ? growth : nil
        if repeats >= Self.repeatsBeforeStopping { stopped = true }
        if stopped, growth > 0 { return nil }
        height = new
        lastChange = now
        return new
    }
}
