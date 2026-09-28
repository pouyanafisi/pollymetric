import AppKit
import Darwin
import SwiftUI

/// Extra working copies of your projects (git worktrees), often left behind by agents
/// after a task: how much space each holds, and whether anything still depends on it.
struct WorktreesReport: Codable, Sendable, Equatable {
    var worktrees: [Worktree] = []

    /// Space held by copies that still exist. Records whose folder is gone hold nothing.
    var totalBytes: Int64 { worktrees.reduce(0) { $0 + $1.bytes } }
    var present: [Worktree] { worktrees.filter { !$0.isStale } }
    var stale: [Worktree] { worktrees.filter(\.isStale) }

    /// Worktrees not touched since `date`.
    func untouched(since date: Date) -> [Worktree] {
        present.filter { ($0.lastModified ?? .distantPast) < date }
    }
}

struct Worktree: Codable, Sendable, Equatable, Identifiable {
    var id: String { path }
    /// The worktree's folder. For a stale record, where the folder used to be.
    var path: String
    /// The project it's a copy of, and that project's main folder (where git runs).
    var repo: String = ""
    var repoPath: String = ""
    /// Git's name for the record (`.git/worktrees/<name>`).
    var name: String = ""
    /// Branch checked out, or a short commit id when detached.
    var branch: String?
    /// The agent that likely created it, inferred from where it lives.
    var agent: String?
    var lastModified: Date?
    /// Allocated size on disk, not counting files shared with other folders through hard links.
    var bytes: Int64 = 0
    /// The size walk stopped early; the real size is larger.
    var sizeIsPartial = false
    /// Someone marked it to be kept (`git worktree lock`).
    var isLocked = false
    /// The record exists but the folder is gone (git calls these prunable).
    var isStale = false
    /// Programs working in this folder when it was scanned.
    var inUseBy: [String] = []

    var title: String { branch ?? (path as NSString).lastPathComponent }
}

enum Worktrees {
    // MARK: Scan

