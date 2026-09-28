import Charts
import SwiftUI

enum HistoryRange: String, CaseIterable, Identifiable {
    case now, hour, day, week
    var id: String { rawValue }

    var title: String {
        switch self {
        case .now: "Now"
        case .hour: "1 Hour"
        case .day: "24 Hours"
        case .week: "7 Days"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .now, .hour: 3_600
        case .day: 86_400
        case .week: 7 * 86_400
        }
    }

    /// Chart bucket size: roughly 60–90 bars whatever the window.
    var bucket: TimeInterval {
        switch self {
        case .now, .hour: 60
        case .day: 15 * 60
        case .week: 2 * 3_600
        }
    }

    var since: Date { Date().addingTimeInterval(-seconds) }
}

/// Loaded history for the Processes page. It lives on the store so it survives page
/// switches, and so snapshot mode can await it.
@MainActor
@Observable
final class UsageModel {
    var window: HistoryRange = .day
    private(set) var groups: [UsageGroup] = []
    private(set) var system: [TimePoint] = []

    func load() async {
        let window = window
        async let usage = HistoryStore.shared.usage(since: window.since)
        async let timeline = HistoryStore.shared.systemTimeline(since: window.since, bucket: window.bucket)
        (groups, system) = await (usage, timeline)
    }
}

@MainActor
@Observable
final class InspectorModel {
    private(set) var groupKey: String?
    private(set) var usage: UsageGroup?
    private(set) var instances: [UsageInstance] = []
    private(set) var timeline: [TimePoint] = []

    func load(_ key: String) async {
        if key != groupKey { usage = nil; instances = []; timeline = [] }
        groupKey = key
        let since = Date().addingTimeInterval(-86_400)
        async let groups = HistoryStore.shared.usage(since: since, limit: 500)
        async let runs = HistoryStore.shared.instances(of: key, since: since)
        async let points = HistoryStore.shared.timeline(of: key, since: since, bucket: 15 * 60)
        let (all, r, p) = await (groups, runs, points)
        guard key == groupKey else { return }
        usage = all.first { $0.groupKey == key }
        instances = r
        timeline = p
    }
}

/// Which group a process belongs under: its app, else the tool that launched it
/// (e.g. everything a `claude` session spawns), else background and system.
func owner(app: String?, via: String?) -> String {
    app ?? via ?? "Background & system"
}

