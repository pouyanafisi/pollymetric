import AppKit
import Foundation
import Observation
import ServiceManagement
import HarnessKit

/// A destructive run (clean or purge) and its live output.
@MainActor
@Observable
final class Job {
    enum Kind { case clean, purge }
    enum State: Equatable { case running, finished(freed: Int64), failed(String) }

    let kind: Kind
    private(set) var lines: [String] = []
    private(set) var state: State = .running

    init(kind: Kind) { self.kind = kind }

    var isRunning: Bool { state == .running }

    func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        lines.append(trimmed)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
    }

    func finish(_ state: State) { self.state = state }
}

@MainActor
@Observable
final class AppStore {
    let monitor = SystemMonitor()

    // Stale times reflect how fast each thing really changes, and how much a scan costs.
    let clean = Query(key: "clean", staleAfter: 2 * 3_600) {
        try await SerialGate.heavy.run { try await Mole.cleanPreview() }
    }
    let purge = Query(key: "purge", staleAfter: 6 * 3_600) {
        try await SerialGate.heavy.run { try await Mole.purgePreview() }
    }
    let launchItems = Query(key: "launch-items", staleAfter: 24 * 3_600) {
        try await SerialGate.heavy.run { try await KnockKnock.scan() }
    }
    let lynis = Query(key: "lynis", staleAfter: 60, persists: false) { Lynis.load() }
    /// What agents leave running and what they've been given. Ports change by the
    /// minute; worktrees need a disk walk; extensions are a handful of config files.
    let servers = Query(key: "servers", staleAfter: 20, persists: false) { try await LocalServers.scan() }
    let worktrees = Query(key: "worktrees", staleAfter: 30 * 60) {
        try await SerialGate.heavy.run { try await Worktrees.scan() }
    }
    let extensions = Query(key: "extensions", staleAfter: 5 * 60, persists: false) { try await AgentExtensions.scan() }
    let history = Query(key: "history", staleAfter: 10 * 60) { try await Mole.history() }
    /// Installed agent harnesses, their accounts and sign-in state. Status checks are
    /// cheap, safe commands or file reads, never something that could start a login.
    let harnesses = Query<[HarnessInstallation]>(key: "harnesses", staleAfter: 10 * 60) {
        guard !DataDirectory.isSnapshot else { return [] }
        return await HarnessDetector.shared.detect(HarnessRegistry.load().descriptors)
    }
    /// Things that keep flaring up, from the local SQLite history. The database is the
    /// persistence here, so this query isn't cached to disk.
    let recurring = Query(key: "recurring", staleAfter: 5 * 60, persists: false) {
        await HistoryStore.shared.usage(since: Date().addingTimeInterval(-86_400))
            .filter { $0.spikes >= AttentionEngine.recurringSpikes }
    }

    let patterns = UsagePatterns()
    let connections = ConnectionsModel()
    @ObservationIgnored var mcpSocket: MCPSocketServer?
    @ObservationIgnored var mcpServer: MCPServer?
    @ObservationIgnored var showConnections: (() -> Void)?

    var job: Job?
    var dashboardSection: DashboardSection = .overview {
        didSet {
            if dashboardOpen && oldValue != dashboardSection { patterns.record(.sectionView, target: dashboardSection.rawValue) }
        }
    }
    /// Checked on launch and whenever you open the panel; granting it needs a relaunch.
    private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess
    /// The process group open in the Processes inspector, if any.
    var selectedProcessGroup: String? {
        didSet { if oldValue != selectedProcessGroup { agent?.close(); agent = nil } }
    }
    let usage = UsageModel()
    let inspector = InspectorModel()

    @ObservationIgnored private var popoverOpen = false
    @ObservationIgnored private var dashboardOpen = false
    @ObservationIgnored private var watchers: [DirectoryWatcher] = []
    @ObservationIgnored private var launchRescan: DispatchWorkItem?
    var isAuditing = false
    var auditError: String?
    var signInProgress: [String: SignInProgress] = [:]
    var agent: AgentConversation?

    /// Ends the open conversation (stopping the agent if it's still running) and returns
    /// the main area to the page underneath.
    func closeAgent() {
        agent?.close()
        agent = nil
    }

