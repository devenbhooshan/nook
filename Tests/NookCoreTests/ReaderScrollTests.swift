import Testing
@testable import NookCore

@Suite("Reader scrolling")
struct ReaderScrollTests {
    @Test func arrowsMoveALineAndSpaceMovesAPage() {
        #expect(ReaderScroll.forKey(ShortcutInterpreter.KeyCode.downArrow, shift: false, viewportHeight: 600) == .by(48))
        #expect(ReaderScroll.forKey(ShortcutInterpreter.KeyCode.upArrow, shift: false, viewportHeight: 600) == .by(-48))
        #expect(ReaderScroll.forKey(ReaderScroll.KeyCode.space, shift: false, viewportHeight: 600) == .by(504))
        #expect(ReaderScroll.forKey(ReaderScroll.KeyCode.space, shift: true, viewportHeight: 600) == .by(-504))
        #expect(ReaderScroll.forKey(ReaderScroll.KeyCode.pageDown, shift: false, viewportHeight: 600) == .by(504))
        #expect(ReaderScroll.forKey(ReaderScroll.KeyCode.home, shift: false, viewportHeight: 600) == .toTop)
        #expect(ReaderScroll.forKey(ReaderScroll.KeyCode.end, shift: false, viewportHeight: 600) == .toBottom)
        // Letters aren't scroll keys, so j and k keep switching conversations.
        #expect(ReaderScroll.forKey(38, shift: false, viewportHeight: 600) == nil)
    }

    @Test func aTinyWindowStillScrollsByAtLeastALine() {
        #expect(ReaderScroll.forKey(ReaderScroll.KeyCode.space, shift: false, viewportHeight: 50) == .by(48))
    }

    @Test func scrollingStaysWithinTheConversation() {
        #expect(ReaderScroll.by(48).offset(from: 0, contentHeight: 2000, viewportHeight: 600) == 48)
        #expect(ReaderScroll.by(-48).offset(from: 20, contentHeight: 2000, viewportHeight: 600) == 0)
        #expect(ReaderScroll.by(500).offset(from: 1200, contentHeight: 2000, viewportHeight: 600) == 1400)
        #expect(ReaderScroll.toBottom.offset(from: 0, contentHeight: 2000, viewportHeight: 600) == 1400)
        #expect(ReaderScroll.toTop.offset(from: 900, contentHeight: 2000, viewportHeight: 600) == 0)
        // Short conversations don't move.
        #expect(ReaderScroll.by(48).offset(from: 0, contentHeight: 300, viewportHeight: 600) == 0)
    }

    @Test func aSidewaysSwipeGoesBackOnce() {
        var swipe = BackSwipe()
        var went = false
        swipe.begin()
        went = swipe.add(deltaX: 40, deltaY: 2)
        #expect(!went)
        went = swipe.add(deltaX: 60, deltaY: 3)
        #expect(went)
        went = swipe.add(deltaX: 60, deltaY: 0)
        #expect(!went)
    }

    @Test func scrollingDownOrSwipingForwardDoesNotGoBack() {
        var swipe = BackSwipe()
        var went = false
        swipe.begin()
        went = swipe.add(deltaX: -200, deltaY: 0)
        #expect(!went)
        swipe.begin()
        went = swipe.add(deltaX: 100, deltaY: 120)
        #expect(!went)
    }
}