enum Durations {
    static func cpu(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3_600 { return "\(s / 3_600)h \((s % 3_600) / 60)m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}

/// History of what's been using the Mac, grouped by the app that started it. Each app
/// starts collapsed except the heaviest two, so the page reads top-down in seconds.
/// Details live in the inspector, one click away.
struct ProcessesPage: View {
    @Bindable var store: AppStore
    /// nil until you expand or collapse something; until then the top two apps are open.
    @State private var expanded: Set<String>?

    private var model: UsageModel { store.usage }
    private var window: HistoryRange { model.window }
    private var groups: [UsageGroup] { model.groups }
    private var system: [TimePoint] { model.system }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Processes").font(.largeTitle.weight(.semibold))
                Text("What's been slowing your Mac down, and which app started it. The last 14 days, private to this Mac.")
                    .foregroundStyle(.secondary)
            }

            if store.patterns.enabled && !store.patterns.frequent.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "You check these most", trailing: "last 14 days")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(store.patterns.frequent.prefix(4)) { pattern in
                                Button { store.inspectGroup(pattern.target, context: pattern.context) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(pattern.title).font(.callout).lineLimit(1)
                                        Text("\(pattern.count) inspections · \(Relative.string(pattern.lastInspected))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            Picker("Window", selection: Bindable(model).window) {
                ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if window == .now {
                liveList
            } else {
                systemChart
                historyList
            }
        }
        .task(id: window) { await model.load() }
    }

    // MARK: Live

    private var liveGroups: [(app: String, rows: [ProcessRow], cpu: Double)] {
        Dictionary(grouping: store.monitor.processes) { $0.identity.map { owner(app: $0.app, via: $0.via) } ?? "Background & system" }
            .map { (app: $0.key, rows: $0.value, cpu: $0.value.reduce(0) { $0 + $1.cpu }) }
            .sorted { $0.cpu > $1.cpu }
    }

    private var liveList: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(liveGroups, id: \.app) { group in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: group.app, trailing: "\(Int(group.cpu))% CPU")
                    Card {
                        VStack(spacing: 2) {
                            ForEach(group.rows) { row in
                                liveRow(row)
                            }
                        }
                    }
                }
            }
        }
    }

    private func liveRow(_ row: ProcessRow) -> some View {
        ProcessLine(row: row, onSelect: { store.inspectGroup(row.identity?.groupKey, context: row.identity?.cwd) }) {
            store.confirmQuit(row)
        }
    }

    // MARK: History

    private var systemChart: some View {
        Card {
            HStack {
                Text("System CPU").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let peak = system.map(\.value).max() {
                    Text("peak \(Int(peak))%").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if system.count > 1 {
                Chart(system) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("CPU", point.value))
                        .foregroundStyle(.linearGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.03)],
                            startPoint: .top, endPoint: .bottom
                        ))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.date), y: .value("CPU", point.value))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 50, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                    }
                }
                .frame(height: 110)
            } else {
                Text("The chart fills in as Pollymetric records a sample each minute.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if groups.isEmpty {
            EmptyState(
                symbol: "cpu",
                title: "Nothing notable yet",
                message: "Pollymetric records any process above 20% CPU or 2 GB of memory. History builds up as you work."
            )
        } else {
            let apps = Dictionary(grouping: groups) { owner(app: $0.app, via: $0.via) }
                .map { (app: $0.key, groups: $0.value, cpu: $0.value.reduce(0) { $0 + $1.cpuSeconds }) }
                .sorted { $0.cpu > $1.cpu }
            let maxCPU = groups.map(\.cpuSeconds).max() ?? 1

            VStack(alignment: .leading, spacing: 12) {
                ForEach(apps, id: \.app) { entry in
                    Card {
                        DisclosureGroup(isExpanded: expansion(for: entry.app)) {
                            VStack(spacing: 0) {
                                ForEach(Array(entry.groups.enumerated()), id: \.element.id) { index, group in
                                    if index > 0 { Divider() }
                                    UsageRow(group: group, maxCPU: maxCPU, selected: store.selectedProcessGroup == group.groupKey) {
                                        store.inspectGroup(group.groupKey)
                                    }
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            AppHeader(app: entry.app, appPath: entry.groups.first?.appPath,
                                      cpuSeconds: entry.cpu, count: entry.groups.count)
                        }
                    }
                }
            }

        }
    }

    /// The two heaviest apps start open; everything else is one click away.
    private func expansion(for app: String) -> Binding<Bool> {
        Binding(
            get: { (expanded ?? topApps).contains(app) },
            set: { open in
                var next = expanded ?? topApps
                if open { next.insert(app) } else { next.remove(app) }
                expanded = next
            }
        )
    }

    private var topApps: Set<String> {
        let totals = Dictionary(grouping: groups) { owner(app: $0.app, via: $0.via) }
            .mapValues { $0.reduce(0) { $0 + $1.cpuSeconds } }
        return Set(totals.sorted { $0.value > $1.value }.prefix(2).map(\.key))
    }

}

private struct AppHeader: View {
    var app: String
    var appPath: String?
    var cpuSeconds: Double
    var count: Int

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: appPath).frame(width: 22, height: 22)
            Text(app).font(.headline)
            Spacer()
            Text("\(Durations.cpu(cpuSeconds)) CPU · \(count) \(count == 1 ? "thing" : "things")")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

struct AppIcon: View {
    var path: String?

    var body: some View {
        if let path {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
        } else {
            Image(systemName: "gearshape.2").font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
}

private struct UsageRow: View {
    var group: UsageGroup
    var maxCPU: Double
    var selected: Bool
    var select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.label).font(.callout.weight(.medium)).lineLimit(1)
                        if group.spikes >= AttentionEngine.recurringSpikes {
                            Text("\(group.spikes) flare-ups")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(Durations.cpu(group.cpuSeconds)).font(.callout).monospacedDigit()
                    MeterBar(fraction: group.cpuSeconds / max(maxCPU, 1), color: Level.normal.tint)
                        .frame(width: 70)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.05) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var secondary: String {
        var parts: [String] = []
        if let context = group.context { parts.append(context) }
        if let via = group.via { parts.append("via \(via)") }
        parts.append("peak \(Int(group.peakCPU))%")
        parts.append("last \(Relative.string(group.lastSeen))")
        return parts.joined(separator: " · ")
    }
}

// MARK: Inspector

/// Everything known about one thing: what it is, where it runs, who started it, and
/// its history. Reached by clicking a process anywhere in Pollymetric.
struct ProcessInspector: View {
    @Bindable var store: AppStore
    var groupKey: String
    @State private var answers: [AgentRecord] = []

    private var usage: UsageGroup? { store.inspector.groupKey == groupKey ? store.inspector.usage : nil }
    private var instances: [UsageInstance] { store.inspector.groupKey == groupKey ? store.inspector.instances : [] }
    private var timeline: [TimePoint] { store.inspector.groupKey == groupKey ? store.inspector.timeline : [] }

    private var liveRows: [ProcessRow] {
        store.monitor.processes.filter { $0.identity?.groupKey == groupKey }
    }

    private var identity: ProcessIdentity? { liveRows.first?.identity }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let explanation { Text(explanation).font(.callout).foregroundStyle(.secondary) }
                if let agent = store.agent, agent.record.groupKey == groupKey {
                    Label(agent.busy ? "\(agent.record.harness) is working on this" : "Conversation open",
                          systemImage: "text.bubble")
                        .font(.callout).foregroundStyle(.secondary)
                } else { askRow }
                if !liveRows.isEmpty { running }
                stats
                if timeline.count > 1 { chart }
                if !instances.isEmpty { history }
                if !answers.isEmpty {
                    SectionLabel(title: "Agent answers")
                    ForEach(answers) { answer in
                        Button {
                            store.agent?.close()
                            store.agent = AgentConversation(record: answer)
                        } label: {
                            Text("\(answer.ask == "Explain" ? "Explained" : "Investigated") \(Relative.string(answer.started)) · \(answer.harness) · \(answer.account)")
                                .font(.caption).multilineTextAlignment(.leading)
                        }.buttonStyle(.link)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: groupKey) {
            await store.inspector.load(groupKey)
            answers = await HistoryStore.shared.agentSessions(group: groupKey)
        }
        .onChange(of: store.agent == nil) {
            Task { answers = await HistoryStore.shared.agentSessions(group: groupKey) }
        }
    }

    private var title: String { usage?.label ?? identity?.label ?? "Process" }

    /// Hand this to an agent: it opens in iTerm2 in its read-only mode with a brief of
    /// everything above, investigates, and asks before changing anything.
    @ViewBuilder
    private var askRow: some View {
        if let choice = store.assistant {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ForEach([Assistant.Ask.explain, .improve], id: \.title) { ask in
                        Button { self.ask(ask) } label: {
                            Label(ask.title, systemImage: ask.symbol).frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                    }
                }
                HarnessPicker(store: store, current: choice)
            }
            .help("Opens a conversation with everything Pollymetric knows about this process. It investigates read-only and asks before changing anything.")
        } else {
            Button("Set up an agent to explain this…") { store.dashboardSection = .agents }
                .buttonStyle(.link)
        }
    }

    private func ask(_ ask: Assistant.Ask, focus: UsageInstance? = nil) {
        guard let choice = store.assistant else { store.dashboardSection = .agents; return }
        let context = Assistant.Context(
            title: title,
            subtitle: usage?.subtitle ?? identity?.subtitle ?? "",
            explanation: explanation,
            usage: usage,
            runs: instances,
            focus: focus,
            live: liveRows,
            timeline: timeline,
            snapshot: store.monitor.snapshot,
            health: store.monitor.health
        )
        store.patterns.record(.agentAsk, target: groupKey, context: (focus ?? instances.first)?.cwd)
        if choice.harness.descriptor.acp != nil {
            store.agent?.close()
            store.agent = AgentConversation(group: groupKey, ask: ask, harness: choice.harness, account: choice.account, context: context)
        } else { Assistant.open(ask, harness: choice.harness, account: choice.account, context: context) }
    }

    private var explanation: String? {
        ProcessDescriber.explain(label: title, name: identity?.name, app: usage?.app ?? identity?.app)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(path: usage?.appPath ?? identity?.appPath).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(usage?.subtitle ?? identity?.subtitle ?? "").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.selectedProcessGroup = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("Close")
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Running now", trailing: "\(liveRows.count)")
            ForEach(liveRows) { row in
                HStack {
                    Text("PID " + String(row.pid)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(row.cpu))% · \(Bytes.format(row.memoryBytes))").font(.caption).monospacedDigit()
                    Button("Quit") { store.confirmQuit(row) }.controlSize(.small)
                }
            }
        }
    }

    private var stats: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            if let usage {
                GridRow { stat("CPU time (24h)", Durations.cpu(usage.cpuSeconds)); stat("Peak CPU", "\(Int(usage.peakCPU))%") }
                GridRow { stat("Flare-ups", "\(usage.spikes)"); stat("Peak memory", Bytes.format(usage.peakMemory)) }
                GridRow { stat("Times started", "\(usage.instances)"); stat("Last seen", Relative.string(usage.lastSeen)) }
            } else {
                GridRow { stat("History", "none yet") }
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "CPU over 24 hours", trailing: "% of one core")
            Chart(timeline) { point in
                BarMark(x: .value("Time", point.date, unit: .minute), y: .value("CPU", point.value), width: .ratio(0.8))
                    .foregroundStyle(point.value >= 50 ? Color.orange : Level.normal.tint)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel(format: .dateTime.hour().minute()) }
            }
            .frame(height: 90)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Recent runs", trailing: "\(instances.count)")
            ForEach(instances) { instance in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Started \(Relative.string(instance.startedAt))").font(.caption.weight(.medium))
                        Spacer()
                        Text("\(Durations.cpu(instance.cpuSeconds)) · peak \(Int(instance.peakCPU))%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(instance.command)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(4)
                        .textSelection(.enabled)
                    if !instance.chain.isEmpty {
                        Text((instance.chain.reversed() + [title]).joined(separator: " › "))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    HStack(spacing: 12) {
                        Button("Explain") { ask(.explain, focus: instance) }
                            .help("Ask an agent what this run was doing and why it was heavy")
                        Button("Investigate") { ask(.improve, focus: instance) }
                            .help("Ask an agent to find the cause and propose fixes (it asks before editing)")
                        Spacer()
                        // Secondary actions live in a menu so the row never wraps.
                        Menu {
                            Button("Copy Command") { Paths.copy(instance.command) }
                            if let cwd = instance.cwd, cwd != "/" { Button("Open Folder") { Paths.reveal(cwd) } }
                            if let exe = instance.executable { Button("Reveal Binary") { Paths.reveal(exe) } }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}
