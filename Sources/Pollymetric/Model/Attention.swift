import Foundation

struct AttentionItem: Identifiable, Equatable {
    enum Severity: Int, Comparable {
        case suggestion, warning, critical
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    var id: String
    var severity: Severity
    var symbol: String
    var title: String
    var detail: String
    var action: AttentionAction?
}

enum AttentionAction: Equatable {
    case dashboard(DashboardSection)
    case process(String)
    case fullDiskAccess
    case tool(Tool)
    case quit(ProcessRow)

    var label: String {
        switch self {
        case .dashboard: "Review"
        case .process: "Details"
        case .fullDiskAccess: "Open Settings"
        case .tool(.processes): "See All"
        case .tool(.audit): "Run audit"
        case .tool(let tool): tool.title
        case .quit: "Quit"
        }
    }
}

struct AttentionInputs {
    var snapshot: SystemSnapshot?
    var processes: [ProcessRow]
    var clean: CleanPreview?
    var purge: PurgePreview?
    var launchItems: LaunchItemsReport?
    var lynis: LynisStatus?
    var recurring: [UsageGroup] = []
    var servers: LocalServersReport?
    var worktrees: WorktreesReport?
    var hasFullDiskAccess = true
    var now: Date = .now
}

/// Decides what goes in "Needs attention". The rule for this list: only things you
/// can act on, ranked by severity. Anything that's merely informative, like battery
/// health at 79%, lives in its tile instead, so the list stays short enough to read
/// at a glance.
enum AttentionEngine {
    static let reclaimableThreshold: Int64 = 5 * 1_073_741_824 // 5 GB
    static let auditMaxAge: TimeInterval = 30 * 86_400
    /// Flare-ups (15-minute windows above 50% CPU) in 24 h before something counts as recurring.
    static let recurringSpikes = 4

