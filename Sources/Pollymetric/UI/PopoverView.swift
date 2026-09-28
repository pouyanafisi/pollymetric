import SwiftUI

/// The menu bar panel, built to be read in about two seconds, top to bottom:
/// how's my Mac → what should I do → the numbers → the tools.
struct PopoverView: View {
    @Bindable var store: AppStore
    var openDashboard: (DashboardSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                attention
                if let snapshot = store.monitor.snapshot {
                    MetricsGrid(snapshot: snapshot, cpuHistory: store.monitor.cpuHistory) { section in
                        openDashboard(section)
                    }
                }
                processes
            }
            .padding(16)

            Divider()
            tools.padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 360)
        // See Color.label: .primary renders paler than .secondary in the vibrant popover.
        .foregroundStyle(Color.label)
        // Captures have nothing behind the translucent material; use the solid window color.
        .background(DataDirectory.isSnapshot ? Color(nsColor: .windowBackgroundColor) : .clear)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            if let health = store.monitor.health {
                ScoreRing(score: health.score, band: health.band)
                VStack(alignment: .leading, spacing: 2) {
                    Text(health.band.title)
                        .font(.title3.weight(.semibold))
                    Text(store.headline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let s = store.monitor.snapshot {
                        Text("Up \(Relative.uptime(s.uptime))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
                Text("Measuring…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Needs attention

    private var attention: some View {
        let items = store.attention
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Needs attention", trailing: items.isEmpty ? nil : "\(items.count)")
            if items.isEmpty {
                AllClearRow()
            } else {
                ForEach(items.prefix(4)) { item in
                    AttentionRow(item: item) { store.perform($0, openDashboard: openDashboard) }
                }
                if items.count > 4 {
                    Button("\(items.count - 4) more in the dashboard") { openDashboard(.overview) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    // MARK: Processes

    @ViewBuilder
    private var processes: some View {
        let rows = store.patterns.ranked(store.monitor.processes).prefix(3)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(title: "Top processes", trailing: "memory · CPU")
                VStack(spacing: 2) {
                    ForEach(Array(rows)) { row in
                        ProcessLine(row: row, onSelect: { store.inspect(row, openDashboard: openDashboard) }) {
                            store.confirmQuit(row)
                        }
                    }
                }
                .padding(.horizontal, -4)
            }
        }
    }

    // MARK: Tools & footer

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases) { tool in
                ToolButton(tool: tool) { store.open(tool) }
            }
        }
    }

    private func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                openDashboard(store.dashboardSection)
            } label: {
                Label {
                    Text("Open Dashboard")
                } icon: {
                    Image(nsImage: LogoMark.image(size: 14)).renderingMode(.template)
                }
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("d")

            Spacer()

            if let scan = store.activeScan {
                Button {
                    openDashboard(scan.section)
                } label: {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("\(scan.label) · \(elapsed(since: scan.startedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help(scan.detail + " It runs at low priority; results appear when it finishes.")
            }

            Menu {
                Button("Refresh Everything") { store.refreshAll() }
                Toggle("Start at Login", isOn: Binding(get: { store.loginItem.isOn }, set: { store.loginItem.set($0) }))
                Toggle("Learn from how I use Pollymetric", isOn: Bindable(store.patterns).enabled)
                Button("Clear usage patterns") { Task { await store.patterns.clear() } }
                Divider()
                Button("Settings…") { openDashboard(.general) }
                Button("Connections…") { openDashboard(.connections) }
                Divider()
                Button("Quit Pollymetric") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.callout)
    }
}
