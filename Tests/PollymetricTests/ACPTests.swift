import XCTest
import HarnessKit
@testable import Pollymetric

@MainActor
final class ACPTests: XCTestCase {
    func exercise(option: String?, closeOnPermission: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ACPClient()
        defer { client.close() }
        let stub = try XCTUnwrap(Bundle.module.url(forResource: "acp_stub", withExtension: "py", subdirectory: "Fixtures"))
        var updates: [String] = []
        var permissionCount = 0
        client.onUpdate = { updates.append($0["sessionUpdate"] as? String ?? "") }
        client.onPermission = { key, _ in
            permissionCount += 1
            if closeOnPermission { client.close() }
            else if let option { client.answer(key, option: option) }
            else { client.cancel() }
        }
        try await client.start(argv: ["/usr/bin/python3", "-u", stub.path], environment: ["PATH": "/usr/bin:/bin"], cwd: root.path, claude: true, explain: true)
        XCTAssertEqual(client.mode, "Ask")
        do { try await client.prompt("Explain this process") }
        catch { if !closeOnPermission { throw error } }
        XCTAssertEqual(permissionCount, 1)
        XCTAssertTrue(updates.contains("agent_message_chunk"))
        XCTAssertTrue(updates.contains("agent_thought_chunk"))
        XCTAssertTrue(updates.contains("tool_call"))
        XCTAssertTrue(updates.contains("plan"))
        if !closeOnPermission && option != nil { try await client.prompt("Follow-up"); XCTAssertEqual(permissionCount, 2) }
        client.close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while client.process?.isRunning == true && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(client.process?.isRunning ?? true)
        let events = try String(contentsOf: root.appendingPathComponent("stub-events.jsonl"))
        XCTAssertTrue(events.contains("session/cancel"))
        XCTAssertTrue(events.contains(option.map { "\"optionId\": \"\($0)\"" } ?? "\"outcome\": \"cancelled\""))
    }

    func testAllowedTurnAndFollowUp() async throws { try await exercise(option: "allow") }
    func testRejectedTurnAndFollowUp() async throws { try await exercise(option: "reject") }
    func testCancelledPermission() async throws { try await exercise(option: nil) }
    func testCloseCancelsPermissionAndKillsChild() async throws { try await exercise(option: nil, closeOnPermission: true) }

    func testAgentHistoryRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID()).sqlite")
        let history = HistoryStore(url: url)
        var record = AgentRecord(groupKey: "group", harness: "Stub", account: "test", ask: "Explain")
        record.transcript = [AgentEntry(kind: "agent_message_chunk", text: "Answer")]
        record.answer = "Answer"; record.status = "answered"
        history.saveAgent(record)
        let loaded = await history.agentSessions(group: "group")
        XCTAssertEqual(loaded.first?.answer, "Answer")
        XCTAssertEqual(loaded.first?.transcript.first?.text, "Answer")
        let other = await history.agentSessions(group: "other")
        XCTAssertTrue(other.isEmpty)
    }

    func testAccountEnvironmentAndSignInProgress() {
        let claude = HarnessDescriptor.builtIns[0]
        let named = try! JSONDecoder().decode(HarnessAccount.self, from: Data(#"{"home":"/tmp/account","label":"test","isDefault":false,"status":"signedOut"}"#.utf8))
        let inherited = ["HOME": "/tmp/home", "USER": "test", "LOGNAME": "test", "CLAUDE_CONFIG_DIR": "/bad", "TOKEN": "must disappear"]
        let env = HarnessProcess.environment(claude, account: named, path: "/bin", inherited: inherited)
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/account")
        XCTAssertNil(env["TOKEN"])
        XCTAssertNil(HarnessProcess.environment(claude, account: nil, path: "/bin", inherited: inherited)["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(Set(env.keys), ["HOME", "USER", "LOGNAME", "PATH", "CLAUDE_CONFIG_DIR"])
        let now = Date()
        let progress = SignInProgress(desired: .signedIn, started: now)
        XCTAssertTrue(progress.isWaiting(status: .signedOut, now: now))
        XCTAssertFalse(progress.isWaiting(status: .signedIn, now: now))
        XCTAssertFalse(progress.isWaiting(status: .unknown, now: now.addingTimeInterval(301)))
        XCTAssertEqual(claude.acp, ["claude-agent-acp"])
        XCTAssertEqual(HarnessDescriptor.builtIns[1].acp, ["codex-acp"])
        XCTAssertNil(HarnessDescriptor.builtIns[2].acp) // `opencode acp` has no read-only mode
        XCTAssertNil(HarnessDescriptor.builtIns[3].acp)
    }

    func testAdapterWithoutReadOnlyModeIsRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ACPClient()
        defer { client.close() }
        let stub = try XCTUnwrap(Bundle.module.url(forResource: "acp_stub", withExtension: "py", subdirectory: "Fixtures"))
        do {
            try await client.start(argv: ["/usr/bin/python3", "-u", stub.path], environment: ["PATH": "/usr/bin:/bin", "STUB_NO_MODES": "1"],
                                   cwd: root.path, claude: true, explain: true)
            XCTFail("A session without a read-only mode must not start")
        } catch {
            XCTAssertTrue("\(error)".contains("read-only"))
        }
    }

    func testAdminScriptQuotesShellAndAppleScript() {
        let script = Lynis.adminScript(executable: "/tmp/it's \"here\"/lynis")
        XCTAssertTrue(script.hasPrefix("do shell script \"d=$(/usr/bin/mktemp -d "))
        XCTAssertTrue(script.hasSuffix("with administrator privileges without altering line endings"))
        XCTAssertTrue(script.contains("\\\"here\\\""))
        XCTAssertTrue(script.contains("'\\\\''"))
        XCTAssertFalse(script.contains("sudo"))
        XCTAssertFalse(script.contains("chown"))
        XCTAssertFalse(script.contains(Lynis.dataDirectory.path))
    }
}