    /// Opens a saved conversation read-only in the main area, with its process in the
    /// inspector. A conversation that's still running is never stopped silently.
    func openConversation(id: String) {
        if let live = agent, !live.closed, live.record.id != id {
            let alert = NSAlert()
            alert.messageText = "Stop the conversation that's running?"
            alert.informativeText = "\(live.record.harness) is still working on \(live.record.displaySubject). Opening another conversation stops it."
            alert.addButton(withTitle: "Stop and Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if agent?.record.id == id { return }
        Task {
            guard let record = await HistoryStore.shared.agentSession(id: id) else { return }
            closeAgent()
            selectedProcessGroup = record.groupKey
            agent = AgentConversation(record: record)
        }
    }
    @ObservationIgnored private var signInPoll: Timer?

    /// "<harness id>|<account id>", remembered across launches.
    var preferredHarness: String = DataDirectory.preferences.string(forKey: "preferredHarness") ?? "" {
        didSet { DataDirectory.preferences.set(preferredHarness, forKey: "preferredHarness") }
    }

    /// The harness and account "Ask" uses: your pick if it's still installed, otherwise
    /// the first signed-in account, preferring the order harnesses are listed in.
    var assistant: (harness: HarnessInstallation, account: HarnessAccount?)? {
        let installed = (harnesses.value ?? []).filter(\.isInstalled)
        for harness in installed {
            for account in harness.accounts where "\(harness.id)|\(account.id)" == preferredHarness {
                return (harness, account)
            }
        }
        for harness in installed {
            if let account = harness.accounts.first(where: { $0.status == .signedIn }) { return (harness, account) }
        }
        return installed.first.map { ($0, $0.accounts.first) }
    }

    /// Plan usage per "<harness>|<account>", read on demand and kept five minutes.
    /// Anthropic rate-limits this endpoint, so it's never polled.
    private(set) var planUsage: [String: AccountUsage] = [:]
    private(set) var isLoadingUsage = false
    @ObservationIgnored private var usageLoadedAt: Date?

    func loadUsage(force: Bool, only harnessIDs: Set<String>? = nil) async {
        await loadUsageNow(force: force, only: harnessIDs)
    }

    func loadUsage(force: Bool) {
        Task { await loadUsageNow(force: force, only: nil) }
    }

    private func loadUsageNow(force: Bool, only harnessIDs: Set<String>?) async {
        guard !DataDirectory.isSnapshot else { return }
        guard !isLoadingUsage else { return }
        if !force, let usageLoadedAt, Date().timeIntervalSince(usageLoadedAt) < 300 { return }
        isLoadingUsage = true
        do {
            if harnesses.value == nil { await harnesses.refresh().value }
            let targets = (harnesses.value ?? []).filter { $0.isInstalled && (harnessIDs?.contains($0.id) ?? true) }.flatMap { harness in
                harness.accounts.filter { $0.status == .signedIn }.map { (harness, $0) }
            }
            // One account at a time: gentle on the vendors, and keychain prompts
            // (first run only) arrive one by one instead of stacking up.
            for (harness, account) in targets {
                if let result = await HarnessDetector.shared.usage(harness, account) {
                    planUsage["\(harness.id)|\(account.id)"] = result
                }
            }
            usageLoadedAt = .now
            isLoadingUsage = false
        }
    }

    func signIn(_ harness: HarnessInstallation, _ account: HarnessAccount) {
        authenticate(harness, account, signingIn: true)
    }

    func signOut(_ harness: HarnessInstallation, _ account: HarnessAccount) {
        authenticate(harness, account, signingIn: false)
    }

    private func authenticate(_ harness: HarnessInstallation, _ account: HarnessAccount, signingIn: Bool) {
        guard let argv = signingIn ? harness.descriptor.login : harness.descriptor.logout else { return }
        let key = "\(harness.id)|\(account.id)"
        guard signInProgress[key] == nil else { return }
        signInProgress[key] = SignInProgress(desired: signingIn ? .signedIn : .signedOut)
        Task {
            let path = await HarnessDetector.shared.shellPath()
            _ = await HarnessProcess.run(argv, environment: HarnessProcess.environment(harness.descriptor, account: account, path: path))
            await harnesses.refresh().value
            updateSignInProgress()
        }
        watchSignIn()
    }

    private func updateSignInProgress() {
        for (key, progress) in signInProgress {
            let account = (harnesses.value ?? []).flatMap { h in h.accounts.map { ("\(h.id)|\($0.id)", $0) } }
                .first { $0.0 == key }?.1
            if !progress.isWaiting(status: account?.status ?? .unknown) { signInProgress[key] = nil }
        }
        if signInProgress.isEmpty { signInPoll?.invalidate() }
    }

    private func watchSignIn() {
        signInPoll?.invalidate()
        signInPoll = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.harnesses.refresh().value
                self.updateSignInProgress()
            }
        }
    }

