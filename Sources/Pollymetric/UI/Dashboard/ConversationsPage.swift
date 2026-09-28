import HarnessKit
import SwiftUI

/// Every conversation Pollymetric has started with an agent, newest first, grouped by
/// day. Opening one shows its transcript in the main area with its process alongside.
struct ConversationsPage: View {
    @Bindable var store: AppStore
    @State private var records: [AgentRecord] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Conversations",
                       subtitle: "Everything you've asked an AI agent about this Mac. Private to this Mac.",
                       updatedAt: nil, isFetching: false, error: nil, refresh: nil)

            if loaded && records.isEmpty {
                EmptyState(symbol: "text.bubble", title: "No conversations yet",
                           message: "Click a process, then Explain or Find a Fix. Conversations appear here.")
            }
            ForEach(days, id: \.title) { day in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: day.title, trailing: "\(day.records.count)")
                    Card {
                        ForEach(Array(day.records.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { Divider() }
                            ConversationRow(record: record, isOpen: store.agent?.record.id == record.id,
                                            isLive: store.agent?.record.id == record.id && store.agent?.closed == false) {
                                store.openConversation(id: record.id)
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: store.agent?.record.status) { Task { await load() } }
    }

    private func load() async {
        records = await HistoryStore.shared.allAgentSessions()
        loaded = true
    }

    private var days: [(title: String, records: [AgentRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.started) }
        return grouped.keys.sorted(by: >).map { day in
            let title = calendar.isDateInToday(day) ? "Today"
                : calendar.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            return (title, grouped[day]!.sorted { $0.started > $1.started })
        }
    }
}

private struct ConversationRow: View {
    var record: AgentRecord
    var isOpen: Bool
    var isLive: Bool
    var open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 12) {
                logo
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.callout.weight(.semibold)).foregroundStyle(Color.label)
                        status
                    }
                    Text("\(record.harness) · \(record.account) · \(record.started.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    if let preview {
                        Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.5)
            }
            .padding(.vertical, 6).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isOpen ? Color.accentColor.opacity(0.1) : Color.primary.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var title: String {
        (record.ask == Assistant.Ask.explain.title ? "Explained " : "Looked for a fix for ") + record.displaySubject
    }

    /// The answer's first real sentence, without Markdown markers.
    private var preview: String? {
        let line = record.answer.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("|") && !$0.hasPrefix("```") && !$0.contains("───") }
        return line.map { $0.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }
    }

    @ViewBuilder
    private var logo: some View {
        if let harness = ProviderLogos.installation(named: record.harness) {
            ProviderLogo(harness: harness, size: 22)
        } else {
            Image(systemName: "text.bubble").foregroundStyle(.secondary).frame(width: 22, height: 22)
        }
    }

    @ViewBuilder
    private var status: some View {
        let (text, color): (String, Color) = isLive ? ("Running", .accentColor) : {
            switch record.status {
            case "answered": return ("Answered", HealthBand.excellent.color)
            case "failed": return ("Failed", .orange)
            case "stopped": return ("Stopped", .secondary)
            case "running": return ("Interrupted", .secondary)
            default: return (record.status.capitalized, .secondary)
            }
        }()
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