    static func scan() async throws -> WorktreesReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = ProjectFolders.roots
        // File-system work blocks, so keep it off the cooperative pool.
        return await Task.detached(priority: .utility) {
            scan(roots: roots, agentLocations: agentLocations(home: home), home: home, processes: processFolders())
        }.value
    }

    /// Finds every worktree of every repository under `roots`, plus worktrees in agents'
    /// own folders (whose main repository may live anywhere), and measures them.
    static func scan(
        roots: [URL],
        agentLocations: [URL],
        home: URL,
        processes: [RunningFolder] = [],
        budget: TimeInterval = 240
    ) -> WorktreesReport {
        var repos = findRepositories(in: roots)
        for checkout in findCheckouts(in: agentLocations) {
            if let repo = mainRepository(ofCheckout: checkout) { repos.append(repo) }
        }

        var seenRepos = Set<String>()
        var seenPaths = Set<String>()
        var found: [Worktree] = []
        for repo in repos where seenRepos.insert(repo.standardizedFileURL.path).inserted {
            for entry in entries(ofRepository: repo, home: home) where seenPaths.insert(entry.path).inserted {
                found.append(entry)
            }
        }

        // Three folders at a time under one overall time budget, so a Mac with hundreds of
        // copies can't stall the scan; whatever's left over is marked as partly measured.
        let deadline = Date().addingTimeInterval(budget)
        let allPaths = Set(found.filter { !$0.isStale }.map(\.path))
        let pending = found.indices.filter { !found[$0].isStale }
        let paths = found.map(\.path)
        let lock = NSLock()
        var next = 0
        var measured: [Int: (bytes: Int64, newest: Date?, partial: Bool)] = [:]
        DispatchQueue.concurrentPerform(iterations: min(3, pending.count)) { _ in
            while true {
                let index: Int? = lock.withLock {
                    defer { next += 1 }
                    return next < pending.count ? pending[next] : nil
                }
                guard let index else { return }
                let path = paths[index]
                let nested = allPaths.filter { $0 != path && $0.hasPrefix(path + "/") }
                let result = measure(URL(fileURLWithPath: path), skipping: nested, deadline: deadline)
                lock.withLock { measured[index] = result }
            }
        }
        for (i, result) in measured {
            found[i].bytes = result.bytes
            found[i].sizeIsPartial = result.partial
            found[i].lastModified = [found[i].lastModified, result.newest].compactMap { $0 }.max()
            found[i].inUseBy = users(of: found[i].path, among: processes)
        }
        return WorktreesReport(worktrees: found.sorted { $0.bytes > $1.bytes })
    }

    // MARK: Where agents keep worktrees

    /// Folders where agents create worktrees outside your projects. Worktrees inside a
    /// project (`.claude/worktrees`, `.worktrees`) are found through the project itself.
    static func agentLocations(home: URL) -> [URL] {
        [
            ".codex/worktrees",                 // Codex app: ~/.codex/worktrees/<id>/<repo>
            "conductor/workspaces",             // Conductor: ~/conductor/workspaces/<repo>/<name>
            ".cursor/worktrees",                // Cursor: ~/.cursor/worktrees/<repo>/<name>
            ".t3/worktrees",                    // T3 Code
            ".config/superpowers/worktrees",    // Superpowers plugin for Claude Code: <project>/<name>
        ].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// The agent that most likely created a worktree, from where it lives.
    static func agent(forPath path: String, home: String = Paths.home) -> String? {
        let rules: [(String, String)] = [
            ("/.claude/worktrees/", "Claude Code"),
            (home + "/.config/superpowers/worktrees/", "Claude Code"),
            (home + "/.codex/", "Codex"),
            ("/conductor/workspaces/", "Conductor"),
            ("/.cursor/worktrees/", "Cursor"),
            (home + "/.t3/worktrees/", "T3 Code"),
        ]
        let probe = path.hasSuffix("/") ? path : path + "/"
        return rules.first { probe.contains($0.0) }?.1
    }

    // MARK: Discovery (reads files; never runs git)

    /// Folders never worth descending into: dependencies, build output, system folders.
    static let skippedFolders: Set<String> = [
        "node_modules", "Library", "Applications", "Pictures", "Music", "Movies",
        "build", "dist", "out", "target", "vendor", "Pods", "DerivedData",
        "venv", "env", "__pycache__", "site-packages", "bower_components",
    ]

    /// Main repositories (folders with a `.git` directory) under `roots`, `depth` levels deep.
    static func findRepositories(in roots: [URL], depth: Int = 4) -> [URL] {
        var repos: [URL] = []
        func walk(_ dir: URL, _ level: Int) {
            let git = dir.appendingPathComponent(".git")
            switch kind(of: git) {
            case .directory: repos.append(dir)
            case .file: return // a worktree or submodule checkout; its repository is elsewhere
            case nil: break
            }
            guard level < depth else { return }
            for child in subdirectories(of: dir)
            where !child.lastPathComponent.hasPrefix(".") && !skippedFolders.contains(child.lastPathComponent) {
                walk(child, level + 1)
            }
        }
        roots.forEach { walk($0, 0) }
        return repos
    }

    /// Worktree checkouts (folders whose `.git` is a file) inside agent locations.
    static func findCheckouts(in locations: [URL], depth: Int = 3) -> [URL] {
        var checkouts: [URL] = []
        func walk(_ dir: URL, _ level: Int) {
            if kind(of: dir.appendingPathComponent(".git")) == .file {
                checkouts.append(dir)
                return
            }
            guard level < depth else { return }
            for child in subdirectories(of: dir) where !skippedFolders.contains(child.lastPathComponent) {
                walk(child, level + 1)
            }
        }
        locations.forEach { walk($0, 0) }
        return checkouts
    }

    /// The main repository's folder for a worktree checkout: `.git` file → git's record of
    /// the worktree → its `commondir` → the repository's `.git`.
    static func mainRepository(ofCheckout checkout: URL) -> URL? {
        guard let text = try? String(contentsOf: checkout.appendingPathComponent(".git"), encoding: .utf8),
              let admin = parseGitFile(text, relativeTo: checkout)
        else { return nil }
        let common: URL
        if let commondir = try? String(contentsOf: admin.appendingPathComponent("commondir"), encoding: .utf8) {
            common = resolve(commondir.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: admin)
        } else {
            common = admin.deletingLastPathComponent().deletingLastPathComponent() // <repo>/.git/worktrees/<name>
        }
        guard kind(of: common) == .directory else { return nil }
        // A normal repository's common dir is `<repo>/.git`; a bare one is the repository itself.
        return common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : common
    }

    /// Git's records of a repository's linked worktrees, from `.git/worktrees/<name>/`.
    static func entries(ofRepository repo: URL, home: URL) -> [Worktree] {
        let gitDir = kind(of: repo.appendingPathComponent(".git")) == .directory ? repo.appendingPathComponent(".git") : repo
        let repoName = repo.lastPathComponent.hasSuffix(".git")
            ? String(repo.lastPathComponent.dropLast(4)) : repo.lastPathComponent
        return subdirectories(of: gitDir.appendingPathComponent("worktrees")).map { admin in
            var entry = Worktree(path: admin.path, repo: repoName, repoPath: repo.path, name: admin.lastPathComponent)
            let target = (try? String(contentsOf: admin.appendingPathComponent("gitdir"), encoding: .utf8))
                .map { resolve($0.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: admin) }
            if let target {
                // gitdir points at the worktree's `.git` file.
                entry.path = target.deletingLastPathComponent().standardizedFileURL.path
                entry.isStale = !FileManager.default.fileExists(atPath: target.path)
            } else {
                entry.isStale = true // no gitdir file: git prunes these too
            }
            if let head = try? String(contentsOf: admin.appendingPathComponent("HEAD"), encoding: .utf8) {
                entry.branch = branch(fromHEAD: head)
            }
            entry.isLocked = FileManager.default.fileExists(atPath: admin.appendingPathComponent("locked").path)
            entry.agent = agent(forPath: entry.path, home: home.path)
            // Git touches these on every checkout, commit and status.
            entry.lastModified = ["index", "HEAD", "logs/HEAD"]
                .compactMap { modified(admin.appendingPathComponent($0)) }
                .max()
            return entry
        }
    }

    /// The `gitdir:` target of a `.git` file, resolved against the folder holding it.
    static func parseGitFile(_ text: String, relativeTo dir: URL) -> URL? {
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("gitdir:") else { continue }
            let value = trimmed.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : resolve(value, relativeTo: dir)
        }
        return nil
    }

    /// "ref: refs/heads/fix/login" → "fix/login"; a detached commit → its short id.
    static func branch(fromHEAD text: String) -> String? {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref:") {
            let ref = head.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : (ref.isEmpty ? nil : ref)
        }
        let isSHA = head.count >= 7 && head.allSatisfy(\.isHexDigit)
        return isSHA ? String(head.prefix(7)) : nil
    }

    // MARK: Size

    /// Allocated size of a folder, without following symbolic links or crossing onto other
    /// volumes, and the newest modification time inside it. Files hard-linked from
    /// elsewhere (pnpm's store) are skipped: removing this folder wouldn't free them.
    /// Uses fts rather than FileManager's enumerator: same numbers, about five times faster.
    static func measure(_ folder: URL, skipping nested: Set<String> = [], deadline: Date = .distantFuture,
                        maxFiles: Int = 4_000_000) -> (bytes: Int64, newest: Date?, partial: Bool) {
        guard let root = strdup(folder.path) else { return (0, nil, false) }
        defer { free(root) }
        var paths: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let walker = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return (0, nil, false) }
        defer { fts_close(walker) }

        var bytes: Int64 = 0
        var newest: time_t = 0
        var files = 0
        func result(partial: Bool) -> (Int64, Date?, Bool) {
            (bytes, newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil, partial)
        }
        while let entry = fts_read(walker) {
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                if !nested.isEmpty, nested.contains(String(cString: entry.pointee.fts_path)) {
                    fts_set(walker, entry, FTS_SKIP)
                    continue
                }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                files += 1
                if files % 2_000 == 0, files >= maxFiles || Date() > deadline { return result(partial: true) }
            default:
                continue // directories on the way out, unreadable entries
            }
            guard let stat = entry.pointee.fts_statp?.pointee else { continue }
            newest = max(newest, stat.st_mtimespec.tv_sec)
            if info != FTS_D, stat.st_nlink <= 1 { bytes += Int64(stat.st_blocks) * 512 }
        }
        return result(partial: false)
    }

    // MARK: In use

    struct RunningFolder: Sendable, Equatable {
        var name: String
        var cwd: String
    }

    /// Every one of your processes and the folder it's working in, through libproc.
    static func processFolders() -> [RunningFolder] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let me = getpid()
        return pids.prefix(Int(max(0, count))).compactMap { pid in
            guard pid > 0, pid != me else { return nil }
            var info = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
            let cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            guard !cwd.isEmpty else { return nil }
            var buffer = [CChar](repeating: 0, count: 256)
            var name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : "a process"
            if name.first?.isNumber == true { // versioned binaries: …/claude/versions/2.1.283 → claude
                name = IdentityResolver.friendlyName(name, executable: IdentityResolver.path(pid: pid), argv0: nil)
            }
            return RunningFolder(name: name, cwd: cwd)
        }
    }

    /// Names of the programs working inside `path`, deduplicated.
    static func users(of path: String, among processes: [RunningFolder]) -> [String] {
        let variants = Set([path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path])
        var names: [String] = []
        for process in processes where variants.contains(where: { process.cwd == $0 || process.cwd.hasPrefix($0 + "/") }) {
            if !names.contains(process.name) { names.append(process.name) }
        }
        return names
    }

    // MARK: Git (only for status, remove and prune)

    /// Runs git on a folder the user chose, disclaimed so a repository's own config can't
    /// borrow Pollymetric's Full Disk Access, with fsmonitor and trace hooks switched off.
    static func git(_ arguments: [String], in folder: String, timeout: TimeInterval = 60) async throws -> ShellResult {
        try await Shell.run("/usr/bin/git", [
            "-C", folder,
            "-c", "core.fsmonitor=false",
            "-c", "trace2.eventTarget=0", "-c", "trace2.normalTarget=0", "-c", "trace2.perfTarget=0",
        ] + arguments, disclaim: true, timeout: timeout)
    }

    enum Changes: Equatable {
        case checking, clean, unsaved(Int), unknown
    }

    static func changes(in worktree: Worktree) async -> Changes {
        guard let result = try? await git(["status", "--porcelain"], in: worktree.path), result.status == 0 else { return .unknown }
        let count = result.stdout.split(whereSeparator: \.isNewline).count
        return count == 0 ? .clean : .unsaved(count)
    }

    /// Git's complaint in plain words. Known refusals are rephrased; anything else is its
    /// first line without the "fatal:" prefix.
    static func plainMessage(_ result: ShellResult) -> String {
        let text = result.stderr.isEmpty ? result.stdout : result.stderr
        let known: [(String, String)] = [
            ("contains modified or untracked files", "it has changes that aren't committed, so nothing was removed."),
            ("is a main working tree", "that's the project itself, not an extra copy."),
            ("is locked", "it's locked, so someone meant to keep it."),
            ("submodule", "it contains submodules, which git won't remove on its own."),
        ]
        if let match = known.first(where: { text.contains($0.0) }) { return match.1 }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "git stopped with code \(result.status)."
        return line.replacingOccurrences(of: #"^(fatal|error): "#, with: "", options: .regularExpression)
    }

    // MARK: File helpers

    enum Kind { case file, directory }

    static func kind(of url: URL) -> Kind? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? .directory : .file
    }

    /// Real subfolders, not symbolic links to folders.
    private static func subdirectories(of dir: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return [] }
        return children.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    private static func resolve(_ path: String, relativeTo dir: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)).standardizedFileURL
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