    var attention: [AttentionItem] {
        AttentionEngine.items(AttentionInputs(
            snapshot: monitor.snapshot,
            processes: monitor.processes,
            clean: clean.value,
            purge: purge.value,
            launchItems: launchItems.value,
            lynis: lynis.value,
            recurring: recurring.value ?? [],
            hasFullDiskAccess: hasFullDiskAccess
        ))
    }

    /// One line under the score: why it isn't 100, in plain words.
    var headline: String {
        guard let health = monitor.health else { return "Measuring…" }
        if health.issues.isEmpty { return "Everything looks healthy" }
        var text = health.issues.prefix(2).joined(separator: " · ")
        if health.issues.contains("High CPU"), let hog = monitor.processes.first, hog.cpu > 50 {
            text += " — \(hog.title)"
        }
        return text
    }

    var isScanning: Bool { clean.isFetching || purge.isFetching || launchItems.isFetching }

    /// What's scanning right now, in words, and where to see its results. Scans run one
    /// at a time, so the one that started earliest is the one actually working.
    var activeScan: (label: String, detail: String, section: DashboardSection, startedAt: Date)? {
        let scans: [(Date?, String, String, DashboardSection)] = [
            (clean.fetchStartedAt, "Measuring free-able space", "Working out how much space you can safely get back.", .cleanup),
            (purge.fetchStartedAt, "Checking old projects", "Looking for space held by old projects.", .projects),
            (launchItems.fetchStartedAt, "Checking startup items", "Checking everything that starts by itself.", .launchItems),
        ]
        return scans
            .compactMap { entry in entry.0.map { (label: entry.1, detail: entry.2, section: entry.3, startedAt: $0) } }
            .min { $0.startedAt < $1.startedAt }
    }

    // MARK: Lifecycle

