import Foundation
import Observation

enum InteractionKind: String, Sendable {
    case popoverOpen = "popover_open", sectionView = "section_view", processInspect = "process_inspect"
    case agentAsk = "agent_ask", processQuit = "process_quit", clean, purge, toolOpen = "tool_open", mcpCall = "mcp_call"
}

struct InspectionPattern: Identifiable, Sendable {
    var id: String { target }
    var target: String
    var context: String?
    var count: Int
    var lastInspected: Date
    var label: String

    var title: String {
        guard let context, context != "/", context != NSHomeDirectory(), !context.isEmpty else { return label }
        return "\(label) in \((context as NSString).lastPathComponent)"
    }
}

@MainActor @Observable
final class UsagePatterns {
    private(set) var frequent: [InspectionPattern] = []
    private(set) var weekly: [InspectionPattern] = []
    var enabled: Bool {
        didSet {
            preferences.set(enabled, forKey: "learnFromUsage")
            revision += 1
            if !enabled { frequent = []; weekly = [] }
            else { Task { await refresh() } }
        }
    }
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let preferences: LocalPreferences
    @ObservationIgnored private var revision = 0

    init(history: HistoryStore = .shared, preferences: LocalPreferences = DataDirectory.preferences) {
        self.history = history; self.preferences = preferences
        enabled = preferences.object(forKey: "learnFromUsage") as? Bool ?? true
    }

    func record(_ kind: InteractionKind, target: String? = nil, context: String? = nil) {
        guard enabled, !DataDirectory.isSnapshot else { return }
        history.recordInteraction(kind, target: target, context: context)
        if kind == .processInspect { Task { await refresh() } }
    }

    func refresh() async {
        guard enabled else { return }
        revision += 1; let version = revision
        async let fortnight = history.inspectionPatterns(since: Date().addingTimeInterval(-14 * 86_400))
        async let week = history.inspectionPatterns(since: Date().addingTimeInterval(-7 * 86_400))
        let (f, w) = await (fortnight, week)
        guard version == revision, enabled else { return }
        frequent = f; weekly = w
    }

    func clear() async {
        revision += 1; frequent = []; weekly = []
        await history.clearInteractions()
    }

    /// Five inspections, and twice the runner-up, keeps the overview from declaring weak patterns.
    var clearPattern: InspectionPattern? {
        guard enabled, let first = weekly.first, first.count >= 5,
              weekly.count < 2 || first.count >= weekly[1].count * 2 else { return nil }
        return first
    }

    func ranked(_ rows: [ProcessRow]) -> [ProcessRow] {
        guard enabled else { return rows }
        let counts = Dictionary(uniqueKeysWithValues: frequent.map { ($0.target, $0.count) })
        return rows.enumerated().sorted { left, right in
            let l = Int(left.element.cpu), r = Int(right.element.cpu)
            if l != r { return l > r }
            let lc = counts[left.element.identity?.groupKey ?? ""] ?? 0
            let rc = counts[right.element.identity?.groupKey ?? ""] ?? 0
            return lc == rc ? left.offset < right.offset : lc > rc
        }.map(\.element)
    }
}
