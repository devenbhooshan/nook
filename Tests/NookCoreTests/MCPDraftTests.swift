import Foundation
import Testing
@testable import NookCore

@Suite("Drafts over MCP")
struct MCPDraftTests {
    static let account = "me@example.com"
    let repo: MailRepository
    let gmail = FakeGmail()
    let opened = URLLog()
    let server: MCPServer
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("nook-draft-tests-\(UUID().uuidString)")

    init() throws {
        repo = try makeRepository()
        try repo.addAccount(email: Self.account, name: "Me")
        try repo.upsert([
            .fixture(id: "1", thread: "T", subject: "Tax documents", body: "Please send the statements.", labels: [SystemLabel.inbox]),
        ])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gmail = gmail
        let opened = opened
        server = MCPServer(
            repo: repo, version: "test", isEnabled: { true }, openURL: { opened.append($0) }, makeGmail: { _ in gmail },
            attachmentCache: { AttachmentCache(root: FileManager.default.temporaryDirectory) },
            createdDrafts: CreatedDrafts(defaults: UserDefaults(suiteName: "nook-tests-\(UUID().uuidString)")!)
        )
    }

    func tool(_ name: String, _ arguments: [String: Any]) throws -> (result: [String: Any], text: String, isError: Bool) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let response = try #require(server.handle(line: line))
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
        let result = try #require(decoded["result"] as? [String: Any])
        let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        return (result["structuredContent"] as? [String: Any] ?? [:], text, result["isError"] as? Bool ?? false)
    }

    func file(_ name: String, _ contents: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url.path
    }

    func names(_ value: Any?) -> [String] {
        (value as? [[String: Any]] ?? []).compactMap { $0["filename"] as? String }
    }

    @Test func oneReplyThenEditsLeaveOneDraft() async throws {
        let first = try tool("draft_reply", [
            "account": Self.account, "thread_id": "T", "body": "Attached.",
            "attachments": [try file("a.pdf", "%PDF one"), try file("b.txt", "bee")],
        ])
        #expect(!first.isError, "\(first.text)")
        let id = try #require(first.result["draft_id"] as? String)
        #expect(first.result["thread_id"] as? String == "T")
        #expect(names(first.result["attachments"]) == ["a.pdf", "b.txt"])

        for round in 1...3 {
            let update = try tool("update_draft", ["account": Self.account, "draft_id": id, "body": "Version \(round)"])
            #expect(!update.isError, "\(update.text)")
            #expect(update.result["draft_id"] as? String == id)
        }
        let drafts = try tool("list_drafts", ["account": Self.account, "thread_id": "T"]).result
        #expect(drafts["count"] as? Int == 1)

        let draft = try tool("get_draft", ["account": Self.account, "draft_id": id]).result
        let body = try #require(draft["body"] as? String)
        #expect(body.hasPrefix("Version 3"))
        #expect(body.contains("Please send the statements."), "the quoted original stays")
        #expect(names(draft["attachments"]) == ["a.pdf", "b.txt"], "edits keep the files")
        #expect(draft["is_reply"] as? Bool == true)
        #expect(draft["made_by_claude"] as? Bool == true)

        // Every write opens the draft in Nook; nothing is sent.
        #expect(opened.urls.compactMap(NookURL.init).allSatisfy { if case .draft = $0 { true } else { false } })
        #expect(opened.urls.count == 4)
        #expect(await gmail.sent.isEmpty)
    }

    @Test func getDraftShowsTheUsersOwnEdits() async throws {
        let id = try #require(try tool("compose_draft", ["to": "ca@example.com", "subject": "Docs", "body": "Mine"]).result["draft_id"] as? String)
        // The user edits and saves in Nook, which rewrites the same Gmail draft.
        let edited = MIMEBuilder.gmailRaw(Draft(from: Self.account, to: "ca@example.com", subject: "Docs", body: "Edited by the user"), fromName: "Me")
        _ = try await gmail.updateDraft(id: id, raw: edited, threadId: nil)
        #expect((try tool("get_draft", ["account": Self.account, "draft_id": id]).result["body"] as? String)?.hasPrefix("Edited by the user") == true)
    }

    @Test func addsAndRemovesFiles() throws {
        let id = try #require(try tool("compose_draft", [
            "to": "ca@example.com", "attachments": [try file("one.pdf", "1"), try file("two.pdf", "2")],
        ]).result["draft_id"] as? String)
        let update = try tool("update_draft", [
            "account": Self.account, "draft_id": id, "remove_attachments": ["one.pdf"], "add_attachments": [try file("three.csv", "3")],
        ])
        #expect(!update.isError, "\(update.text)")
        let draft = try tool("get_draft", ["account": Self.account, "draft_id": id]).result
        #expect(names(draft["attachments"]) == ["two.pdf", "three.csv"])
        #expect(draft["to"] as? String == "ca@example.com")

        let read = try tool("get_attachment", ["account": Self.account, "draft_id": id, "filename": "three.csv"])
        #expect(read.result["text"] as? String == "3")

        #expect(try tool("update_draft", ["account": Self.account, "draft_id": id, "remove_attachments": ["nope.pdf"]]).isError)
    }

    @Test func refusesBadFiles() throws {
        #expect(try tool("compose_draft", ["to": "a@b.com", "attachments": ["relative/path.pdf"]]).isError)
        #expect(try tool("compose_draft", ["to": "a@b.com", "attachments": [folder.appendingPathComponent("missing.pdf").path]]).isError)
        #expect(try tool("compose_draft", ["to": "a@b.com", "attachments": [folder.path]]).isError)
        #expect(opened.urls.isEmpty)
    }

    @Test func deletesOnlyItsOwnDraftsWithoutAsking() async throws {
        let mine = try #require(try tool("compose_draft", ["to": "a@b.com"]).result["draft_id"] as? String)
        let theirs = try await gmail.createDraft(raw: MIMEBuilder.gmailRaw(Draft(from: Self.account, to: "x@y.com"), fromName: "Me"), threadId: nil).id

        #expect(!(try tool("delete_draft", ["account": Self.account, "draft_id": mine]).isError))
        let refused = try tool("delete_draft", ["account": Self.account, "draft_id": theirs])
        #expect(refused.isError)
        #expect(refused.text.contains("Ask the user"))
        #expect(!(try tool("delete_draft", ["account": Self.account, "draft_id": theirs, "user_confirmed": true]).isError))
        #expect(try await gmail.drafts().isEmpty)
        #expect(try tool("get_draft", ["account": Self.account, "draft_id": mine]).isError)
    }

    @Test func listsDraftsWithTheirFiles() throws {
        _ = try tool("compose_draft", ["to": "a@b.com", "subject": "First", "attachments": [try file("x.pdf", "x")]])
        _ = try tool("draft_reply", ["account": Self.account, "thread_id": "T", "body": "Second"])
        let list = try tool("list_drafts", [:]).result
        let drafts = try #require(list["drafts"] as? [[String: Any]])
        #expect(drafts.count == 2)
        #expect(drafts.first?["subject"] as? String == "Re: Tax documents", "newest first")
        #expect(names(drafts.last?["attachments"]) == ["x.pdf"])
        #expect((drafts.first?["preview"] as? String)?.hasPrefix("Second") == true)
    }
}
