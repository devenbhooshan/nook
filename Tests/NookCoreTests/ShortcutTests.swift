import Foundation
import Testing
@testable import NookCore

@Suite("Shortcuts")
struct ShortcutTests {
    typealias Code = ShortcutInterpreter.KeyCode

    @Test(arguments: [
        ("j", KeyCommand.next), ("k", .previous), ("o", .open), ("e", .archive), ("y", .archive),
        ("#", .trash), ("s", .toggleStar), ("u", .toggleRead), ("r", .reply), ("a", .replyAll),
        ("f", .forward), ("c", .compose), ("/", .search), ("l", .tagPicker), ("?", .help), ("z", .undo),
        ("U", .toggleUnreadFilter),
    ])
    func singleKeys(key: String, command: KeyCommand) {
        var interpreter = ShortcutInterpreter()
        #expect(interpreter.interpret(characters: key, keyCode: 0) == command)
    }

    @Test func specialKeys() {
        var interpreter = ShortcutInterpreter()
        #expect(interpreter.interpret(characters: "\r", keyCode: Code.returnKey) == .open)
        #expect(interpreter.interpret(characters: "", keyCode: Code.escape) == .close)
        #expect(interpreter.interpret(characters: "", keyCode: Code.downArrow) == .next)
        #expect(interpreter.interpret(characters: "", keyCode: Code.upArrow) == .previous)
        #expect(interpreter.interpret(characters: "", keyCode: Code.delete) == .trash)
        #expect(interpreter.interpret(characters: "\t", keyCode: Code.tab) == .nextSplit)
        #expect(interpreter.interpret(characters: "\u{19}", keyCode: Code.tab, shift: true) == .previousSplit)
        #expect(interpreter.interpret(characters: "x", keyCode: 7) == nil)
    }

    @Test func goToSequences() {
        var interpreter = ShortcutInterpreter()
        let start = Date()
        #expect(interpreter.interpret(characters: "g", keyCode: 5, now: start) == nil)
        #expect(interpreter.isAwaitingSequence)
        #expect(interpreter.interpret(characters: "s", keyCode: 1, now: start.addingTimeInterval(0.3)) == .go(.starred))
        #expect(!interpreter.isAwaitingSequence)

        // Without "g", "s" means star.
        #expect(interpreter.interpret(characters: "s", keyCode: 1) == .toggleStar)

        for (key, mailbox) in [("i", Mailbox.inbox), ("t", .sent), ("a", .all), ("#", .trash)] {
            _ = interpreter.interpret(characters: "g", keyCode: 5, now: start)
            #expect(interpreter.interpret(characters: key, keyCode: 0, now: start) == .go(mailbox))
        }
    }

    @Test func onlyMovementRepeatsWhenAKeyIsHeld() {
        #expect(KeyCommand.next.repeatsWhenHeld)
        #expect(KeyCommand.previous.repeatsWhenHeld)
        for destructive in [KeyCommand.archive, .trash, .toggleStar, .toggleRead, .reply, .compose, .undo, .go(.inbox)] {
            #expect(!destructive.repeatsWhenHeld, "\(destructive)")
        }
    }

    @Test func goToSequenceTimesOut() {
        var interpreter = ShortcutInterpreter()
        let start = Date()
        _ = interpreter.interpret(characters: "g", keyCode: 5, now: start)
        // Too late: "i" isn't a shortcut on its own.
        #expect(interpreter.interpret(characters: "i", keyCode: 34, now: start.addingTimeInterval(5)) == nil)
        _ = interpreter.interpret(characters: "g", keyCode: 5, now: start)
        #expect(interpreter.interpret(characters: "e", keyCode: 14, now: start.addingTimeInterval(5)) == .archive)
    }

    @Test func referenceCoversEverySection() {
        #expect(ShortcutInterpreter.reference.map(\.title) == ["Navigate", "Act", "Write", "Go to", "Calendar"])
        #expect(ShortcutInterpreter.reference.allSatisfy { !$0.entries.isEmpty })
    }
}

@Suite("Onboarding")
struct OnboardingTests {
    @Test func newPeopleConnectMailThenSetUpTaggingThenMayConnectAnAssistant() {
        #expect(OnboardingStep.current(hasAccounts: false, completed: false, taggingReviewed: false) == .connectAccount)
        #expect(OnboardingStep.current(hasAccounts: true, completed: false, taggingReviewed: false) == .setUpTagging)
        #expect(OnboardingStep.current(hasAccounts: true, completed: false, taggingReviewed: true) == .connectAssistant)
        #expect(OnboardingStep.current(hasAccounts: true, completed: true, taggingReviewed: true) == .done)
    }

    @Test func existingSetupsSkipTheNewSteps() {
        #expect(OnboardingStep.current(hasAccounts: true, completed: nil, taggingReviewed: false) == .done)
    }

    @Test func removingEveryAccountStartsOver() {
        #expect(OnboardingStep.current(hasAccounts: false, completed: true, taggingReviewed: true) == .connectAccount)
        #expect(OnboardingStep.current(hasAccounts: false, completed: nil, taggingReviewed: false) == .connectAccount)
    }

    @Test func stepsAreInOrder() {
        #expect(OnboardingStep.allCases == [.connectAccount, .setUpTagging, .connectAssistant, .done])
    }
}

@Suite("MCP client setup")
struct MCPClientTests {
    let path = "/Applications/Nook.app/Contents/MacOS/nook-mcp"

    @Test func claudeCodeCommand() {
        #expect(MCPClient.claudeCode.snippet(serverPath: path) == "claude mcp add nook -- /Applications/Nook.app/Contents/MacOS/nook-mcp")
    }

    @Test func quotesPathsWithSpacesForTheShell() {
        let spaced = "/Users/sam/My Apps/Nook.app/Contents/MacOS/nook-mcp"
        #expect(MCPClient.claudeCode.snippet(serverPath: spaced) == "claude mcp add nook -- '/Users/sam/My Apps/Nook.app/Contents/MacOS/nook-mcp'")
        #expect(MCPClient.shellQuoted("/tmp/it's") == "'/tmp/it'\\''s'")
    }

    @Test func claudeDesktopConfigIsValidJSON() throws {
        let tricky = "/Users/sam/\"quoted\" apps/nook-mcp"
        let snippet = MCPClient.claudeDesktop.snippet(serverPath: tricky)
        let object = try JSONSerialization.jsonObject(with: Data("{\(snippet)}".utf8)) as? [String: [String: String]]
        #expect(object?["nook"]?["command"] == tricky)
    }

    @Test func otherClientsGetTheBarePath() {
        #expect(MCPClient.other.snippet(serverPath: path) == path)
        #expect(MCPClient.allCases.allSatisfy { !$0.instructions.isEmpty && !$0.title.isEmpty })
    }
}
