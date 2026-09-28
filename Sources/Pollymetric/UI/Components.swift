import SwiftUI

// Metrics update every 2 seconds without animation, on purpose. Animating them meant
// every tick spent ~half a second re-laying out the whole window at display refresh
// rate: 24% CPU with the dashboard open, versus 2.5% without.

// MARK: Palette

extension Color {
    /// Solid label color. Inside the popover's vibrant material SwiftUI's `.primary`
    /// blends with the backdrop and ended up paler than `.secondary`, inverting the
    /// hierarchy. AppKit's labelColor stays solid.
    static let label = Color(nsColor: .labelColor)
}

/// Color is reserved for signal. Healthy things are drawn in neutral tones, so the
/// moment something turns amber or red, it's the only color on screen.
enum Level {
    case normal, elevated, critical

    var tint: Color {
        switch self {
        case .normal: Color.primary.opacity(0.55)
        case .elevated: .orange
        case .critical: .red
        }
    }
}

extension HealthBand {
    var color: Color {
        switch self {
        case .excellent: Color(red: 0.20, green: 0.78, blue: 0.47)
        case .good: Color(red: 0.36, green: 0.74, blue: 0.53)
        case .fair: .orange
        case .poor: .red
        }
    }
}

extension AttentionItem.Severity {
    var color: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .suggestion: .blue
        }
    }
}

// MARK: Score ring

struct ScoreRing: View {
    var score: Int
    var band: HealthBand
    var size: CGFloat = 58
    var lineWidth: CGFloat = 6

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(score) / 100)
                .stroke(band.color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(score)")
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Health score \(score) of 100, \(band.title)")
    }
}

// MARK: Meter tile

struct MeterTile: View {
    var title: String
    var symbol: String
    var value: String
    var caption: String
    var fraction: Double?
    var level: Level = .normal
    var history: [Double]? = nil
    /// When set, the tile is a button: CPU and Memory open Processes, Disk opens Caches.
    var action: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                Text(title).font(.caption.weight(.medium))
                Spacer(minLength: 4)
                if let history, history.count > 2 {
                    Sparkline(values: history, color: level.tint)
                        .frame(width: 46, height: 14)
                }
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(hovering ? 1 : 0.5)
                }
            }
            .foregroundStyle(.secondary)

            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(level == .normal ? AnyShapeStyle(.primary) : AnyShapeStyle(level.tint))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let fraction { MeterBar(fraction: fraction, color: level.tint) }

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(hovering ? 0.9 : 0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct MeterBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(3, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var maxValue: Double = 100

    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let point = CGPoint(x: CGFloat(i) * step, y: size.height * (1 - CGFloat(min(v, maxValue) / maxValue)))
                i == 0 ? line.move(to: point) : line.addLine(to: point)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height))
            fill.addLine(to: CGPoint(x: 0, y: size.height))
            fill.closeSubpath()
            context.fill(fill, with: .color(color.opacity(0.15)))
            context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
        }
    }
}

// MARK: Attention row

struct AttentionRow: View {
    var item: AttentionItem
    var perform: (AttentionAction) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle().fill(item.severity.color.opacity(0.14))
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.severity.color)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.callout.weight(.medium)).foregroundStyle(Color.label).lineLimit(1)
                Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            if let action = item.action {
                Button(action.label) { perform(action) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: Small pieces

struct SectionLabel: View {
    var title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            if let trailing { Text(trailing).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}

struct AllClearRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 18))
                .foregroundStyle(HealthBand.excellent.color)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nothing needs you").font(.callout.weight(.medium))
                Text("Pollymetric will flag anything worth a look.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A process as a person would name it: "next dev" with "storefront · claude › iTerm2"
/// under it, not "node". Clicking opens the full story in the dashboard.
struct ProcessLine: View {
    var row: ProcessRow
    var onSelect: (() -> Void)?
    var onQuit: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        Button { onSelect?() } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title).font(.callout).foregroundStyle(Color.label).lineLimit(1).truncationMode(.middle)
                    if let subtitle = row.subtitle {
                        Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                Text(Bytes.format(row.memoryBytes))
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
                Text("\(Int(row.cpu.rounded()))%")
                    .foregroundStyle(row.cpu > 80 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    .frame(width: 44, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(onSelect == nil ? 0 : (hovering ? 1 : 0.5))
            }
            .font(.caption.monospacedDigit())
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering && onSelect != nil ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(row.identity?.command ?? row.name)
        .contextMenu {
            if let onQuit { Button("Quit \(row.title)…", action: onQuit) }
            if let command = row.identity?.command { Button("Copy Command") { Paths.copy(command) } }
            if let cwd = row.identity?.cwd, cwd != "/" { Button("Open Folder") { Paths.reveal(cwd) } }
            Button("Copy PID") { Paths.copy("\(row.pid)") }
        }
    }
}

struct ToolButton: View {
    var tool: Tool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tool.symbol).font(.system(size: 14, weight: .regular)).frame(height: 16)
                Text(tool.title).font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? .primary : .secondary)
        .onHover { hovering = $0 }
        .help(tool.help)
    }
}

