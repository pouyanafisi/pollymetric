import XCTest
@testable import Pollymetric

/// Builds fake repositories and worktrees in a temporary folder, the way git lays them
/// out on disk. Nothing here reads or runs git, and nothing touches real project folders.
final class WorktreesTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pollymetric-worktrees-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    @discardableResult
    private func makeRepo(_ relative: String) throws -> URL {
        let repo = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git/worktrees"), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(to: repo.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
        return repo
    }

    /// A linked worktree: git's record in `<repo>/.git/worktrees/<name>` and a checkout
    /// with a `.git` file pointing back. `createFolder: false` leaves a stale record.
    @discardableResult
    private func addWorktree(to repo: URL, name: String, at checkout: URL, head: String = "ref: refs/heads/feature\n",
                             locked: Bool = false, createFolder: Bool = true, payload: Int = 0) throws -> URL {
        let admin = repo.appendingPathComponent(".git/worktrees/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try (checkout.appendingPathComponent(".git").path + "\n").write(to: admin.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        try head.write(to: admin.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: admin.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        if locked { try "agent is working".write(to: admin.appendingPathComponent("locked"), atomically: true, encoding: .utf8) }
        if createFolder {
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            try "gitdir: \(admin.path)\n".write(to: checkout.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            if payload > 0 {
                try Data(repeating: 7, count: payload).write(to: checkout.appendingPathComponent("payload.bin"))
            }
        }
        return admin
    }

    // MARK: Parsing

    func testParsesGitFileAbsoluteAndRelative() {
        let dir = URL(fileURLWithPath: "/projects/shop/.claude/worktrees/task")
        XCTAssertEqual(Worktrees.parseGitFile("gitdir: /projects/shop/.git/worktrees/task\n", relativeTo: dir)?.path,
                       "/projects/shop/.git/worktrees/task")
        XCTAssertEqual(Worktrees.parseGitFile("gitdir: ../../../.git/worktrees/task", relativeTo: dir)?.path,
                       "/projects/shop/.git/worktrees/task")
        XCTAssertNil(Worktrees.parseGitFile("not a git file", relativeTo: dir))
        XCTAssertNil(Worktrees.parseGitFile("gitdir:   \n", relativeTo: dir))
    }

    func testBranchFromHEAD() {
        XCTAssertEqual(Worktrees.branch(fromHEAD: "ref: refs/heads/fix/login\n"), "fix/login")
        XCTAssertEqual(Worktrees.branch(fromHEAD: "0123456789abcdef0123456789abcdef01234567\n"), "0123456")
        XCTAssertNil(Worktrees.branch(fromHEAD: "garbage"))
    }

    func testAgentInferenceFromPath() {
        let home = "/Users/me"
        XCTAssertEqual(Worktrees.agent(forPath: "/Users/me/Sites/shop/.claude/worktrees/agent-1", home: home), "Claude Code")
        XCTAssertEqual(Worktrees.agent(forPath: "/Users/me/.config/superpowers/worktrees/shop/task", home: home), "Claude Code")
        XCTAssertEqual(Worktrees.agent(forPath: "/Users/me/.codex/worktrees/a1b2/shop", home: home), "Codex")
        XCTAssertEqual(Worktrees.agent(forPath: "/Users/me/conductor/workspaces/shop/tokyo", home: home), "Conductor")
        XCTAssertEqual(Worktrees.agent(forPath: "/Users/me/.cursor/worktrees/shop/x1", home: home), "Cursor")
        XCTAssertEqual(Worktrees.agent(forPath: "/Users/me/.t3/worktrees/shop/x1", home: home), "T3 Code")
        XCTAssertNil(Worktrees.agent(forPath: "/Users/me/Sites/shop/.worktrees/feature", home: home))
        XCTAssertNil(Worktrees.agent(forPath: "/Users/me/Sites/shop-hotfix", home: home))
    }

    // MARK: Records

    func testReadsRecordsBranchLockAndStale() throws {
        let repo = try makeRepo("Sites/shop")
        let live = repo.appendingPathComponent(".claude/worktrees/agent-1")
        try addWorktree(to: repo, name: "agent-1", at: live, locked: true)
        try addWorktree(to: repo, name: "gone", at: repo.appendingPathComponent(".worktrees/gone"),
                        head: "abcdef0123456789abcdef0123456789abcdef01\n", createFolder: false)

        let entries = Worktrees.entries(ofRepository: repo, home: home).sorted { $0.name < $1.name }
        XCTAssertEqual(entries.count, 2)

        let first = entries[0]
        XCTAssertEqual(first.name, "agent-1")
        XCTAssertEqual(first.path, live.path)
        XCTAssertEqual(first.repo, "shop")
        XCTAssertEqual(first.repoPath, repo.path)
        XCTAssertEqual(first.branch, "feature")
        XCTAssertEqual(first.agent, "Claude Code")
        XCTAssertTrue(first.isLocked)
        XCTAssertFalse(first.isStale)
        XCTAssertNotNil(first.lastModified)

        let gone = entries[1]
        XCTAssertTrue(gone.isStale)
        XCTAssertEqual(gone.branch, "abcdef0")
        XCTAssertFalse(gone.isLocked)
    }

    func testMainRepositoryFromCheckout() throws {
        let repo = try makeRepo("elsewhere/api")
        let checkout = home.appendingPathComponent(".codex/worktrees/a1b2/api")
        try addWorktree(to: repo, name: "api", at: checkout)
        XCTAssertEqual(Worktrees.mainRepository(ofCheckout: checkout)?.path, repo.path)
    }

    // MARK: Discovery

    func testDiscoverySkipsDependenciesAndHiddenFolders() throws {
        let shop = try makeRepo("Sites/shop")
        try makeRepo("Sites/clients/acme/web")                       // depth 3
        try makeRepo("Sites/shop/node_modules/some-package")          // dependencies
        try makeRepo("Sites/.cache/tool")                             // hidden
        try makeRepo("Sites/a/b/c/d/e/too-deep")                      // beyond depth 4
        try addWorktree(to: shop, name: "task", at: root.appendingPathComponent("Sites/shop-task"))

        let found = Set(Worktrees.findRepositories(in: [root.appendingPathComponent("Sites")]).map(\.lastPathComponent))
        XCTAssertEqual(found, ["shop", "web"])
    }

    func testScanFindsProjectAndAgentWorktreesAndMeasuresThem() throws {
        let shop = try makeRepo("Sites/shop")
        try addWorktree(to: shop, name: "agent-1", at: shop.appendingPathComponent(".claude/worktrees/agent-1"), payload: 200_000)
        try addWorktree(to: shop, name: "old", at: shop.appendingPathComponent(".worktrees/old"), createFolder: false)

        // A repository outside the project folders whose only worktree lives in Codex's folder.
        let outside = try makeRepo("outside/api")
        try addWorktree(to: outside, name: "api", at: home.appendingPathComponent(".codex/worktrees/a1b2/api"), payload: 50_000)

        let report = Worktrees.scan(
            roots: [root.appendingPathComponent("Sites")],
            agentLocations: Worktrees.agentLocations(home: home),
            home: home,
            processes: [.init(name: "claude", cwd: shop.appendingPathComponent(".claude/worktrees/agent-1/src").path)]
        )

        XCTAssertEqual(report.worktrees.count, 3)
        XCTAssertEqual(report.present.count, 2)
        XCTAssertEqual(report.stale.map(\.name), ["old"])

        let claude = try XCTUnwrap(report.worktrees.first { $0.name == "agent-1" })
        XCTAssertGreaterThanOrEqual(claude.bytes, 200_000)
        XCTAssertEqual(claude.inUseBy, ["claude"])
        XCTAssertEqual(claude.agent, "Claude Code")

        let codex = try XCTUnwrap(report.worktrees.first { $0.repo == "api" })
        XCTAssertEqual(codex.agent, "Codex")
        XCTAssertGreaterThanOrEqual(codex.bytes, 50_000)
        XCTAssertTrue(codex.inUseBy.isEmpty)

        XCTAssertEqual(report.worktrees.first?.name, "agent-1", "largest first")
        XCTAssertEqual(report.totalBytes, claude.bytes + codex.bytes)
    }

    // MARK: Size and use

    func testMeasureSkipsNestedWorktreesAndHardLinks() throws {
        let outer = root.appendingPathComponent("outer")
        let nested = outer.appendingPathComponent(".claude/worktrees/inner")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: outer.appendingPathComponent("own.bin"))
        try Data(repeating: 2, count: 400_000).write(to: nested.appendingPathComponent("inner.bin"))
        // A file hard-linked from a shared store (pnpm) isn't freed by removing this folder.
        let store = root.appendingPathComponent("store.bin")
        try Data(repeating: 3, count: 300_000).write(to: store)
        try FileManager.default.linkItem(at: store, to: outer.appendingPathComponent("linked.bin"))

        let all = Worktrees.measure(outer)
        let skipped = Worktrees.measure(outer, skipping: [nested.path])
        XCTAssertGreaterThanOrEqual(all.bytes, 500_000)
        XCTAssertLessThan(all.bytes, 800_000, "hard-linked file excluded")
        XCTAssertGreaterThanOrEqual(skipped.bytes, 100_000)
        XCTAssertLessThan(skipped.bytes, 400_000)
        XCTAssertFalse(all.partial)
        XCTAssertNotNil(all.newest)
    }

    func testUsersMatchesFolderAndSubfoldersOnly() {
        let processes: [Worktrees.RunningFolder] = [
            .init(name: "node", cwd: "/p/shop/.claude/worktrees/a"),
            .init(name: "node", cwd: "/p/shop/.claude/worktrees/a/web"),
            .init(name: "zsh", cwd: "/p/shop/.claude/worktrees/ab"),
        ]
        XCTAssertEqual(Worktrees.users(of: "/p/shop/.claude/worktrees/a", among: processes), ["node"])
        XCTAssertEqual(Worktrees.users(of: "/p/shop/.claude/worktrees/ab", among: processes), ["zsh"])
    }

    func testPlainGitMessage() {
        let result = ShellResult(status: 128, stdout: "", stderr: "fatal: '/x' contains modified or untracked files, use --force to delete it\n")
        XCTAssertEqual(Worktrees.plainMessage(result), "it has changes that aren't committed, so nothing was removed.")
        let other = ShellResult(status: 128, stdout: "", stderr: "fatal: something unexpected\nmore detail\n")
        XCTAssertEqual(Worktrees.plainMessage(other), "something unexpected")
    }
}
