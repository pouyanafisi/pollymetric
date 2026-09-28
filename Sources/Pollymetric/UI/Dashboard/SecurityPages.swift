import SwiftUI

struct LaunchItemsPage: View {
    @Bindable var store: AppStore
    @State private var flaggedOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Launch Items",
                subtitle: "Everything that starts by itself when you log in. Anything from an unidentified developer is flagged.",
                updatedAt: store.launchItems.updatedAt, isFetching: store.launchItems.isFetching, error: store.launchItems.error,
                refresh: { store.launchItems.refresh() }
            )

            if let report = store.launchItems.value {
                let flagged = report.flaggedPaths.count
                Hero(
                    value: flagged == 0 ? "All signed" : "\(flagged) unsigned",
                    caption: "\(report.items.count) items across \(report.categories.filter { !$0.items.isEmpty }.count) categories"
                ) {
                    VStack(alignment: .trailing, spacing: 8) {
                        Toggle("Only unsigned", isOn: $flaggedOnly).toggleStyle(.switch).controlSize(.small)
                        Button("Open KnockKnock") { store.open(.launchItems) }.controlSize(.small)
                    }
                }

                let groups = report.categories
                    .map { ($0.name, flaggedOnly ? $0.items.filter(\.isFlagged) : $0.items) }
                    .filter { !$0.1.isEmpty }

                if groups.isEmpty {
                    EmptyState(symbol: "checkmark.shield", title: "Nothing unsigned", message: "Everything that starts by itself comes from an identified developer.")
                }
                ForEach(groups, id: \.0) { name, items in
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(title: name, trailing: "\(items.count)")
                        Card {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                LaunchItemRow(item: item)
                            }
                        }
                    }
                }
            } else if store.launchItems.isFetching {
                EmptyState(symbol: "power", title: "Scanning…", message: "Checking everything that starts by itself. This takes a few minutes in the background.")
            } else {
                EmptyState(symbol: "power", title: "No scan yet", message: "Click the refresh button to scan.")
            }
        }
    }
}

struct LaunchItemRow: View {
    var item: LaunchItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(.callout.weight(.medium))
                    if let badge { Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(tint) }
                }
                Text(Paths.abbreviate(item.path)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(item.path)
                if let signer = item.signer {
                    Text(signer).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal in Finder") { Paths.reveal(item.path) }
            if let plist = item.plist { Button("Reveal Launch Plist") { Paths.reveal(plist) } }
            Button("Copy Path") { Paths.copy(item.path) }
        }
    }

    private var icon: String {
        switch item.trust {
        case .trusted: "checkmark.seal"
        case .notNotarized: "seal"
        case .unsigned: "exclamationmark.triangle.fill"
        case .unverified: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch item.trust {
        case .trusted: .secondary
        case .notNotarized: .secondary
        case .unsigned: item.isFlagged ? .orange : .secondary
        case .unverified: .secondary
        }
    }

    private var badge: String? {
        switch item.trust {
        case .trusted: nil
        case .notNotarized: "NOT NOTARIZED"
        case .unsigned: item.isShellConfig ? nil : "UNSIGNED"
        case .unverified: "COULDN'T VERIFY"
        }
    }
}

struct SecurityPage: View {
    @Bindable var store: AppStore
    @State private var showAllSuggestions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Security Audit",
                subtitle: "How well this Mac is protected, and what to tighten.",
                updatedAt: store.lynis.value?.report?.date, isFetching: false, error: nil,
                refresh: nil
            )

            if store.isAuditing { ProgressView("Running security audit…") }
            if let error = store.auditError { Text(error).foregroundStyle(.secondary) }
            if let report = store.lynis.value?.report {
                Card {
                    HStack(spacing: 20) {
                        let index = report.hardeningIndex ?? 0
                        ScoreRing(score: index, band: HealthBand(score: index), size: 80, lineWidth: 8)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hardening index").font(.title3.weight(.semibold))
                            Text("\(report.warnings.count) warnings · \(report.suggestions.count) suggestions")
                                .foregroundStyle(.secondary)
                            Text("Audited \(Relative.string(report.date))" + (report.version.map { " · Lynis \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Run Again") { store.runAudit() }.disabled(store.isAuditing)
                    }
                }

                if !report.warnings.isEmpty {
                    findings("Warnings", report.warnings, symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
                let suggestions = showAllSuggestions ? report.suggestions : Array(report.suggestions.prefix(8))
                if !suggestions.isEmpty {
                    findings("Suggestions", suggestions, symbol: "lightbulb", tint: .blue)
                    if report.suggestions.count > 8 {
                        Button(showAllSuggestions ? "Show fewer" : "Show all \(report.suggestions.count) suggestions") {
                            showAllSuggestions.toggle()
                        }
                        .buttonStyle(.link)
                    }
                }
            } else {
                Card {
                    EmptyState(
                        symbol: "checkmark.shield",
                        title: "No audit yet",
                        message: "Find out how well this Mac is protected and what to tighten. macOS asks for your password first. Takes about a minute."
                    )
                    HStack {
                        Spacer()
                        Button("Run Security Audit") { store.runAudit() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(store.isAuditing)
                        Spacer()
                    }
                }
            }
        }
    }

    private func findings(_ title: String, _ items: [LynisFinding], symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title, trailing: "\(items.count)")
            Card {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, finding in
                    if index > 0 { Divider() }
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(finding.text).font(.callout)
                            if let details = finding.details {
                                Text(details).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Text(finding.testID).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                if let url = finding.controlURL {
                                    Link("How to fix", destination: url).font(.caption2)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                    .textSelection(.enabled)
                }
            }
        }
    }
}

struct HistoryPage: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "History",
                subtitle: "Space you've freed, and when.",
                updatedAt: store.history.updatedAt, isFetching: store.history.isFetching, error: store.history.error,
                refresh: { store.history.refresh() }
            )
            let sessions = (store.history.value ?? []).filter(\.didWork)
            if sessions.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "No cleanups yet", message: "Cleanups you run will appear here.")
            } else {
                Card {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider() }
                        HStack {
                            Text(session.command?.capitalized ?? "—").font(.callout.weight(.medium)).frame(width: 90, alignment: .leading)
                            Text(session.startedAt ?? "").foregroundStyle(.secondary)
                            Spacer()
                            Text("\(session.items ?? 0) items").foregroundStyle(.secondary)
                            Text(session.size ?? "").monospacedDigit().frame(width: 80, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}
