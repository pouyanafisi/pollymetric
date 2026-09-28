import AppKit
import ServiceManagement
import HarnessKit
import SwiftUI

@main
enum PollymetricMain {
    static func main() {
        // `Pollymetric --make-iconset <dir>`: the build uses this to make AppIcon.icns from
        // the same drawing code as the menu bar mark, so there's one source of geometry.
        let args = CommandLine.arguments
        // `Pollymetric --login-item status|on|off`: checks or sets start-at-login from the
        // installed bundle (SMAppService identifies the item by the running app's bundle).
        if let i = args.firstIndex(of: "--login-item") {
            let service = SMAppService.mainApp
            let action = args.indices.contains(i + 1) ? args[i + 1] : "status"
            do {
                if action == "on" { try service.register() }
                if action == "off" { try service.unregister() }
            } catch { print("error: \(error.localizedDescription)"); exit(1) }
            let names: [SMAppService.Status: String] = [.enabled: "enabled", .notRegistered: "notRegistered",
                                                        .requiresApproval: "requiresApproval", .notFound: "notFound"]
            print(names[service.status] ?? "unknown")
            exit(0)
        }
        // `Pollymetric --make-social-preview <panel.png> <out.png>`: the repo's link preview.
        if let i = args.firstIndex(of: "--make-social-preview"), args.indices.contains(i + 2),
           let panel = NSImage(contentsOfFile: args[i + 1]) {
            let rep = InstallerArt.socialPreview(panel: panel, scale: 1)
            do { try rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 2])); exit(0) }
            catch { print(error); exit(1) }
        }
        // `Pollymetric --make-dmg-background <dir>`: the release script's DMG artwork.
        if let i = args.firstIndex(of: "--make-dmg-background"), args.indices.contains(i + 1) {
            do { try InstallerArt.writeDMGBackground(to: URL(fileURLWithPath: args[i + 1])); exit(0) } catch { print(error); exit(1) }
        }
        if let i = args.firstIndex(of: "--make-iconset"), args.indices.contains(i + 1) {
            do { try LogoMark.writeIconset(to: URL(fileURLWithPath: args[i + 1])); exit(0) } catch { print(error); exit(1) }
        }
        if args.contains("--mcp") { exit(MCPShim.run()) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only: no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AppStore()
    private var statusItem: StatusItemController?
    private var dashboard: DashboardController?

    static let onboardingKey = "onboardingCompleted"
    private var onboarding: NSWindow?

    /// The setup window. While it's open Pollymetric shows in the Dock and ⌘-Tab.
    func showOnboarding() {
        if let onboarding { onboarding.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 660),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: OnboardingView(store: store) { [weak self] in self?.finishOnboarding() })
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 580, height: 660))
        window.center()
        onboarding = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onboardingClosed() }
        }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finishOnboarding() {
        onboarding?.close()
        // Show where Pollymetric lives from now on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.statusItem?.showPopover() }
    }

    private func onboardingClosed() {
        UserDefaults.standard.set(true, forKey: Self.onboardingKey)
        onboarding = nil
        if !NSApp.windows.contains(where: { $0.isVisible && $0.title == "Pollymetric" }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.connections.close()
        store.mcpSocket?.stop()
        store.agent?.close()
        RunningProcesses.shared.terminateAll()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `Pollymetric --harnesses` prints what HarnessKit detects, then quits.
        // `Pollymetric --usage <harness-id>` prints plan usage for that harness's accounts.
        if let i = CommandLine.arguments.firstIndex(of: "--usage"), CommandLine.arguments.indices.contains(i + 1) {
            let id = CommandLine.arguments[i + 1]
            Task {
                let found = await HarnessDetector.shared.detect(HarnessRegistry.load().descriptors.filter { $0.id == id })
                for h in found { for a in h.accounts where a.status == .signedIn {
                    guard let u = await HarnessDetector.shared.usage(h, a) else { continue }
                    print("\(a.label): \(u.status.rawValue) \(u.plan ?? "") \(u.identity ?? "") \(u.message ?? "")")
                    for w in u.windows { print("   \(w.label): \(w.usedPercent)% resets \(w.resetsAt.map { "\($0)" } ?? "?")") }
                } }
                exit(0)
            }
            return
        }
        // `Pollymetric --acp-smoke <harness-id>`: a real ACP session through the same
        // adapter, environment and client the agent pane uses. One tiny prompt, no tools,
        // any permission request is cancelled. For the lead's live check.
        if let i = CommandLine.arguments.firstIndex(of: "--acp-smoke"), CommandLine.arguments.indices.contains(i + 1) {
            let id = CommandLine.arguments[i + 1]
            Task { @MainActor in
                let found = await HarnessDetector.shared.detect(HarnessRegistry.load().descriptors.filter { $0.id == id })
                guard let harness = found.first, let acp = harness.descriptor.acp,
                      let account = harness.accounts.first(where: { $0.status == .signedIn }) else {
                    print("no signed-in account with an ACP adapter for \(id)"); exit(1)
                }
                let path = await HarnessDetector.shared.shellPath()
                let client = ACPClient()
                var text = "", kinds: [String: Int] = [:]
                client.onUpdate = { update in
                    let kind = update["sessionUpdate"] as? String ?? "?"
                    kinds[kind, default: 0] += 1
                    if kind == "agent_message_chunk", let content = update["content"] as? [String: Any], let t = content["text"] as? String { text += t }
                }
                client.onPermission = { key, request in
                    print("permission requested: \((request["toolCall"] as? [String: Any])?["title"] ?? "?"), cancelling")
                    client.answer(key, option: nil)
                }
                do {
                    try await client.start(argv: acp, environment: HarnessProcess.environment(harness.descriptor, account: account, path: path),
                                           cwd: NSTemporaryDirectory(), claude: id == "claude-code", explain: true)
                    print("account: \(account.identity ?? account.label)  mode: \(client.mode)")
                    try await client.prompt("Reply with exactly the single word READY. Do not use any tools.")
                    print("updates: \(kinds)")
                    print("answer: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
                } catch { print("error: \(error.localizedDescription)") }
                client.close()
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--harnesses") {
            Task {
                let found = await HarnessDetector.shared.detect(HarnessRegistry.load().descriptors)
                for h in found {
                    print("\(h.descriptor.name): \(h.executable ?? "not installed")")
                    for a in h.accounts { print("   \(a.label) [\(a.status.rawValue)] \(a.identity ?? "") \(a.home ?? "")") }
                }
                exit(0)
            }
            return
        }
        // Launched from the DMG or Downloads: offer to move into Applications first.
        if !DataDirectory.isSnapshot, AppMover.offerMoveIfNeeded() { return }

        let dashboard = DashboardController(store: store)
        self.dashboard = dashboard
        store.showConnections = { [weak dashboard] in dashboard?.show(.connections) }
        statusItem = StatusItemController(store: store) { [weak dashboard] section in
            dashboard?.show(section)
        }
        store.start()
        store.showSetup = { [weak self] in self?.showOnboarding() }

        // First launch (or `--setup`): the setup window.
        if !DataDirectory.isSnapshot,
           !UserDefaults.standard.bool(forKey: Self.onboardingKey) || CommandLine.arguments.contains("--setup") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.showOnboarding() }
        }

        // `Pollymetric --snapshot <dir>` renders the panel and each dashboard page to PNGs and
        // quits. It's for checking the UI without Screen Recording permission.
        let args = CommandLine.arguments
        // `--open-dashboard`: opens the dashboard on launch, for measuring its CPU cost.
        if args.contains("--open-dashboard") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.dashboard?.show(.overview) }
        }
        if let flag = args.firstIndex(of: "--snapshot"), args.indices.contains(flag + 1) {
            let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
            // `--dark`: every window in dark appearance, for the dark set of screenshots.
            if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.snapshot(to: dir) }
        }
    }

    /// Renders with SwiftUI's ImageRenderer (not a window capture), so it needs no
    /// Screen Recording permission. It waits for any running scans so pages show real data.
    private func snapshot(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            store.setDashboard(open: true)
            let deadline = Date().addingTimeInterval(90)
            while (store.isScanning || store.monitor.processes.isEmpty), Date() < deadline {
                try? await Task.sleep(for: .seconds(2))
            }
            let fixture = await snapshotFixtures()
            await store.usage.load()
            for dark in [false, true] {
                let suffix = dark ? "-dark" : ""
                render(PopoverView(store: store) { _ in }, width: 360, dark: dark,
                       to: dir.appendingPathComponent("popover\(suffix).png"))
                for section in DashboardSection.allCases {
                    store.dashboardSection = section
                    render(DashboardPage(store: store).padding(28), width: 836, dark: dark,
                           to: dir.appendingPathComponent("page-\(section.rawValue)\(suffix).png"))
                }
            }
            // Real windows too: the sidebar, inspector and scroll views that ImageRenderer can't draw.
            statusItem?.showPopover()
            try? await Task.sleep(for: .seconds(2))
            captureWindows(to: dir.appendingPathComponent("window-popover.png"))

            // The menu bar mark at 1x/2x and in its attention colors.
            for (name, color) in [("template", nil), ("fair", NSColor.systemOrange), ("poor", NSColor.systemRed)] as [(String, NSColor?)] {
                let image = LogoMark.image(size: 16, color: color)
                if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("mark-\(name).png"))
                }
                let big = LogoMark.image(size: 256, color: color ?? .black)
                if let tiff = big.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("mark-\(name)-256.png"))
                }
            }

            // A real brief from real history, to check what Claude would be handed.
            if let group = store.usage.groups.first(where: { $0.spikes > 0 }) ?? store.usage.groups.first {
                await store.inspector.load(group.groupKey)
                let brief = Assistant.markdown(.improve, context: .init(
                    title: group.label, subtitle: group.subtitle, explanation: nil, usage: store.inspector.usage,
                    runs: store.inspector.instances, focus: nil, live: [], timeline: store.inspector.timeline,
                    snapshot: store.monitor.snapshot, health: store.monitor.health
                ))
                try? brief.write(to: dir.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
            }

            // Exactly what clicking the top process row in the panel runs.
            if let row = store.monitor.processes.first, let statusItem {
                store.inspect(row, openDashboard: statusItem.openFromPopover)
                try? await Task.sleep(for: .seconds(2.5))
                captureWindows(to: dir.appendingPathComponent("window-row-click.png"))
                NSLog("VSNAP row click: %@ selected=%@ section=%@", row.title, store.selectedProcessGroup ?? "nil", store.dashboardSection.rawValue)
                dashboard?.close()
                try? await Task.sleep(for: .seconds(1))
            }
            let key = fixture?.groupKey ?? store.usage.groups.first?.groupKey ?? store.monitor.processes.first?.identity?.groupKey
            // Same order as a real click in the panel: select first, then open the window.
            if fixture == nil { store.harnesses.refresh() } // keep the demo account in screenshots
            try? await Task.sleep(for: .seconds(4))
            // Codex only here: Claude usage would raise keychain prompts mid-snapshot.
            await store.loadUsage(force: true, only: ["codex"])
            store.dashboardSection = .agents
            render(DashboardPage(store: store).padding(28), width: 836, dark: false, to: dir.appendingPathComponent("page-agents-usage.png"))
            for (section, select) in [(DashboardSection.processes, true), (.overview, true)] {
                store.selectedProcessGroup = select ? key : nil
                dashboard?.show(section)
                try? await Task.sleep(for: .seconds(2.5))
                captureWindows(to: dir.appendingPathComponent("window-\(section.rawValue)\(select ? "-inspector" : "").png"))
            }
            if let fixture {
                dashboard?.show(.processes)
                try? await Task.sleep(for: .seconds(1))
                store.selectedProcessGroup = fixture.groupKey
                store.agent = AgentConversation(record: fixture)
                try? await Task.sleep(for: .seconds(1))
                captureWindows(to: dir.appendingPathComponent("window-agent-fixture.png"))
                store.agent?.closed = false; store.agent?.mode = "Ask"
                store.agent?.permissions = [AgentPermission(id: "fixture", title: "Review proposed watcher change",
                    details: "{\"path\":\"tsup.config.ts\"}", options: [("allow", "Allow once"), ("reject", "Reject")])]
                try? await Task.sleep(for: .seconds(1))
                captureWindows(to: dir.appendingPathComponent("window-agent-approval-fixture.png"))
                dashboard?.show(.connections)
                try? await Task.sleep(for: .seconds(1))
                captureWindows(to: dir.appendingPathComponent("window-connections-fixture.png"))
                store.closeAgent()
                store.selectedProcessGroup = nil
                dashboard?.show(.conversations)
                try? await Task.sleep(for: .seconds(1.5))
                captureWindows(to: dir.appendingPathComponent("window-conversations-fixture.png"))
                dashboard?.close()
                showOnboarding()
                try? await Task.sleep(for: .seconds(2))
                captureWindows(to: dir.appendingPathComponent("window-onboarding.png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// Synthetic state is confined to an explicitly overridden snapshot data folder.
    private func snapshotFixtures() async -> AgentRecord? {
        guard DataDirectory.isSnapshot, let root = DataDirectory.override() else { return nil }
        let db = HistoryStore.shared
        let project = root.appendingPathComponent("storefront").path
        func identity(_ key: String, name: String, label: String, context: String? = nil, via: String? = nil,
                      app: String?, command: String, cwd: String? = nil, chain: [String]) -> ProcessIdentity {
            ProcessIdentity(key: key, pid: Int32(abs(key.hashValue) % 90_000 + 1_000), startedAt: Date().addingTimeInterval(-26 * 3600),
                            name: name, label: label, context: context, via: via, app: app, appPath: nil,
                            executable: nil, command: command, cwd: cwd, chain: chain)
        }
        let tsup = identity("demo-tsup", name: "node", label: "tsup", context: "storefront", via: "Claude Code", app: "iTerm2",
                            command: "node node_modules/.bin/tsup --watch", cwd: project, chain: ["Claude Code", "iTerm2"])
        let next = identity("demo-next", name: "node", label: "next dev", context: "storefront", app: "Visual Studio Code",
                            command: "node node_modules/.bin/next dev", cwd: project, chain: ["Code Helper", "Visual Studio Code"])
        let chrome = identity("demo-chrome", name: "Google Chrome Helper (Renderer)", label: "Google Chrome Helper (Renderer)",
                              app: "Google Chrome", command: "Google Chrome Helper (Renderer)", chain: ["Google Chrome"])
        let spotlight = identity("demo-mds", name: "mds_stores", label: "mds_stores", app: nil,
                                 command: "/System/Library/Frameworks/CoreServices.framework/mds_stores", chain: [])
        let windowServer = identity("demo-ws", name: "WindowServer", label: "WindowServer", app: nil,
                                    command: "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", chain: [])

        // A believable day, sampled every 5 minutes: a working-hours curve, a tsup watcher
        // that flares up in loops, Spotlight catching up overnight.
        let now = Date()
        for step in stride(from: 24 * 12, through: 0, by: -1) {
            let at = now.addingTimeInterval(Double(-step * 300))
            // The last 12 hours are the "working day", so the demo looks current.
            let working = step < 12 * 12
            let wave = sin(Double(step) / 7) * 6
            var records = [
                ProcessRecord(identity: windowServer, cpu: (working ? 38 : 14) + wave, memory: 210_000_000),
                ProcessRecord(identity: chrome, cpu: working ? 24 + wave : 4, memory: 1_300_000_000),
            ]
            if working, step % 18 < 4 { records.append(ProcessRecord(identity: tsup, cpu: 280 + wave * 3, memory: 420_000_000)) }
            if working { records.append(ProcessRecord(identity: next, cpu: 30 + wave, memory: 950_000_000)) }
            if !working, step % 9 < 3 { records.append(ProcessRecord(identity: spotlight, cpu: 90, memory: 160_000_000)) }
            db.record(records, duration: 300, at: at)
            let busy = records.reduce(0) { $0 + $1.cpu } / 10
            db.recordSystem(SystemSnapshot(date: at, cpuUsage: busy, cpuSustained: busy, memoryUsedPercent: 58,
                                           memoryUsedBytes: 0, memoryTotalBytes: 0, memoryPressure: .normal, diskUsedPercent: 41,
                                           diskFreeBytes: 0, diskTotalBytes: 0, diskIOMBps: 0, battery: nil, uptime: 0), score: 90)
        }
        for hour in 1...9 {
            db.recordInteraction(.processInspect, target: tsup.groupKey, context: project, at: now.addingTimeInterval(Double(-hour * 3600)))
        }
        for hour in 1...3 {
            db.recordInteraction(.processInspect, target: next.groupKey, context: project, at: now.addingTimeInterval(Double(-hour * 5000)))
        }
        await store.patterns.refresh()
        // An agent account so the inspector shows Explain / Find a Fix.
        if let claude = HarnessDescriptor.builtIns.first(where: { $0.id == "claude-code" }) {
            store.harnesses.seed([HarnessInstallation(descriptor: claude, executable: "/usr/local/bin/claude", accounts: [
                HarnessAccount(home: nil, label: "default", isDefault: true, status: .signedIn, identity: "you@example.com", plan: "Max")])])
        }
        let identity = tsup
        var record = AgentRecord(groupKey: identity.groupKey, harness: "Claude Code", account: "you@example.com", ask: "Explain")
        record.status = "answered"; record.ended = .now
        record.answer = "**tsup is rebuilding your project.** Its watcher is active in sample-project. The recorded bursts are brief; check whether generated files are triggering another build."
        record.subject = "tsup"
        record.answer = """
        ## What's happening

        `tsup --watch` in **storefront** rebuilds on every file change, and the build output lands inside a watched folder, so each rebuild triggers the next one.

        - 7 flare-ups in 24 hours, each 2–4 minutes at ~300% CPU
        - Every burst lines up with a write to `dist/`

        | Trigger | Rebuilds | CPU |
        |---|---|---|
        | Save in `src/` | 1 | ~40% |
        | Write to `dist/` | loops | ~300% |

        ★ Insight ─────────────────────
        A watcher that can see its own output is the most common cause of runaway dev-server CPU.
        ─────────────────────

        ### Fix

        1. Add `dist/**` to the watcher's ignore list in `tsup.config.ts`.
        2. Restart the watch process.
        """
        record.transcript = [
            AgentEntry(kind: "user", text: "# tsup\n\nBrief written by Pollymetric…"),
            AgentEntry(kind: "agent_thought_chunk", text: "Comparing the recorded bursts with the watcher configuration."),
            AgentEntry(kind: "tool", text: "Read tsup.config.ts", status: "completed", toolKind: "read",
                       input: "~/Sites/storefront/tsup.config.ts", output: "export default defineConfig({ entry: ['src/index.ts'], watch: true })"),
            AgentEntry(kind: "tool", text: "Search for watch configuration", status: "completed", toolKind: "search", input: "watch", output: "tsup.config.ts:1\npackage.json:12"),
            AgentEntry(kind: "tool", text: "ls -la dist", status: "completed", toolKind: "execute", input: "ls -la dist", output: "index.js\nindex.js.map"),
            AgentEntry(kind: "tool", text: "Read package.json", status: "completed", toolKind: "read", input: "~/Sites/storefront/package.json"),
            AgentEntry(kind: "agent_message_chunk", text: record.answer),
            AgentEntry(kind: "plan", text: "Review the watcher’s ignored folders", status: "completed"),
            AgentEntry(kind: "plan", text: "Propose the ignore change", status: "in_progress")]
        db.saveAgent(record)
        if let client = await db.pairClient(name: "Claude Code on this Mac", scope: "read+act", token: MCPToken.generate()) {
            await db.recordMCPCall(clientID: client.id, tool: "health", allowed: true)
            await db.recordMCPCall(clientID: client.id, tool: "clean_caches", allowed: false)
            if let tool = MCPTool.all.first(where: { $0.name == "clean_caches" }) {
                store.connections.approvals = [MCPApproval(client: client, tool: tool, arguments: "{}",
                    effect: "Run Mole cache cleanup with its current rules and protected paths. Matching cache files will be removed.", expires: Date().addingTimeInterval(60))]
            }
        }
        await store.connections.refresh()
        return record
    }

    /// Captures this app's own frontmost window. Your own windows need no Screen
    /// Recording permission.
    private func captureWindows(to url: URL) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 200 }
        guard let window = windows.min(by: { $0.orderedIndex < $1.orderedIndex }) else { return }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution])
        else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool, to url: URL) {
        let content = view
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// The menu bar item: an ECG glyph and the health score. It's monochrome (a template
/// image, so it follows the menu bar's appearance) until the score drops into Fair or
/// worse. Only then does it take on color.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let store: AppStore
    private let openDashboard: (DashboardSection) -> Void
    private var rendered: Health?

    init(store: AppStore, openDashboard: @escaping (DashboardSection) -> Void) {
        self.store = store
        self.openDashboard = openDashboard
        super.init()
        popover.behavior = .transient
        popover.animates = true
        // A popover follows the menu bar's appearance; the dark snapshot set needs it to follow the app.
        if DataDirectory.isSnapshot, CommandLine.arguments.contains("--dark") { popover.appearance = NSAppearance(named: .darkAqua) }
        popover.delegate = self
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageLeading
        }
        render()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = store.monitor.menuBarHealth
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.render()
                self?.observe()
            }
        }
    }

    private func render() {
        guard let button = item.button else { return }
        let health = store.monitor.menuBarHealth
        // Redraw only when something visible changed.
        if let health, let rendered, health.score == rendered.score, health.band == rendered.band { return }
        rendered = health

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let text = health.map { " \($0.score)" } ?? ""

        // The Pollymetric mark: a template image (tinted by macOS to match the menu bar)
        // until the score needs attention, then drawn in amber or red.
        if let health, health.band.wantsAttention {
            let color: NSColor = health.band == .poor ? .systemRed : .systemOrange
            button.image = LogoMark.image(size: 16, color: color)
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        } else {
            button.image = LogoMark.image(size: 16)
            button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font])
        }
        button.toolTip = health.map { "Pollymetric: \($0.band.title) (\($0.score))" + ($0.issues.isEmpty ? "" : ", " + $0.issues.joined(separator: ", ")) }
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = item.button else { return }
        // Build the SwiftUI tree only while the panel is showing; it's released on close.
        let host = NSHostingController(rootView: PopoverView(store: store) { [weak self] section in
            self?.openFromPopover(section)
        })
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        store.setPopover(open: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// What every link in the panel does: close the panel, open the dashboard there.
    func openFromPopover(_ section: DashboardSection) {
        popover.performClose(nil)
        openDashboard(section)
    }

    func popoverDidClose(_ notification: Notification) {
        store.setPopover(open: false)
        popover.contentViewController = nil
    }
}