    static func items(_ input: AttentionInputs) -> [AttentionItem] {
        var items: [AttentionItem] = []

        if !input.hasFullDiskAccess {
            items.append(.init(
                id: "fda", severity: .warning, symbol: "lock.open",
                title: "Give Pollymetric Full Disk Access",
                detail: "So it can find space to free and check startup items without asking about each folder.",
                action: .fullDiskAccess
            ))
        }

        if let s = input.snapshot {
            // One process pinning the CPU is the most common "why is my Mac slow".
            // Never blame Pollymetric itself (it's only busy while rendering snapshots).
            let others = input.processes.filter { $0.pid != getpid() }
            if s.cpuSustained > 85 || (others.first?.cpu ?? 0) > 150,
               let hog = others.first, hog.cpu > 50 {
                items.append(.init(
                    id: "cpu", severity: .warning, symbol: "flame",
                    title: "\(hog.title) is using \(Int(hog.cpu))% CPU",
                    detail: [hog.subtitle, "slowing your Mac for the last 30 seconds"].compactMap { $0 }.joined(separator: " · "),
                    action: hog.identity.map { .process($0.groupKey) } ?? .quit(hog)
                ))
            }

            if s.memoryPressure != .normal {
                // Only name a process when it's genuinely holding a lot. The rows here are the
                // top CPU users, so the biggest of them may be small, and blaming 116 MB for
                // low memory is wrong.
                let top = input.processes.filter { $0.pid != getpid() && $0.memoryBytes >= 1_073_741_824 }
                    .max { $0.memoryBytes < $1.memoryBytes }
                items.append(.init(
                    id: "memory", severity: s.memoryPressure == .critical ? .critical : .warning,
                    symbol: "memorychip",
                    title: s.memoryPressure == .critical ? "Your Mac is out of memory" : "Your Mac is running low on memory",
                    detail: top.map { "\($0.title) is using \(Bytes.format($0.memoryBytes))." } ?? "Apps may slow down. Quitting ones you aren't using frees some up.",
                    action: .tool(.processes)
                ))
            }

            if s.diskUsedPercent > 80 {
                items.append(.init(
                    id: "disk", severity: s.diskUsedPercent > 93 ? .critical : .warning,
                    symbol: "internaldrive",
                    title: s.diskUsedPercent > 93 ? "Disk is almost full" : "Disk is filling up",
                    detail: "\(Bytes.format(s.diskFreeBytes)) free of \(Bytes.format(s.diskTotalBytes)).",
                    action: .dashboard(.cleanup)
                ))
            }

            if s.uptime > 14 * 86_400 {
                items.append(.init(
                    id: "uptime", severity: .suggestion, symbol: "arrow.clockwise",
                    title: "Restart recommended",
                    detail: "Up for \(Relative.uptime(s.uptime)). A restart clears leaked memory and applies updates.",
                    action: nil
                ))
            }
        }

        // The classic agent leftover: a dev server whose agent finished and quit.
        if let left = input.servers?.servers.filter(\.leftRunning), let first = left.first {
            items.append(.init(
                id: "servers-left", severity: .warning, symbol: "network",
                title: left.count == 1 ? "localhost:\(first.port) was left running" : "\(left.count) servers were left running",
                detail: left.count == 1
                    ? "\(first.what) · \(first.origin)"
                    : "Started by agents that have since quit: " + left.prefix(2).map { "localhost:\($0.port)" }.joined(separator: ", "),
                action: .dashboard(.servers)
            ))
        }

        // Copies of projects agents made for a task and never cleaned up.
        if let report = input.worktrees {
            let idle = report.worktrees.filter { tree in
                !tree.isStale && tree.inUseBy.isEmpty
                    && (tree.lastModified.map { input.now.timeIntervalSince($0) > 7 * 86_400 } ?? false)
            }
            let bytes = idle.reduce(Int64(0)) { $0 + $1.bytes }
            if bytes >= reclaimableThreshold {
                items.append(.init(
                    id: "worktrees", severity: .suggestion, symbol: "arrow.triangle.branch",
                    title: "\(Bytes.format(bytes)) in worktrees nobody's using",
                    detail: "\(idle.count) extra copies of your projects, untouched for over a week.",
                    action: .dashboard(.worktrees)
                ))
            }
        }

        if let report = input.launchItems {
            let flagged = report.flaggedPaths
            if !flagged.isEmpty {
                let names = flagged.map { ($0 as NSString).lastPathComponent }
                items.append(.init(
                    id: "launch", severity: .warning, symbol: "exclamationmark.shield",
                    title: flagged.count == 1 ? "1 startup item from an unknown developer" : "\(flagged.count) startup items from unknown developers",
                    detail: names.prefix(2).joined(separator: ", ") + (names.count > 2 ? " and \(names.count - 2) more" : ""),
                    action: .dashboard(.launchItems)
                ))
            }
        }

        if let status = input.lynis {
            if let report = status.report {
                if !report.warnings.isEmpty {
                    items.append(.init(
                        id: "lynis-warnings", severity: .warning, symbol: "lock.trianglebadge.exclamationmark",
                        title: report.warnings.count == 1 ? "1 security warning" : "\(report.warnings.count) security warnings",
                        detail: report.warnings[0].text,
                        action: .dashboard(.security)
                    ))
                } else if input.now.timeIntervalSince(report.date) > auditMaxAge {
                    items.append(.init(
                        id: "lynis-stale", severity: .suggestion, symbol: "checkmark.shield",
                        title: "Security audit is out of date",
                        detail: "Last run \(Relative.string(report.date, now: input.now)).",
                        action: .tool(.audit)
                    ))
                }
            } else {
                items.append(.init(
                    id: "lynis-never", severity: .suggestion, symbol: "checkmark.shield",
                    title: "No security audit yet",
                    detail: "Find out how well this Mac is protected. Takes about a minute.",
                    action: .tool(.audit)
                ))
            }
        }

        // Something that keeps coming back is worth fixing at the source, even if it's
        // quiet right now. Show only the worst one, and skip it if it's the live hog above.
        let liveHog = input.processes.first?.identity?.groupKey
        if let worst = input.recurring.first(where: { $0.groupKey != liveHog || !items.contains { $0.id == "cpu" } }) {
            let minutes = Int((worst.cpuSeconds / 60).rounded())
            items.append(.init(
                id: "recurring-\(worst.groupKey)", severity: .suggestion, symbol: "arrow.triangle.2.circlepath",
                title: "\(worst.label) keeps spiking",
                detail: "\(worst.spikes) flare-ups and \(minutes) min of CPU in the last 24h"
                    + (worst.subtitle.isEmpty ? "" : " · \(worst.subtitle)"),
                action: .process(worst.groupKey)
            ))
        }

        let cacheBytes = input.clean?.totalBytes ?? 0
        let buildBytes = input.purge?.totalBytes ?? 0
        if cacheBytes + buildBytes >= reclaimableThreshold {
            var parts: [String] = []
            if cacheBytes > 0 { parts.append("\(Bytes.format(cacheBytes)) caches") }
            if buildBytes > 0 { parts.append("\(Bytes.format(buildBytes)) build folders") }
            items.append(.init(
                id: "reclaim", severity: .suggestion, symbol: "sparkles",
                title: "\(Bytes.format(cacheBytes + buildBytes)) can be freed",
                detail: parts.joined(separator: " · "),
                action: .dashboard(cacheBytes >= buildBytes ? .cleanup : .projects)
            ))
        }

        return items.sorted { $0.severity > $1.severity }
    }
}
