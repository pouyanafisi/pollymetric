import SwiftUI

struct DashboardView: View {
    @Bindable var store: AppStore

    var body: some View {
        NavigationSplitView {
            List(selection: selection) {
                Section {
                    row(.overview, badge: store.attention.isEmpty ? nil : "\(store.attention.count)")
                    row(.processes, badge: nil)
                }
                Section("Agent Activity") {
                    row(.servers, badge: store.servers.value.map { $0.servers.isEmpty ? nil : "\($0.servers.count)" } ?? nil)
                    row(.worktrees, badge: store.worktrees.value.flatMap { $0.totalBytes > 0 ? Bytes.format($0.totalBytes) : nil })
                    row(.extensions, badge: store.extensions.value.flatMap { $0.worthALookCount == 0 ? nil : "\($0.worthALookCount)" })
                }
                Section("Storage") {
                    row(.cleanup, badge: store.clean.value.map { Bytes.format($0.totalBytes) })
                    row(.projects, badge: store.purge.value.map { Bytes.format($0.totalBytes) })
                }
                Section("Security") {
                    row(.launchItems, badge: store.launchItems.value.flatMap { $0.flaggedPaths.isEmpty ? nil : "\($0.flaggedPaths.count)" })
                    row(.security, badge: store.lynis.value?.report?.hardeningIndex.map { "\($0)" })
                }
                Section("Activity") {
                    row(.history, badge: nil)
                    row(.conversations, badge: nil)
                }
                Section("Settings") {
                    row(.general, badge: store.hasFullDiskAccess ? nil : "!")
                    row(.agents, badge: nil)
                    row(.connections, badge: nil)
                }
            }
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Image(nsImage: LogoMark.image(size: 20)).renderingMode(.template)
                    Text("Pollymetric").font(.headline)
                    Spacer()
                }
                .foregroundStyle(Color.label)
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 4)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            Group {
                if let agent = store.agent {
                    // A conversation takes over the main area; the process stays in the inspector.
                    AgentWorkspace(conversation: agent) { store.closeAgent() }
                } else {
                    ScrollView {
                        DashboardPage(store: store)
                            .frame(maxWidth: 780, alignment: .leading)
                            .padding(28)
                            .frame(maxWidth: .infinity)
                    }
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .top) { TopFade() }
                }
            }
            .inspector(isPresented: inspectorShown) {
                Group {
                    if let key = store.selectedProcessGroup {
                        ProcessInspector(store: store, groupKey: key)
                    } else {
                        Color.clear
                    }
                }
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
            }
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { store.selectedProcessGroup != nil && [.processes, .overview, .conversations].contains(store.dashboardSection) },
            set: { if !$0 { store.selectedProcessGroup = nil } }
        )
    }

    private var selection: Binding<DashboardSection?> {
        Binding(get: { store.dashboardSection }, set: { if let s = $0 { store.dashboardSection = s } })
    }

    private func row(_ section: DashboardSection, badge: String?) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(badge.map { Text($0).monospacedDigit() })
            .tag(section)
    }
}

struct DashboardPage: View {
    @Bindable var store: AppStore

    var body: some View {
        switch store.dashboardSection {
        case .overview: OverviewPage(store: store)
        case .processes: ProcessesPage(store: store)
        case .servers: LocalServersPage(store: store)
        case .worktrees: WorktreesPage(store: store)
        case .extensions: AgentExtensionsPage(store: store)
        case .cleanup: CachesPage(store: store)
        case .projects: BuildFoldersPage(store: store)
        case .launchItems: LaunchItemsPage(store: store)
        case .security: SecurityPage(store: store)
        case .history: HistoryPage(store: store)
        case .conversations: ConversationsPage(store: store)
        case .general: GeneralPage(store: store)
        case .agents: AgentsPage(store: store)
        case .connections: ConnectionsPage(model: store.connections)
        }
    }
}

// MARK: Shared page chrome

struct PageHeader: View {
    var title: String
    var subtitle: String
    var updatedAt: Date?
    var isFetching: Bool
    var error: String?
    var refresh: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            if let refresh {
                HStack(spacing: 8) {
                    if isFetching {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Updated \(Relative.string(updatedAt))").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .disabled(isFetching)
                        .help("Rescan now")
                }
            }
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }
}

/// Content scrolling up under the transparent title bar fades out instead of colliding
/// with the window controls.
struct TopFade: View {
    var height: CGFloat = 56

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(nsColor: .windowBackgroundColor), location: 0),
                .init(color: Color(nsColor: .windowBackgroundColor), location: 0.45),
                .init(color: Color(nsColor: .windowBackgroundColor).opacity(0), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
        )
        .frame(height: height)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

/// The one number that matters on a page, with its main action beside it.
struct Hero<Actions: View>: View {
    var value: String
    var caption: String
    @ViewBuilder var actions: Actions

    var body: some View {
        Card {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(value)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(caption).foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }
        }
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

struct JobPanel: View {
    var job: Job
    var dismiss: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 10) {
                switch job.state {
                case .running:
                    ProgressView().controlSize(.small)
                    Text(job.kind == .clean ? "Cleaning caches…" : "Removing build folders…").font(.headline)
                case .finished(let freed):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(HealthBand.excellent.color)
                    Text(freed > 0 ? "Done. \(Bytes.format(freed)) freed." : "Done.").font(.headline)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.headline)
                }
                Spacer()
                if !job.isRunning { Button("Dismiss", action: dismiss).controlSize(.small) }
            }
            if !job.lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(job.lines.suffix(job.isRunning ? 6 : 12).enumerated()), id: \.offset) { _, line in
                        Text(line).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }
}

// MARK: Overview

struct OverviewPage: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let health = store.monitor.health, let s = store.monitor.snapshot {
                Card {
                    HStack(spacing: 20) {
                        ScoreRing(score: health.score, band: health.band, size: 92, lineWidth: 9)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(health.band.title).font(.title.weight(.semibold))
                            Text(store.headline).foregroundStyle(.secondary)
                            if let pattern = store.patterns.clearPattern {
                                Button("You’ve looked at \(pattern.title) \(pattern.count) times this week") {
                                    store.inspectGroup(pattern.target, context: pattern.context)
                                }.buttonStyle(.link).font(.caption)
                            }
                            Text("\(Host.current().localizedName ?? "This Mac") · up \(Relative.uptime(s.uptime))")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                }
                MetricsGrid(snapshot: s, cpuHistory: store.monitor.cpuHistory, columns: 4)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(title: "Needs attention")
                Card {
                    let items = store.attention
                    if items.isEmpty {
                        AllClearRow()
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            AttentionRow(item: item) { action in
                                store.perform(action) { store.dashboardSection = $0 }
                            }
                        }
                    }
                }
            }

            if !store.monitor.processes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "Top processes", trailing: "click for details")
                    Card {
                        VStack(spacing: 2) {
                            ForEach(store.monitor.processes) { row in
                                ProcessLine(row: row, onSelect: { store.inspectGroup(row.identity?.groupKey, context: row.identity?.cwd) }) {
                                    store.confirmQuit(row)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
