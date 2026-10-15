import Foundation
import Testing
@testable import NookCore

@Suite("Message height")
struct ContentHeightTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func followsTheContent() {
        var height = ContentHeight()
        #expect(height.report(320.4, at: start) == 321)
        #expect(height.report(321, at: start) == nil)
        #expect(height.report(900, at: start.addingTimeInterval(0.01)) == 900)
        #expect(height.report(500, at: start.addingTimeInterval(0.02)) == 500)
        #expect(height.report(0, at: start.addingTimeInterval(0.03)) == nil)
    }

    @Test func stopsGrowingWhenThePageIsSizedToTheView() {
        // A page with `min-height: 100vh` and a footer: every resize adds the footer again.
        var height = ContentHeight()
        var view = 0.0
        var time = start
        for _ in 0..<100 {
            if let new = height.report(view + 48, at: time) { view = new }
            time += 0.016
        }
        #expect(view < 600)
        // It can still shrink.
        #expect(height.report(100, at: time) == 100)
    }

    @Test func keepsFollowingSlowEvenGrowth() {
        // Identical images arriving one by one, each well after the last.
        var height = ContentHeight()
        var time = start
        for step in 1...12 {
            #expect(height.report(Double(step) * 200, at: time) == Double(step) * 200)
            time += 0.5
        }
    }

    @Test func keepsFollowingQuickUnevenGrowth() {
        var height = ContentHeight()
        var time = start
        for value in [100.0, 180, 400, 410, 700, 1_300, 1_340, 2_000] {
            #expect(height.report(value, at: time) == value)
            time += 0.01
        }
    }
}
