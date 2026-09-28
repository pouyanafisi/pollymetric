import XCTest
@testable import Pollymetric

/// Every fixture lives in a temporary home folder; no real config is ever read.
final class AgentExtensionsTests: XCTestCase {
    private var home: String!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("pollymetric-ext-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: home)
    }

    private func write(_ relative: String, _ text: String, executable: Bool = false) throws {
        let path = (home as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
    }

    private func scan(live: [[String]] = []) -> AgentExtensionsReport {
        AgentExtensions.scan(home: home) { _ in live }
    }

    /// The report as a string: what Pollymetric could show or hand to anything else.
    private func dump(_ report: AgentExtensionsReport) throws -> String {
        String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
    }

    // MARK: Claude Code

    func testClaudeCodeGlobalProjectAndProjectFileServers() throws {
        let project = home + "/code/shop"
        try write(".claude.json", """
        {
          "mcpServers": {
            "github": { "type": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                        "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_fixtureFixtureFixtureFixture1234", "LOG_LEVEL": "debug" } },
            "pinned": { "command": "npx", "args": ["-y", "some-mcp@1.2.3"], "env": { "API_KEY": "${API_KEY}" } },
            "docs": { "type": "http", "url": "https://mcp.example.com/mcp" },
            "legacy": { "type": "sse", "url": "http://mcp.example.org/sse" },
            "local": { "type": "http", "url": "http://localhost:3845/mcp" }
          },
          "oauthAccount": { "emailAddress": "someone@example.com" },
          "projects": {
            "\(project)": { "mcpServers": { "db": { "command": "uvx", "args": ["postgres-mcp"] } } },
            "\(home!)/gone": { "mcpServers": {} }
          }
        }
        """)
        try write("code/shop/.mcp.json", """
        { "mcpServers": { "browser": { "command": "/usr/local/bin/browser-mcp", "args": ["--port", "0"] } } }
        """)

        let servers = scan().servers
        XCTAssertEqual(Set(servers.map(\.name)), ["github", "pinned", "docs", "legacy", "local", "db", "browser"])
        XCTAssertTrue(servers.allSatisfy { $0.agent == "Claude Code" })

        let github = try XCTUnwrap(servers.first { $0.name == "github" })
        XCTAssertEqual(github.scope, "Global")
        XCTAssertEqual(github.transport, .local)
        XCTAssertEqual(github.command, "npx -y @modelcontextprotocol/server-github")
        XCTAssertEqual(github.envNames, ["GITHUB_PERSONAL_ACCESS_TOKEN", "LOG_LEVEL"])
        XCTAssertEqual(github.plaintextKeyNames, ["GITHUB_PERSONAL_ACCESS_TOKEN"])
        XCTAssertEqual(github.flags, [.unpinned, .plaintextKey])
        XCTAssertTrue(github.isWorthALook)
        XCTAssertEqual(github.configPath, home + "/.claude.json")

        let pinned = try XCTUnwrap(servers.first { $0.name == "pinned" })
        XCTAssertEqual(pinned.flags, [], "pinned version and an env reference are both fine")

        let docs = try XCTUnwrap(servers.first { $0.name == "docs" })
        XCTAssertEqual(docs.transport, .remote)
        XCTAssertEqual(docs.flags, [.remote])
        XCTAssertFalse(docs.isWorthALook)
        XCTAssertEqual(docs.host, "mcp.example.com")

        XCTAssertEqual(servers.first { $0.name == "legacy" }?.flags, [.unencrypted, .remote])
        XCTAssertEqual(servers.first { $0.name == "local" }?.flags, [], "plain http to this Mac isn't flagged")

        let db = try XCTUnwrap(servers.first { $0.name == "db" })
        XCTAssertEqual(db.scope, "shop")
        XCTAssertEqual(db.flags, [.unpinned])

        let browser = try XCTUnwrap(servers.first { $0.name == "browser" })
        XCTAssertEqual(browser.scope, "shop")
        XCTAssertEqual(browser.configPath, project + "/.mcp.json")

        let text = try dump(scan())
        XCTAssertFalse(text.contains("ghp_fixture"), "env values never reach the report")
        XCTAssertFalse(text.contains("debug"))
        XCTAssertFalse(text.contains("someone@example.com"))
    }

    func testAccountsMergeIntoOneRowAndLabelTheExtraAccount() throws {
        let server = #"{ "mcpServers": { "memory": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-memory@2025.1.1"] } } }"#
        try write(".claude.json", server)
        try write(".claude-work/.claude.json", server)
        try write(".claude-work/.claude.json.bak", "not read")
        try write(".claude-personal/.claude.json", #"{ "mcpServers": { "solo": { "command": "solo-mcp" } } }"#)

        let servers = scan().servers
        XCTAssertEqual(servers.count, 2)
        XCTAssertEqual(servers.first { $0.name == "memory" }?.accounts, ["Default", "work"])
        XCTAssertEqual(servers.first { $0.name == "solo" }?.accounts, ["personal"])
    }

    func testSkillsAndPlugins() throws {
        try write(".claude/skills/deploy/SKILL.md", """
        ---
        name: deploy
        description: >
          Ships the site to production.
          Use when asked to deploy.
        ---
        # Deploy
        """)
        try write(".claude/skills/deploy/scripts/run.sh", "#!/bin/sh\necho hi\n")
        try write(".claude/skills/notes/SKILL.md", "---\nname: \"Notes\"\ndescription: 'Keeps notes: short ones'\n---\nbody\n")
        try write(".claude/skills/tool/SKILL.md", "---\ndescription: |\n  First line.\n  Second line.\n---\n")
        try write(".claude/skills/tool/helper", "#!/bin/sh\n", executable: true)
        try write(".claude/skills/.trash/old/SKILL.md", "---\nname: old\n---\n")
        try write(".claude/skills/not-a-skill/README.md", "nothing")

        let install = home + "/.claude/plugins/cache/market/helper/1.0.0"
        try write(".claude/settings.json", #"{ "enabledPlugins": { "helper@market": true, "off@market": false } }"#)
        try write(".claude/plugins/installed_plugins.json", """
        { "version": 2, "plugins": {
            "helper@market": [ { "scope": "user", "installPath": "\(install)", "version": "1.0.0" } ],
            "off@market": [ { "scope": "user", "installPath": "\(home!)/.claude/plugins/cache/market/off/1.0.0" } ]
        } }
        """)
        try write(".claude/plugins/cache/market/off/1.0.0/.claude-plugin/plugin.json", #"{ "name": "off" }"#)
        try write(".claude/plugins/cache/market/helper/1.0.0/.claude-plugin/plugin.json",
                  #"{ "name": "helper", "description": "Helps.\nMore detail." }"#)
        try write(".claude/plugins/cache/market/helper/1.0.0/skills/review/SKILL.md", "---\nname: review\ndescription: Reviews code\n---\n")
        try write(".claude/plugins/cache/market/helper/1.0.0/.mcp.json",
                  #"{ "helper-server": { "command": "${CLAUDE_PLUGIN_ROOT}/bin/server", "args": ["--stdio"] } }"#)

        try write(".codex/skills/lint/SKILL.md", "---\nname: lint\ndescription: Lints\n---\n")

        let report = scan()
        let skills = report.skillsAndPlugins.filter { $0.kind == .skill }
        XCTAssertEqual(Set(skills.map(\.name)), ["deploy", "Notes", "tool", "review", "lint"])

        let deploy = try XCTUnwrap(skills.first { $0.name == "deploy" })
        XCTAssertEqual(deploy.summary, "Ships the site to production. Use when asked to deploy.")
        XCTAssertEqual(deploy.source, "Your skill")
        XCTAssertEqual(deploy.flags, [.runsScripts])
        XCTAssertEqual(skills.first { $0.name == "Notes" }?.summary, "Keeps notes: short ones")
        XCTAssertEqual(skills.first { $0.name == "Notes" }?.flags, [])
        XCTAssertEqual(skills.first { $0.name == "tool" }?.summary, "First line.")
        XCTAssertEqual(skills.first { $0.name == "tool" }?.flags, [.runsScripts], "an executable file counts")
        XCTAssertEqual(skills.first { $0.name == "review" }?.source, "helper")
        XCTAssertEqual(skills.first { $0.name == "lint" }?.agent, "Codex")

        let plugins = report.skillsAndPlugins.filter { $0.kind == .plugin }
        XCTAssertEqual(plugins.map(\.name), ["helper"], "a turned-off plugin isn't something the agent has")
        XCTAssertEqual(plugins.first?.summary, "Helps.")
        XCTAssertEqual(plugins.first?.skillCount, 1)
        XCTAssertEqual(plugins.first?.serverCount, 1)
        XCTAssertEqual(plugins.first?.source, "market")

        let server = try XCTUnwrap(report.servers.first { $0.name == "helper-server" })
        XCTAssertEqual(server.source, "helper")
        XCTAssertEqual(server.command, "~/.claude/plugins/cache/market/helper/1.0.0/bin/server --stdio")
    }

    // MARK: Codex and the rest

    func testCodexTOMLServers() throws {
        try write(".codex/config.toml", #"""
        model = "gpt-5"   # a comment

        [mcp_servers.context7]
        command = "npx"
        args = [
          "-y",   # the flag
          "@upstash/context7-mcp",
        ]

        [mcp_servers.context7.env]
        CONTEXT7_API_KEY = "ctx7-fixture-value"

        [mcp_servers."figma.remote"]
        url = "https://mcp.figma.com/mcp"
        bearer_token_env_var = "FIGMA_TOKEN"

        [mcp_servers.off]
        command = "uvx"
        args = ["mcp-server-fetch"]
        enabled = false

        [mcp_servers.inline]
        command = 'C:\tools\server'
        env = { SESSION_SECRET = "abc123", MODE = "fast" }
        env_vars = ["HOME_TOKEN"]

        [[profiles]]
        name = "ignored"
        """#)
        try write(".codex-work/config.toml", "[mcp_servers.work]\ncommand = \"work-mcp\"\n")

        let servers = scan().servers
        XCTAssertEqual(Set(servers.map(\.name)), ["context7", "figma.remote", "off", "inline", "work"])
        XCTAssertTrue(servers.allSatisfy { $0.agent == "Codex" })

        let context7 = try XCTUnwrap(servers.first { $0.name == "context7" })
        XCTAssertEqual(context7.command, "npx -y @upstash/context7-mcp")
        XCTAssertEqual(context7.envNames, ["CONTEXT7_API_KEY"])
        XCTAssertEqual(context7.flags, [.unpinned, .plaintextKey])

        let figma = try XCTUnwrap(servers.first { $0.name == "figma.remote" })
        XCTAssertEqual(figma.transport, .remote)
        XCTAssertEqual(figma.envNames, ["FIGMA_TOKEN"])
        XCTAssertEqual(figma.flags, [.remote])

        let off = try XCTUnwrap(servers.first { $0.name == "off" })
        XCTAssertFalse(off.isEnabled)
        XCTAssertEqual(off.flags, [], "a turned-off runner doesn't fetch anything")

        let inline = try XCTUnwrap(servers.first { $0.name == "inline" })
        XCTAssertEqual(inline.command, #"C:\tools\server"#)
        XCTAssertEqual(inline.envNames, ["MODE", "SESSION_SECRET", "HOME_TOKEN"])
        XCTAssertEqual(inline.plaintextKeyNames, ["SESSION_SECRET"])

        XCTAssertEqual(servers.first { $0.name == "work" }?.accounts, ["work"])
        XCTAssertFalse(try dump(scan()).contains("ctx7-fixture-value"))
        XCTAssertFalse(try dump(scan()).contains("abc123"))
    }

    func testOtherAgentsConfigFiles() throws {
        try write("Library/Application Support/Claude/claude_desktop_config.json",
                  #"{ "mcpServers": { "files": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"] } } }"#)
        try write(".cursor/mcp.json", #"{ "mcpServers": { "linear": { "url": "https://mcp.linear.app/sse" } } }"#)
        try write("Library/Application Support/Code/User/mcp.json", """
        {
          // VS Code allows comments
          "servers": {
            "playwright": { "type": "stdio", "command": "npx", "args": ["@playwright/mcp@latest"], },
            /* and block comments */
            "api": { "type": "http", "url": "https://api.example.com/mcp?api_key=fixture-secret&x=1",
                     "headers": { "Authorization": "Bearer ${input:token}" } }
          },
        }
        """)
        try write(".codeium/windsurf/mcp_config.json", #"{ "mcpServers": { "wind": { "serverUrl": "https://wind.example.com/mcp", "headers": { "X-API-Key": "fixture" } } } }"#)
        try write(".config/opencode/opencode.json", """
        { "mcp": { "oc": { "type": "local", "command": ["bunx", "oc-mcp"], "environment": { "OC_TOKEN": "{env:OC_TOKEN}" }, "enabled": true } } }
        """)

        let servers = scan().servers
        XCTAssertEqual(servers.map(\.agent), ["Claude Desktop", "Cursor", "VS Code", "VS Code", "Windsurf", "OpenCode"])

        XCTAssertEqual(servers.first { $0.name == "files" }?.flags, [.unpinned])
        XCTAssertEqual(servers.first { $0.name == "linear" }?.transport, .remote)
        XCTAssertEqual(servers.first { $0.name == "playwright" }?.flags, [.unpinned], "@latest is not a pin")

        let api = try XCTUnwrap(servers.first { $0.name == "api" })
        XCTAssertEqual(api.plaintextKeyNames, ["api_key"], "a header that references an input is fine")
        XCTAssertEqual(api.url, "https://api.example.com/mcp?api_key=••••&x=1")

        XCTAssertEqual(servers.first { $0.name == "wind" }?.plaintextKeyNames, ["X-API-Key"])

        let oc = try XCTUnwrap(servers.first { $0.name == "oc" })
        XCTAssertEqual(oc.command, "bunx oc-mcp")
        XCTAssertEqual(oc.envNames, ["OC_TOKEN"])
        XCTAssertEqual(oc.flags, [.unpinned])

        XCTAssertFalse(try dump(scan()).contains("fixture-secret"))
    }

    func testMissingFilesAndGarbageAreSkipped() throws {
        XCTAssertEqual(scan().items, [])
        try write(".claude.json", "{ not json")
        try write(".codex/config.toml", "[mcp_servers.x\ncommand = \"unterminated\n= = =\n[mcp_servers.ok]\ncommand = \"ok-mcp\"\n")
        XCTAssertEqual(scan().servers.map(\.name), ["ok"])
    }

    // MARK: Command lines

    func testCommandLinesAreRedactedAndArgumentKeysFlagged() throws {
        try write(".cursor/mcp.json", """
        { "mcpServers": {
          "pg": { "command": "postgres-mcp", "args": ["postgresql://admin:hunter2secret@db.example.com/app", "--api-key", "sk-fixturefixturefixture00"] },
          "ref": { "command": "tool-mcp", "args": ["--token", "${TOKEN}"] }
        } }
        """)
        let servers = scan().servers
        let pg = try XCTUnwrap(servers.first { $0.name == "pg" })
        XCTAssertEqual(pg.command, "postgres-mcp postgresql://admin:••••@db.example.com/app --api-key ••••")
        XCTAssertEqual(pg.flags, [.plaintextKey])
        XCTAssertEqual(pg.plaintextKeyNames.count, 2)

        XCTAssertEqual(servers.first { $0.name == "ref" }?.flags, [])
        let text = try dump(scan())
        XCTAssertFalse(text.contains("hunter2secret"))
        XCTAssertFalse(text.contains("sk-fixture"))
    }

    func testUnpinnedRunnerDetection() {
        func unpinned(_ line: String) -> Bool {
            let parts = line.split(separator: " ").map(String.init)
            return AgentExtensions.unpinnedPackage(command: parts[0], args: Array(parts.dropFirst())) != nil
        }
        XCTAssertTrue(unpinned("npx -y foo"))
        XCTAssertFalse(unpinned("npx -y foo@1.2.3"))
        XCTAssertTrue(unpinned("npx -y foo@latest"))
        XCTAssertTrue(unpinned("npx -y foo@^1.2.0"))
        XCTAssertTrue(unpinned("npx -y @scope/pkg"))
        XCTAssertFalse(unpinned("npx -y @scope/pkg@0.4.1"))
        XCTAssertFalse(unpinned("npx --package=@scope/pkg@2.0.0 run-it"))
        XCTAssertTrue(unpinned("/opt/homebrew/bin/npx -y foo"))
        XCTAssertFalse(unpinned("npx ./local/server.js"))
        XCTAssertTrue(unpinned("bunx foo"))
        XCTAssertTrue(unpinned("pnpm dlx foo"))
        XCTAssertFalse(unpinned("pnpm install"))
        XCTAssertTrue(unpinned("npm exec foo"))
        XCTAssertTrue(unpinned("uvx mcp-server-fetch"))
        XCTAssertFalse(unpinned("uvx mcp-server-fetch==0.6.2"))
        XCTAssertFalse(unpinned("uvx --from mcp-server-git==1.0.0 mcp-server-git"))
        XCTAssertTrue(unpinned("uvx --python 3.12 mcp-server-time"))
        XCTAssertTrue(unpinned("uv tool run serena"))
        XCTAssertFalse(unpinned("uv run server.py"))
        XCTAssertTrue(unpinned("pipx run some-tool"))
        XCTAssertFalse(unpinned("node server.js"))
        XCTAssertFalse(unpinned("docker run -i --rm mcp/fetch"))
    }

    func testSecretNamesAndLiteralValues() {
        for name in ["GITHUB_TOKEN", "OPENAI_API_KEY", "apiKey", "SESSION_SECRET", "DB_PASSWORD", "Authorization", "accessToken", "KEY", "SENTRY_DSN"] {
            XCTAssertTrue(AgentExtensions.looksSecret(name), name)
        }
        for name in ["LOG_LEVEL", "MONKEY_MODE", "HOME", "NODE_ENV", "AUTHOR", "KEYBOARD_LAYOUT"] {
            XCTAssertFalse(AgentExtensions.looksSecret(name), name)
        }
        XCTAssertTrue(AgentExtensions.isLiteral("abc123"))
        for reference in ["${GITHUB_TOKEN}", "$TOKEN", "{env:X}", "<your-token>", "YOUR_API_KEY", "", "  "] {
            XCTAssertFalse(AgentExtensions.isLiteral(reference), reference)
        }
    }

    // MARK: TOML

    func testTOMLSubsetEdgeCases() {
        let parsed = MiniTOML.parse(#"""
        top = "value" # trailing comment
        n = 1_000
        f = 3.5
        yes = true
        "quoted key" = 'literal \n stays'
        a.b.c = "dotted"
        escapes = "tab\tquote\"unicode\u00e9"
        multi = """
        line one
        line two"""
        folded = """\
          joined \
          up"""
        raw = '''
        C:\path\'''
        list = [ "x", 'y', [1, 2], { k = "v" } ]
        empty = []
        hash = "not # a comment"

        [server]
        inline = { name = "n", nested = { deep = true } }

        [server.child]
        leaf = "ok"

        [[array.of.tables]]
        skipped = "yes"

        [after]
        kept = "yes"
        """#)

        XCTAssertEqual(parsed["top"] as? String, "value")
        XCTAssertEqual(parsed["n"] as? Int, 1000)
        XCTAssertEqual(parsed["f"] as? Double, 3.5)
        XCTAssertEqual(parsed["yes"] as? Bool, true)
        XCTAssertEqual(parsed["quoted key"] as? String, #"literal \n stays"#)
        XCTAssertEqual(((parsed["a"] as? [String: Any])?["b"] as? [String: Any])?["c"] as? String, "dotted")
        XCTAssertEqual(parsed["escapes"] as? String, "tab\tquote\"unicodeé")
        XCTAssertEqual(parsed["multi"] as? String, "line one\nline two")
        XCTAssertEqual(parsed["folded"] as? String, "joined up")
        XCTAssertEqual(parsed["raw"] as? String, #"C:\path\"#)
        let list = parsed["list"] as? [Any]
        XCTAssertEqual(list?.count, 4)
        XCTAssertEqual(list?.first as? String, "x")
        XCTAssertEqual((list?[2] as? [Int]), [1, 2])
        XCTAssertEqual((list?[3] as? [String: Any])?["k"] as? String, "v")
        XCTAssertEqual((parsed["empty"] as? [Any])?.count, 0)
        XCTAssertEqual(parsed["hash"] as? String, "not # a comment")

        let server = parsed["server"] as? [String: Any]
        let inline = server?["inline"] as? [String: Any]
        XCTAssertEqual(inline?["name"] as? String, "n")
        XCTAssertEqual((inline?["nested"] as? [String: Any])?["deep"] as? Bool, true)
        XCTAssertEqual((server?["child"] as? [String: Any])?["leaf"] as? String, "ok")
        XCTAssertNil(parsed["array"], "arrays of tables are skipped")
        XCTAssertEqual((parsed["after"] as? [String: Any])?["kept"] as? String, "yes")
    }

    // MARK: Running now

    func testRunningNowMatchesLiveProcesses() throws {
        try write(".cursor/mcp.json", """
        { "mcpServers": {
          "npx-title": { "command": "npx", "args": ["-y", "tavily-mcp@latest"] },
          "child": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"] },
          "script": { "command": "node", "args": ["~/servers/index.js"] },
          "uv": { "command": "uvx", "args": ["mcp-server-fetch"] },
          "idle": { "command": "npx", "args": ["-y", "idle-mcp"] },
          "bare-node": { "command": "node" }
        } }
        """)
        let live = [
            ["npm exec tavily-mcp@latest"],
            ["node", "/Users/x/.npm/_npx/abc/node_modules/.bin/server-github"],
            ["node", home + "/servers/index.js"],
            ["/Users/x/.local/bin/uv", "tool", "uvx", "mcp-server-fetch"],
            ["node", "/some/other.js"],
        ]
        let running = Set(scan(live: live).servers.filter(\.isRunning).map(\.name))
        XCTAssertEqual(running, ["npx-title", "child", "script", "uv"])
    }

    func testRedactURL() {
        XCTAssertEqual(AgentExtensions.redactURL("https://user:pw123456@host.example/mcp"), "https://user:••••@host.example/mcp")
        XCTAssertEqual(AgentExtensions.redactURL("https://host.example/mcp?token=abc&x=1"), "https://host.example/mcp?token=••••&x=1")
        XCTAssertEqual(AgentExtensions.redactURL("https://host.example/mcp"), "https://host.example/mcp")
    }
}
