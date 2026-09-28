import XCTest
@testable import HarnessKit

final class HarnessKitTests: XCTestCase {
    func testBuiltInsDecodeAndAreReadOnly() {
        let ids = HarnessDescriptor.builtIns.map(\.id)
        XCTAssertEqual(ids, ["claude-code", "codex", "opencode", "grok", "cursor-agent"])
        XCTAssertTrue(HarnessDescriptor.builtIns.allSatisfy { $0.readOnly == true })
        // Cursor's status command starts a login when signed out, so it must have no probe.
        XCTAssertNil(HarnessDescriptor.builtIns.first { $0.id == "cursor-agent" }?.auth)
    }

    func testUserFileOverridesAddsAndDisables() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("harnesses-\(UUID()).json")
        try #"""
        [
          { "id": "codex", "name": "Codex (mine)", "executables": ["codex"], "launch": ["codex", "{prompt}"] },
          { "id": "grok", "name": "Grok", "executables": ["grok"], "launch": ["grok"], "disabled": true },
          { "id": "aider", "name": "Aider", "executables": ["aider"], "launch": ["aider", "--message", "{prompt}"] }
        ]
        """#.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = HarnessRegistry.load(userFile: url)
        XCTAssertNil(loaded.userFileError)
        XCTAssertEqual(loaded.descriptors.map(\.id), ["claude-code", "codex", "opencode", "cursor-agent", "aider"])
        XCTAssertEqual(loaded.descriptors.first { $0.id == "codex" }?.name, "Codex (mine)")
    }

    func testBrokenUserFileKeepsBuiltIns() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID()).json")
        try "[ not json".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let loaded = HarnessRegistry.load(userFile: url)
        XCTAssertNotNil(loaded.userFileError)
        XCTAssertEqual(loaded.descriptors.count, HarnessDescriptor.builtIns.count)
    }

    func testLaunchCommandSelectsAccountAndQuotes() {
        let claude = HarnessDescriptor.builtIns[0]
        let values = HarnessCommand.Values(prompt: "Read /tmp/it's here.md", briefFile: "/tmp/b.md", briefDir: "/tmp/briefs dir", cwd: "/Users/me/My App")
        let named = HarnessAccount(home: "/Users/me/.claude-work", label: "work", isDefault: false, status: .signedIn, identity: nil)
        XCTAssertEqual(
            HarnessCommand.launch(claude, account: named, values: values),
            "cd '/Users/me/My App' && CLAUDE_CONFIG_DIR=/Users/me/.claude-work claude --permission-mode plan --add-dir '/tmp/briefs dir' 'Read /tmp/it'\\''s here.md'"
        )
        let standard = HarnessAccount(home: "/Users/me/.claude", label: "default", isDefault: true, status: .signedIn, identity: nil)
        XCTAssertTrue(HarnessCommand.launch(claude, account: standard, values: values).contains("&& env -u CLAUDE_CONFIG_DIR claude "))
        XCTAssertEqual(HarnessCommand.login(claude, account: named), "CLAUDE_CONFIG_DIR=/Users/me/.claude-work claude auth login")
    }

    func testMatchEvaluation() {
        let json = try? JSONSerialization.jsonObject(with: Data(#"{"loggedIn":true,"account":{"email":"a@b.c"}}"#.utf8))
        XCTAssertTrue(HarnessDetector.evaluate(.init(jsonKey: "loggedIn"), text: "", json: json, exit: 1))
        XCTAssertEqual(HarnessDetector.string(at: "account.email", in: json), "a@b.c")
        XCTAssertTrue(HarnessDetector.evaluate(.init(contains: "Logged in"), text: "Logged in using ChatGPT", json: nil, exit: 0))
        XCTAssertFalse(HarnessDetector.evaluate(.init(exitCode: 0), text: "", json: nil, exit: 1))
    }

    /// Detection end to end with a stand-in CLI: /bin/echo prints JSON as its "status".
    func testDetectsAccountsAndStatusWithAStandInCLI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hk-\(UUID())")
        for home in [".fake", ".fake-work", ".fake-play", ".fakeother"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(home), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let fake = HarnessDescriptor(
            id: "fake", name: "Fake", vendor: nil, executables: ["/bin/echo"],
            accounts: .init(env: "FAKE_HOME", default: root.appendingPathComponent(".fake").path, glob: root.appendingPathComponent(".fake-*").path),
            auth: .init(command: ["/bin/echo", #"{"ok":true,"who":"me@example.com"}"#], file: nil, signedIn: .init(jsonKey: "ok"), identity: .init(jsonKey: "who")),
            login: nil, logout: nil, launch: ["/bin/echo", "{prompt}"], readOnly: true, usage: nil, icon: nil, disabled: nil
        )
        let found = await HarnessDetector().detect([fake])
        XCTAssertEqual(found.first?.executable, "/bin/echo")
        XCTAssertEqual(found.first?.accounts.map(\.label), ["default", "play", "work"])
        XCTAssertTrue(found.first?.accounts.allSatisfy { $0.status == .signedIn && $0.identity == "me@example.com" } ?? false)
    }

    func testClaudeUsageParsesClaudeCodesOwnUsageText() {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 2% used · resets Sep 27 at 5:09pm (America/Los_Angeles)
        Current week (all models): 12% used · resets Oct 3 at 5:59pm (America/Los_Angeles)
        Current week (Fable): 21% used · resets Oct 3 at 5:59pm (America/Los_Angeles)

        What's contributing to your limits usage?
        """
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 12))!
        let windows = ClaudeUsageReader.windows(text, now: now)
        XCTAssertEqual(windows.map(\.label), ["Current session", "Weekly, all models", "Weekly, Fable"])
        XCTAssertEqual(windows.map(\.usedPercent), [2, 12, 21])
        let reset = calendar.dateComponents([.month, .day, .hour, .minute], from: windows[1].resetsAt!)
        XCTAssertEqual([reset.month, reset.day, reset.hour, reset.minute], [10, 3, 17, 59])

        // A reset early next year, seen in late December, lands in the next year.
        let december = calendar.date(from: DateComponents(year: 2026, month: 12, day: 30, hour: 12))!
        let rolled = ClaudeUsageReader.parseReset("Jan 2 at 9am (America/Los_Angeles)", now: december)!
        XCTAssertEqual(calendar.component(.year, from: rolled), 2027)
    }

    func testCodexWindowLabels() {
        XCTAssertEqual(CodexUsageReader.window("p", ["usedPercent": 12.4, "windowDurationMins": 300])?.label, "5-hour limit")
        XCTAssertEqual(CodexUsageReader.window("s", ["usedPercent": 1, "windowDurationMins": 10_080], prefix: "GPT-5")?.label, "GPT-5, weekly limit")
        XCTAssertEqual(CodexUsageReader.plan("chatgpt_pro"), "Chatgpt Pro")
    }
}