// MARK: - Page

/// Checks for unsaved changes as rows come into view, two at a time, so a project with
/// dozens of copies doesn't start dozens of git processes at once.
@MainActor
@Observable
final class WorktreeChangeChecker {
    private(set) var results: [String: Worktrees.Changes] = [:]
    @ObservationIgnored private var queue: [Worktree] = []
    @ObservationIgnored private var running = 0

    func check(_ worktree: Worktree) {
        guard !worktree.isStale, results[worktree.path] == nil else { return }
        results[worktree.path] = .checking
        queue.append(worktree)
        pump()
    }

    func set(_ changes: Worktrees.Changes, for path: String) { results[path] = changes }

    func reset() {
        queue.removeAll()
        results.removeAll()
    }

    private func pump() {
        while running < 2, !queue.isEmpty {
            let next = queue.removeFirst()
            running += 1
            Task {
                let changes = await Worktrees.changes(in: next)
                running -= 1
                if results[next.path] == .checking { results[next.path] = changes }
                pump()
            }
        }
    }
}

struct WorktreesPage: View {
    @Bindable var store: AppStore
    @State private var checker = WorktreeChangeChecker()
    @State private var liveUsers: [String: [String]]?
    @State private var busy: Set<String> = []
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Worktrees",
                subtitle: "Extra copies of your projects that agents create for each task, and the space they hold.",
                updatedAt: store.worktrees.updatedAt, isFetching: store.worktrees.isFetching, error: store.worktrees.error,
                refresh: { store.worktrees.refresh() }
            )

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let report = store.worktrees.value {
                if report.worktrees.isEmpty {
                    EmptyState(symbol: "arrow.triangle.branch", title: "No extra worktrees",
                               message: "None of your projects have extra copies lying around.")
                } else {
                    if !report.present.isEmpty {
                        Hero(value: Bytes.format(report.totalBytes), caption: caption(report)) { EmptyView() }
                    }
                    ForEach(groups(report), id: \.repoPath) { group in
                        groupCard(group)
                    }
                }
            } else if store.worktrees.isFetching {
                EmptyState(symbol: "arrow.triangle.branch", title: "Looking for worktrees…",
                           message: "Measuring the extra copies of your projects. This runs quietly in the background.")
            } else {
                EmptyState(symbol: "arrow.triangle.branch", title: "No scan yet",
                           message: "Click the refresh button to find extra copies of your projects.")
            }
        }
        .onAppear {
            store.worktrees.refreshIfStale()
            refreshUsers()
        }
        .onChange(of: store.worktrees.updatedAt) {
            checker.reset()
            refreshUsers()
        }
    }

    // MARK: Pieces

    private struct RepoGroup {
        var repo: String
        var repoPath: String
        var worktrees: [Worktree]
        var bytes: Int64 { worktrees.reduce(0) { $0 + $1.bytes } }
        var hasStale: Bool { worktrees.contains(where: \.isStale) }
    }

    private func groups(_ report: WorktreesReport) -> [RepoGroup] {
        Dictionary(grouping: report.worktrees, by: \.repoPath)
            .map { path, items in
                RepoGroup(repo: items[0].repo, repoPath: path, worktrees: items.sorted {
                    $0.isStale != $1.isStale ? !$0.isStale : $0.bytes > $1.bytes
                })
            }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.repo < $1.repo }
    }

    private func caption(_ report: WorktreesReport) -> String {
        let count = report.present.count
        var parts = ["held by \(count) worktree\(count == 1 ? "" : "s")"]
        let idle = report.untouched(since: Date().addingTimeInterval(-7 * 86_400)).count
        if idle > 0 { parts.append("\(idle) \(idle == 1 ? "hasn't" : "haven't") been touched in a week") }
        if !report.stale.isEmpty { parts.append("\(report.stale.count) with folder gone") }
        return parts.joined(separator: " · ")
    }

    private func groupCard(_ group: RepoGroup) -> some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(group.repo).font(.headline)
                Text("\(group.worktrees.count)").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                if group.hasStale {
                    Button("Clean Up Stale Entries") { prune(group) }
                        .buttonStyle(.link)
                        .font(.caption)
                        .disabled(busy.contains(group.repoPath))
                        .help("Forget the copies whose folders are already gone. Nothing on disk changes.")
                }
                Text(Bytes.format(group.bytes)).monospacedDigit().foregroundStyle(.secondary)
            }
            LazyVStack(spacing: 0) {
                ForEach(group.worktrees) { worktree in
                    WorktreeRow(
                        worktree: worktree,
                        users: users(worktree),
                        changes: checker.results[worktree.path],
                        isBusy: busy.contains(worktree.path),
                        remove: { remove(worktree) }
                    )
                    .onAppear { checker.check(worktree) }
                    if worktree.id != group.worktrees.last?.id { Divider() }
                }
            }
        }
    }

    private func users(_ worktree: Worktree) -> [String] {
        liveUsers?[worktree.path] ?? worktree.inUseBy
    }

    /// Who's working in each folder right now; the scan's answer may be half an hour old.
    private func refreshUsers() {
        guard let report = store.worktrees.value else { return }
        let paths = report.present.map(\.path)
        Task {
            let found = await Task.detached(priority: .utility) { () -> [String: [String]] in
                let processes = Worktrees.processFolders()
                return Dictionary(uniqueKeysWithValues: paths.map { ($0, Worktrees.users(of: $0, among: processes)) })
            }.value
            liveUsers = found
        }
    }

    // MARK: Actions

    private func remove(_ worktree: Worktree) {
        guard !worktree.isStale, !worktree.isLocked, !busy.contains(worktree.path) else { return }
        // Never a main repository: a worktree's `.git` is a file, a repository's is a folder.
        guard Worktrees.kind(of: URL(fileURLWithPath: worktree.path).appendingPathComponent(".git")) == .file,
              URL(fileURLWithPath: worktree.path).standardizedFileURL != URL(fileURLWithPath: worktree.repoPath).standardizedFileURL
        else {
            failure = "\(worktree.path) isn't an extra copy, so Pollymetric won't remove it."
            return
        }
        failure = nil
        busy.insert(worktree.path)
        Task {
            // Fresh answers, not the ones on screen.
            async let changes = Worktrees.changes(in: worktree)
            let running = await Task.detached(priority: .userInitiated) {
                Worktrees.users(of: worktree.path, among: Worktrees.processFolders())
            }.value
            let current = await changes
            checker.set(current, for: worktree.path)
            liveUsers?[worktree.path] = running

            guard let force = confirmRemoval(worktree, changes: current, users: running) else {
                busy.remove(worktree.path)
                return
            }
            let arguments = ["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.path]
            do {
                let result = try await Worktrees.git(arguments, in: worktree.repoPath, timeout: 600)
                if result.status != 0 {
                    failure = "Couldn't remove \(worktree.title): \(Worktrees.plainMessage(result))"
                }
            } catch {
                failure = "Couldn't remove \(worktree.title): \(error.localizedDescription)"
            }
            busy.remove(worktree.path)
            store.worktrees.refresh()
        }
    }

    /// Asks before removing. Returns nil to cancel, or whether to discard unsaved changes.
    private func confirmRemoval(_ worktree: Worktree, changes: Worktrees.Changes, users: [String]) -> Bool? {
        var details = ["Removes the folder and git's record of it"
            + (worktree.bytes > 0 ? ", freeing about \(Bytes.format(worktree.bytes))." : ".")]
        details.append(worktree.branch.map { "The branch \($0) stays in the \(worktree.repo) repository." }
            ?? "Everything already committed stays in the \(worktree.repo) repository.")
        let risky: Bool
        switch changes {
        case .unsaved(let count):
            details.append("It has \(count) unsaved change\(count == 1 ? "" : "s") that aren't committed anywhere. Removing it deletes them.")
            risky = true
        case .unknown, .checking:
            details.append("Pollymetric couldn't check it for unsaved changes. If it has any, git will refuse and nothing is removed.")
            risky = true
        case .clean:
            risky = false
        }
        if !users.isEmpty {
            details.append("\(ListFormatter.localizedString(byJoining: users)) \(users.count == 1 ? "is" : "are") working in this folder right now and may break if it disappears.")
        }

        let alert = NSAlert()
        alert.alertStyle = risky || !users.isEmpty ? .critical : .warning
        alert.messageText = "Remove the \(worktree.title) worktree of \(worktree.repo)?"
        alert.informativeText = details.joined(separator: "\n\n")
        if risky || !users.isEmpty {
            // Cancel is the default: Return must never lose work.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Remove").hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return nil }
        } else {
            alert.addButton(withTitle: "Remove").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }

        guard case .unsaved(let count) = changes else { return false }
        let second = NSAlert()
        second.alertStyle = .critical
        second.messageText = "Delete \(count) unsaved change\(count == 1 ? "" : "s") in \(worktree.title)?"
        second.informativeText = "They exist only in this folder. This can't be undone."
        second.addButton(withTitle: "Cancel")
        second.addButton(withTitle: "Delete Changes and Remove").hasDestructiveAction = true
        return second.runModal() == .alertSecondButtonReturn ? true : nil
    }

    private func prune(_ group: RepoGroup) {
        failure = nil
        busy.insert(group.repoPath)
        Task {
            do {
                let result = try await Worktrees.git(["worktree", "prune"], in: group.repoPath)
                if result.status != 0 { failure = "Couldn't clean up \(group.repo): \(Worktrees.plainMessage(result))" }
            } catch {
                failure = "Couldn't clean up \(group.repo): \(error.localizedDescription)"
            }
            busy.remove(group.repoPath)
            store.worktrees.refresh()
        }
    }
}