/// The detailed window. While it's open Pollymetric shows in the Dock and ⌘-Tab like a
/// normal app, and it goes back to menu-bar-only when you close it.
@MainActor
final class DashboardController: NSObject, NSWindowDelegate {
    private let store: AppStore
    private var window: NSWindow?

    init(store: AppStore) {
        self.store = store
    }

    func show(_ section: DashboardSection) {
        store.dashboardSection = section
        if window == nil {
            // Creating the split view with its inspector already open sends SwiftUI into an
            // update-constraints loop that AppKit aborts. Open the window first, then the
            // inspector on the next pass.
            if let pending = store.selectedProcessGroup {
                store.selectedProcessGroup = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.store.selectedProcessGroup = pending
                }
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "Pollymetric"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden // the sidebar already says where you are
            window.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: DashboardView(store: store))
            // Don't let SwiftUI drive the window's size constraints. With a split view and
            // an inspector that feedback loop can exceed AppKit's update-constraints limit
            // and crash. The window owns its minimum size instead.
            host.sizingOptions = []
            window.contentMinSize = NSSize(width: 960, height: 560)
            host.view.frame = NSRect(x: 0, y: 0, width: 1180, height: 740)
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1180, height: 740))
            if DataDirectory.override() == nil {
                window.setFrameAutosaveName("PollymetricDashboard.v2")
                if !window.setFrameUsingName("PollymetricDashboard.v2") { window.center() }
            } else { window.center() }
            window.delegate = self
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        store.setDashboard(open: true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        store.connections.close()
        store.setDashboard(open: false)
        window?.contentViewController = nil
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