// MARK: Tile builders shared by the panel and the dashboard

extension SystemSnapshot {
    var cpuLevel: Level { cpuSustained > 85 ? .elevated : .normal }

    var memoryLevel: Level {
        switch memoryPressure {
        case .critical: .critical
        case .warn: .elevated
        case .normal: memoryUsedPercent > 88 ? .elevated : .normal
        }
    }

    var diskLevel: Level { diskUsedPercent > 93 ? .critical : (diskUsedPercent > 80 ? .elevated : .normal) }

    var batteryLevel: Level {
        guard let b = battery, !b.onAC else { return .normal }
        return b.percent < 10 ? .critical : (b.percent < 20 ? .elevated : .normal)
    }
}

struct MetricsGrid: View {
    var snapshot: SystemSnapshot
    var cpuHistory: [Double]
    var columns: Int = 2
    var open: ((DashboardSection) -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            MeterTile(
                title: "CPU", symbol: "cpu",
                value: "\(Int(snapshot.cpuUsage.rounded()))%",
                caption: "30s average \(Int(snapshot.cpuSustained.rounded()))%",
                fraction: snapshot.cpuUsage / 100, level: snapshot.cpuLevel, history: cpuHistory,
                action: open.map { open in { open(.processes) } }
            )
            MeterTile(
                title: "Memory", symbol: "memorychip",
                value: "\(Int(snapshot.memoryUsedPercent.rounded()))%",
                caption: "\(Bytes.format(Int64(snapshot.memoryUsedBytes))) of \(Bytes.format(Int64(snapshot.memoryTotalBytes)))"
                    + (snapshot.memoryPressure == .normal ? "" : " · pressure"),
                fraction: snapshot.memoryUsedPercent / 100, level: snapshot.memoryLevel,
                action: open.map { open in { open(.processes) } }
            )
            MeterTile(
                title: "Disk", symbol: "internaldrive",
                value: Bytes.format(snapshot.diskFreeBytes) + " free",
                caption: "\(Int(snapshot.diskUsedPercent.rounded()))% of \(Bytes.format(snapshot.diskTotalBytes)) used",
                fraction: snapshot.diskUsedPercent / 100, level: snapshot.diskLevel,
                action: open.map { open in { open(.cleanup) } }
            )
            if let battery = snapshot.battery {
                MeterTile(
                    title: "Battery", symbol: battery.onAC ? "bolt.fill" : "battery.75percent",
                    value: "\(battery.percent)%",
                    caption: batteryCaption(battery),
                    fraction: Double(battery.percent) / 100, level: snapshot.batteryLevel
                )
            } else {
                MeterTile(
                    title: "Uptime", symbol: "clock",
                    value: Relative.uptime(snapshot.uptime),
                    caption: "since last restart", fraction: nil
                )
            }
        }
    }

    private func batteryCaption(_ b: BatteryInfo) -> String {
        let power = b.isCharging ? "Charging" : (b.onAC ? "On power" : "On battery")
        return b.healthPercent > 0 ? "\(power) · \(b.healthPercent)% health" : power
    }
}