    func start() {
        monitor.start()
        guard !DataDirectory.isSnapshot else { return }
        Task { await patterns.refresh() }
        startMCP()
        lynis.refresh()
        for folder in KnockKnock.watchedFolders {
            if let watcher = DirectoryWatcher(path: folder, onChange: { [weak self] in self?.launchFoldersChanged() }) {
                watchers.append(watcher)
            }
        }
        // On a first-ever launch there's nothing cached; warm up quietly after a minute.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.hasFullDiskAccess else { return }
            if self.clean.value == nil { self.clean.refresh() }
            if self.purge.value == nil { self.purge.refresh() }
            if self.launchItems.value == nil { self.launchItems.refresh() }
        }
    }

    func setPopover(open: Bool) {
        if open && !popoverOpen {
            patterns.record(.popoverOpen)
            Task { await patterns.refresh() }
        }
        popoverOpen = open
        activityChanged()
    }

    func setDashboard(open: Bool) {
        if open && !dashboardOpen {
            patterns.record(.sectionView, target: dashboardSection.rawValue)
            Task { await patterns.refresh() }
        }
        dashboardOpen = open
        if !open { closeAgent() }
        activityChanged()
    }

    private func activityChanged() {
        guard !DataDirectory.isSnapshot else { return }
        let active = popoverOpen || dashboardOpen
        monitor.setLive(active)
        guard active else { return }
        hasFullDiskAccess = Permissions.hasFullDiskAccess
        loginItem.refresh()
        recurring.refreshIfStale()
        if dashboardOpen { harnesses.refreshIfStale() }
        lynis.refreshIfStale()
        // Automatic scans only with Full Disk Access; otherwise each one sets off a
        // round of per-folder prompts. The refresh buttons still work if you insist.
        if hasFullDiskAccess {
            clean.refreshIfStale()
            purge.refreshIfStale()
            launchItems.refreshIfStale()
        }
        if dashboardOpen { history.refreshIfStale() }
    }

    func refreshAll() {
        monitor.sampleNow()
        lynis.refresh()
        clean.refresh()
        purge.refresh()
        launchItems.refresh()
        history.refresh()
        recurring.refresh()
        harnesses.refresh()
    }

    func inspect(_ row: ProcessRow, openDashboard: (DashboardSection) -> Void) {
        inspectGroup(row.identity?.groupKey, context: row.identity?.cwd)
        openDashboard(.processes)
    }

    func inspectGroup(_ key: String?, context: String? = nil) {
        selectedProcessGroup = key
        guard let key else { return }
        let folder = context ?? monitor.processes.first { $0.identity?.groupKey == key }?.identity?.cwd
            ?? (inspector.groupKey == key ? inspector.instances.first?.cwd : nil)
        if let folder { patterns.record(.processInspect, target: key, context: folder) }
        else {
            Task {
                let runs = await HistoryStore.shared.instances(of: key, since: Date().addingTimeInterval(-14 * 86_400))
                patterns.record(.processInspect, target: key, context: runs.first?.cwd)
            }
        }
    }

    /// Something registered or removed a launch agent. Rescan once things settle.
    private func launchFoldersChanged() {
        launchRescan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hasFullDiskAccess else { return }
            self.launchItems.refresh()
        }
        launchRescan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    // MARK: Actions

    func perform(_ action: AttentionAction, openDashboard: (DashboardSection) -> Void) {
        switch action {
        case .dashboard(let section): openDashboard(section)
        case .process(let groupKey):
            inspectGroup(groupKey)
            openDashboard(.processes)
        case .tool(let tool): open(tool)
        case .quit(let row): confirmQuit(row)
        case .fullDiskAccess: Permissions.openFullDiskAccessSettings()
        }
    }

    func open(_ tool: Tool) {
        patterns.record(.toolOpen, target: tool.rawValue)
        switch tool {
        case .launchItems:
            NSWorkspace.shared.open(URL(fileURLWithPath: KnockKnock.app))
        case .audit:
            runAudit()
        default:
            if let command = tool.command { Terminal.run(command) }
        }
    }

    func runAudit() {
        guard !isAuditing else { return }
        isAuditing = true
        auditError = nil
        Task {
            guard let executable = Shell.which("lynis") else {
                auditError = "Lynis isn't installed"; isAuditing = false; return
            }
            let result = try? await Shell.run("/usr/bin/osascript", ["-e", Lynis.adminScript(executable: executable)], timeout: 1_200)
            if result?.status != 0 || !Lynis.saveReport(result?.stdout ?? "") {
                auditError = "The audit was cancelled or could not finish."
            }
            await lynis.refresh().value
            isAuditing = false
        }
    }

    func confirmQuit(_ row: ProcessRow) {
        let alert = NSAlert()
        alert.messageText = "Quit \(row.name)?"
        alert.informativeText = "It's using \(Int(row.cpu))% CPU and \(Bytes.format(row.memoryBytes)) of memory. Unsaved work in it may be lost."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            patterns.record(.processQuit, target: row.identity?.groupKey, context: row.identity?.cwd)
            ProcessList.quit(row)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.monitor.sampleNow() }
        }
    }

    func protect(_ path: String) {
        try? Mole.protect(path)
        clean.refresh()
    }

    func runClean() { runJob(.clean, arguments: ["clean"]) { $0.clean.refresh() } }
    func runPurge() { runJob(.purge, arguments: ["purge", "--yes"]) { $0.purge.refresh() } }

    private func runJob(_ kind: Job.Kind, arguments: [String], then invalidate: @escaping (AppStore) -> Void) {
        guard job?.isRunning != true else { return }
        patterns.record(kind == .clean ? .clean : .purge)
        let job = Job(kind: kind)
        self.job = job
        monitor.sampleNow()
        let freeBefore = monitor.snapshot?.diskFreeBytes ?? 0

        Task {
            do {
                let result = try await Shell.run("mo", arguments, timeout: 1_800) { line in
                    Task { @MainActor in job.append(line) }
                }
                // Measure what was actually freed rather than trusting the estimate.
                monitor.sampleNow()
                let freed = max(0, (monitor.snapshot?.diskFreeBytes ?? 0) - freeBefore)
                job.finish(result.status == 0 ? .finished(freed: freed) : .failed("mo exited with code \(result.status)"))
            } catch {
                job.finish(.failed(error.localizedDescription))
            }
            invalidate(self)
            history.refresh()
        }
    }

    // MARK: Launch at login

    let loginItem = LoginItem()
    /// Reopens the setup window (set by the app delegate).
    @ObservationIgnored var showSetup: (() -> Void)?

    /// Rechecks Full Disk Access (the setup window polls this while it's open).
    func recheckFullDiskAccess() {
        let granted = Permissions.hasFullDiskAccess
        if granted != hasFullDiskAccess { hasFullDiskAccess = granted }
    }

    // MARK: Uninstall

    /// Removes the login item and, if asked, everything Pollymetric stored, then moves
    /// the app to the Trash and quits.
    func uninstall(deletingData: Bool) {
        loginItem.set(false)
        if deletingData {
            let fm = FileManager.default
            // A folder set with POLLYMETRIC_DATA_DIR may hold other things: only remove ours.
            if DataDirectory.override() == nil {
                try? fm.removeItem(at: Lynis.dataDirectory)
            } else {
                for name in Lynis.ownFiles { try? fm.removeItem(at: Lynis.dataDirectory.appendingPathComponent(name)) }
            }
            try? fm.removeItem(at: QueryDiskCache.directory)
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        }
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([app]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