private struct WorktreeRow: View {
    var worktree: Worktree
    var users: [String]
    var changes: Worktrees.Changes?
    var isBusy: Bool
    var remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(worktree.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let agent = worktree.agent { WorktreeTag(text: agent, color: nil) }
                    if worktree.isStale { WorktreeTag(text: "Folder is gone", color: nil) }
                    if !users.isEmpty {
                        WorktreeTag(text: "In use", color: HealthBand.excellent.color)
                            .help("\(ListFormatter.localizedString(byJoining: users)) \(users.count == 1 ? "is" : "are") working here")
                    }
                    if case .unsaved(let count) = changes {
                        WorktreeTag(text: "Unsaved changes", color: .orange)
                            .help("\(count) change\(count == 1 ? "" : "s") not committed")
                    }
                    if worktree.isLocked {
                        WorktreeTag(text: "Locked", color: nil)
                            .help("Someone marked this copy to be kept, so Pollymetric won't remove it.")
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(worktree.path)
            }
            Spacer(minLength: 8)
            if hovering, !worktree.isStale {
                Button { Paths.reveal(worktree.path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
            if isBusy {
                ProgressView().controlSize(.small)
            } else if !worktree.isStale {
                Button("Remove…", action: remove)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(worktree.isLocked)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if !worktree.isStale {
                Button("Show in Finder") { Paths.reveal(worktree.path) }
            }
            Button("Copy Path") { Paths.copy(worktree.path) }
            if !worktree.isStale, !worktree.isLocked {
                Divider()
                Button("Remove…", action: remove)
            }
        }
    }

    private var detail: String {
        let path = Paths.abbreviate(worktree.path)
        if worktree.isStale { return "Was at \(path)" }
        let size = (worktree.sizeIsPartial ? "more than " : "") + Bytes.format(worktree.bytes)
        let touched = worktree.lastModified.map { "last touched \(Relative.string($0))" }
        return [size, touched, path].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct WorktreeTag: View {
    var text: String
    var color: Color?

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background((color ?? .primary).opacity(color == nil ? 0.07 : 0.14), in: Capsule())
            .fixedSize()
    }
}
