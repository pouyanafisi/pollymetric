import XCTest
@testable import Pollymetric

final class AgentTranscriptTests: XCTestCase {
    func testMarkdownGroupsListsAndKeepsCode() {
        let blocks = MarkdownText.blocks("""
        ## Fix
        Some **bold** text
        continues here.

        - one
        - two
        1. first
        ```
        let x = 1
        - not a list
        ```
        """)
        guard blocks.count == 4 else { return XCTFail("got \(blocks.count) blocks") }
        if case .heading(let level, let text) = blocks[0] { XCTAssertEqual(level, 2); XCTAssertEqual(text, "Fix") } else { XCTFail() }
        if case .paragraph(let text) = blocks[1] { XCTAssertEqual(text, "Some **bold** text continues here.") } else { XCTFail() }
        if case .list(let items) = blocks[2] { XCTAssertEqual(items.map(\.text), ["one", "two", "first"]) } else { XCTFail() }
        if case .code(let code) = blocks[3] { XCTAssertTrue(code.contains("- not a list")) } else { XCTFail() }
    }

    func testTranscriptSeparatesBriefAndGroupsTools() {
        let transcript = [
            AgentEntry(kind: "user", text: "the brief"),
            AgentEntry(kind: "tool", text: "Read a", status: "completed", toolKind: "read"),
            AgentEntry(kind: "tool", text: "Read b", status: "completed", toolKind: "read"),
            AgentEntry(kind: "agent_message_chunk", text: "Answer"),
            AgentEntry(kind: "user", text: "follow-up"),
        ]
        let items = TranscriptItem.build(transcript, turnInProgress: false)
        let kinds = items.map { item -> String in
            switch item {
            case .brief: "brief"; case .user: "user"; case .thought: "thought"
            case .answer: "answer"; case .plan: "plan"; case .tools(_, let e, _): "tools\(e.count)"
            }
        }
        XCTAssertEqual(kinds, ["brief", "tools2", "answer", "user"])
    }

    func testToolDetailsAreCompact() {
        XCTAssertEqual(AgentConversation.toolInput(["command": "ls -la dist"]), "ls -la dist")
        XCTAssertEqual(AgentConversation.toolInput(["command": ["git", "status"]]), "git status")
        XCTAssertEqual(AgentConversation.toolOutput([["type": "content", "content": ["type": "text", "text": "ok"]]]), "ok")
        XCTAssertEqual(AgentConversation.toolOutput([["type": "diff", "path": "a.ts", "newText": "x\ny"]]), "Edited a.ts (2 lines)")
        XCTAssertNil(AgentConversation.toolOutput([]))
    }

    func testMarkdownTablesRulesAndLabels() {
        let blocks = MarkdownText.blocks("""
        | Activity | CPUIntensive | AllowBattery |
        |---|---|---|
        | Harvest | true | false |
        | Heartbeat | — | true |

        ★ Insight ─────────────────────
        Body text.
        ─────────────────────
        ---
        """)
        guard blocks.count == 5 else { return XCTFail("got \(blocks.count) blocks: \(blocks)") }
        if case .table(let header, let rows) = blocks[0] {
            XCTAssertEqual(header, ["Activity", "CPUIntensive", "AllowBattery"])
            XCTAssertEqual(rows, [["Harvest", "true", "false"], ["Heartbeat", "—", "true"]])
        } else { XCTFail("expected a table") }
        if case .label(let text) = blocks[1] { XCTAssertEqual(text, "★ Insight") } else { XCTFail("expected a label") }
        if case .paragraph = blocks[2] {} else { XCTFail("expected a paragraph") }
        if case .rule = blocks[3] {} else { XCTFail("expected a rule") }
        if case .rule = blocks[4] {} else { XCTFail("expected a rule") }
    }

    func testSubjectFallsBackToGroupKeyLabel() {
        var record = AgentRecord(groupKey: "|suggestd|", harness: "Claude Code", account: "x", ask: "Explain")
        XCTAssertEqual(record.displaySubject, "suggestd")
        record.subject = "tsup"
        XCTAssertEqual(record.displaySubject, "tsup")
    }

    func testConversationHistoryListsAllAndLoadsOne() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("conv-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HistoryStore(url: dir.appendingPathComponent("history.sqlite"))
        var first = AgentRecord(groupKey: "|tsup|storefront", harness: "Claude Code", account: "work", ask: "Explain")
        first.started = Date(timeIntervalSince1970: 1_000); first.answer = "Rebuild loop"; first.status = "answered"
        first.transcript = [AgentEntry(kind: "agent_message_chunk", text: "Rebuild loop")]
        var second = AgentRecord(groupKey: "|suggestd|", harness: "Codex", account: "personal", ask: "Find a Fix")
        second.started = Date(timeIntervalSince1970: 2_000)
        store.saveAgent(first); store.saveAgent(second)

        let all = await store.allAgentSessions()
        XCTAssertEqual(all.map(\.displaySubject), ["suggestd", "tsup"])
        XCTAssertTrue(all.allSatisfy { $0.transcript.isEmpty }, "the list shouldn't load transcripts")
        let loaded = await store.agentSession(id: first.id)
        XCTAssertEqual(loaded?.transcript.first?.text, "Rebuild loop")
        XCTAssertEqual(loaded?.status, "answered")
    }

    @MainActor
    func testStreamedChunksAreBatchedButKeepOrder() {
        let conversation = AgentConversation(record: AgentRecord(groupKey: "|x|", harness: "Claude Code", account: "a", ask: "Explain"))
        func chunk(_ text: String) -> [String: Any] { ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]] }
        conversation.update(chunk("Hello "))
        conversation.update(chunk("world"))
        XCTAssertTrue(conversation.record.transcript.isEmpty, "chunks wait for the batch")
        conversation.update(["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read a", "kind": "read", "status": "pending"])
        conversation.update(chunk("after"))
        conversation.flushChunks()
        XCTAssertEqual(conversation.record.transcript.map(\.kind), ["agent_message_chunk", "tool", "agent_message_chunk"])
        XCTAssertEqual(conversation.record.transcript.first?.text, "Hello world")
        XCTAssertEqual(conversation.record.answer, "Hello worldafter")
    }

    func testPermissionOffersNoStandingApprovalAndRejectsFirst() {
        let options = AgentConversation.permissionOptions([
            ["optionId": "always", "name": "Always Allow", "kind": "allow_always"],
            ["optionId": "once", "name": "Allow", "kind": "allow_once"],
            ["optionId": "no", "name": "Reject", "kind": "reject_once"],
        ])
        XCTAssertEqual(options.map(\.id), ["no", "once"])
    }
}
