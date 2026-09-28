import SwiftUI

/// A conversation with an agent about one process. It takes over the dashboard's main
/// area while the process's details stay in the inspector beside it.
///
/// The transcript is calm by default: the brief is one line, each tool call is one line
/// (click for the command and its output), finished runs of tools fold into "Used 6
/// tools", and thinking stays collapsed. The answer is the thing you read.
struct AgentWorkspace: View {
    @Bindable var conversation: AgentConversation
    var close: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        TranscriptItemView(item: item)
                            .padding(.bottom, item.isAnswer ? 6 : 0)
                    }
                    if conversation.busy, conversation.permissions.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(items.isEmpty ? "Starting \(conversation.record.harness)…" : "Working…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let error = conversation.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            // Short conversations start at the top; as it grows, follow the newest text.
            // No animation: this fires for every streamed update.
            .onChange(of: progress) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }

            ForEach(conversation.permissions) { request in
                PermissionCard(request: request, agent: conversation.record.harness) { conversation.answer(request, option: $0) }
                    .padding(.horizontal, 28).padding(.bottom, 10)
                    .frame(maxWidth: 760).frame(maxWidth: .infinity)
            }
            if !conversation.closed { composer }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Links in an answer open in the browser, nowhere else: file:// and app URL
        // schemes could open or run things with one click.
        .environment(\.openURL, OpenURLAction { url in
            ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let harness = conversation.harness ?? ProviderLogos.installation(named: conversation.record.harness) {
                ProviderLogo(harness: harness, size: 32)
            } else {
                Image(systemName: "text.bubble").font(.title2).foregroundStyle(.secondary).frame(width: 32, height: 32)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            statusPill
            if conversation.busy, !conversation.closed {
                Button("Stop") { conversation.stop() }.controlSize(.small)
            }
            Menu {
                if conversation.harness != nil, !conversation.closed {
                    Button("Continue in iTerm") { conversation.continueInTerminal() }
                }
                Button("Copy Answer") { Paths.copy(conversation.record.answer) }
                    .disabled(conversation.record.answer.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button { conversation.close(); close() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain).help("Close the conversation")
        }
        // Same top inset as the inspector's header, so the two titles line up.
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var title: String {
        let subject = conversation.record.displaySubject
        return conversation.record.ask == Assistant.Ask.explain.title ? "Explaining \(subject)" : "Finding a fix for \(subject)"
    }

    private var subtitle: String {
        var parts = [conversation.record.harness, conversation.record.account]
        if conversation.closed, conversation.harness == nil {
            parts.append(Relative.string(conversation.record.started))
        } else {
            parts.append(conversation.mode == "Default" ? "agent's default mode" : "\(conversation.mode) mode")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusPill: some View {
        let (text, color): (String, Color) = {
            if conversation.error != nil { return ("Failed", .orange) }
            if conversation.busy { return ("Working", .accentColor) }
            switch conversation.record.status {
            case "stopped": return ("Stopped", .secondary)
            case "answered": return ("Answered", HealthBand.excellent.color)
            default: return (conversation.closed ? "Closed" : "Ready", .secondary)
            }
        }()
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a follow-up…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .onSubmit(send)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).frame(width: 30, height: 30)
                    .background(Circle().fill(canSend ? Color.accentColor : Color.primary.opacity(0.1)))
                    .foregroundStyle(canSend ? .white : .secondary)
            }
            .buttonStyle(.plain).disabled(!canSend)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .frame(maxWidth: 760).frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Changes whenever the transcript grows, so the view can follow it.
    private var progress: Int {
        conversation.record.transcript.count * 100_000 + (conversation.record.transcript.last?.text.count ?? 0)
            + conversation.permissions.count
    }

    private var canSend: Bool { !conversation.busy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        Task { await conversation.send(text) }
    }

    // MARK: Transcript model

    private var items: [TranscriptItem] {
        TranscriptItem.build(conversation.record.transcript, turnInProgress: conversation.busy)
    }
}

/// The transcript as the reader sees it: consecutive tool calls grouped, plan entries
/// gathered into one checklist, the opening brief separated from real follow-ups.
enum TranscriptItem: Identifiable {
    case brief(String)
    case user(String)
    case thought(id: String, text: String)
    case answer(id: String, text: String)
    case plan([AgentEntry])
    case tools(id: String, entries: [AgentEntry], active: Bool)

    var isAnswer: Bool { if case .answer = self { return true } else { return false } }

    var id: String {
        switch self {
        case .brief: "brief"
        case .user(let text): "user-\(text.hashValue)"
        case .thought(let id, _), .answer(let id, _): id
        case .plan: "plan"
        case .tools(let id, _, _): "tools-\(id)"
        }
    }

    static func build(_ transcript: [AgentEntry], turnInProgress: Bool) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var tools: [AgentEntry] = []
        var sawBrief = false

        func flushTools(active: Bool) {
            guard let first = tools.first else { return }
            items.append(.tools(id: first.id, entries: tools, active: active))
            tools = []
        }

        for (index, entry) in transcript.enumerated() {
            if entry.isTool { tools.append(entry); continue }
            if entry.kind == "plan" { continue } // shown once, below
            flushTools(active: false)
            switch entry.kind {
            case "user":
                if !sawBrief { items.append(.brief(entry.text)); sawBrief = true } else { items.append(.user(entry.text)) }
            case "agent_thought_chunk":
                items.append(.thought(id: entry.id + "\(index)", text: entry.text))
            case "agent_message_chunk":
                items.append(.answer(id: entry.id + "\(index)", text: entry.text))
            default:
                break
            }
        }
        // The group still being worked on stays expanded.
        flushTools(active: turnInProgress)
        let plan = transcript.filter { $0.kind == "plan" }
        if !plan.isEmpty { items.insert(.plan(plan), at: max(0, items.count - 1)) }
        return items
    }
}

private struct TranscriptItemView: View {
    var item: TranscriptItem

    var body: some View {
        switch item {
        case .brief(let text):
            QuietDisclosure(symbol: "doc.text", title: "Sent the brief: the process, its runs and history, and this Mac's state") {
                Text(text).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
        case .user(let text):
            HStack {
                Spacer(minLength: 80)
                Text(text).font(.system(size: MarkdownText.bodySize)).lineSpacing(MarkdownText.lineSpacing).textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.1)))
            }
        case .thought(_, let text):
            QuietDisclosure(symbol: "brain", title: "Thinking") {
                MarkdownText(text: text).foregroundStyle(.secondary)
            }
        case .answer(_, let text):
            MarkdownText(text: text)
        case .plan(let entries):
            VStack(alignment: .leading, spacing: 5) {
                Text("Plan").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(entries) { entry in
                    Label(entry.text, systemImage: entry.status == "completed" ? "checkmark.circle.fill"
                          : entry.status == "in_progress" ? "circle.dotted" : "circle")
                        .font(.callout)
                        .foregroundStyle(entry.status == "completed" ? .secondary : .primary)
                }
            }
        case .tools(_, let entries, let active):
            ToolGroup(entries: entries, active: active)
        }
    }
}

/// Consecutive tool calls. While the agent works they're listed; once finished, three
/// or more fold into a single "Used 6 tools" line.
private struct ToolGroup: View {
    var entries: [AgentEntry]
    var active: Bool
    @State private var expanded = false

    private var failed: Int { entries.filter { $0.status == "failed" }.count }

    var body: some View {
        if active || entries.count < 3 {
            rows
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Button { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Image(systemName: "wrench.and.screwdriver").font(.caption)
                        Text("Used \(entries.count) tools" + (failed > 0 ? " · \(failed) failed" : ""))
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded { rows.padding(.leading, 16) }
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entries) { ToolRow(entry: $0) }
        }
    }
}

/// One tool call as one line. Click for what it ran and what came back.
private struct ToolRow: View {
    var entry: AgentEntry
    @State private var expanded = false
    @State private var hovering = false

    private var hasDetail: Bool { entry.input != nil || entry.output != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if hasDetail { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } } } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.caption).frame(width: 16).foregroundStyle(.secondary)
                    Text(entry.text).font(.callout).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(entry.status == "failed" ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    Spacer(minLength: 8)
                    status
                    if hasDetail {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .opacity(hovering || expanded ? 1 : 0.4)
                    }
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = entry.input { CodeBlock(label: entry.toolKind == "execute" ? "Command" : "Input", text: input) }
                    if let output = entry.output { CodeBlock(label: "Output", text: output) }
                }
                .padding(.leading, 30)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch entry.status {
        case "pending", "in_progress", nil: ProgressView().controlSize(.mini)
        case "failed": Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.orange)
        default: Image(systemName: "checkmark").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
    }

    private var symbol: String {
        switch entry.toolKind {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.right.doc.on.clipboard"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "brain"
        case "fetch": "globe"
        case "switch_mode": "arrow.triangle.swap"
        default: "gearshape"
        }
    }
}

/// An approval the agent is waiting on. Nothing runs until you pick an option.
private struct PermissionCard: View {
    var request: AgentPermission
    var agent: String
    var choose: (String) -> Void
    @State private var showDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("\(agent) wants to: \(request.title)").font(.callout.weight(.semibold)).lineLimit(2)
            }
            if !request.details.isEmpty {
                Button(showDetails ? "Hide details" : "Show details") { showDetails.toggle() }
                    .buttonStyle(.link).font(.caption)
                if showDetails { CodeBlock(label: nil, text: request.details) }
            }
            HStack(spacing: 8) {
                // No prominent choice: the details above are what should decide it.
                ForEach(request.options, id: \.id) { option in
                    Button(option.name) { choose(option.id) }
                }
            }
            .controlSize(.regular)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }
}

/// A collapsed-by-default line for secondary material (the brief, the agent's thinking).
private struct QuietDisclosure<Content: View>: View {
    var symbol: String
    var title: String
    @ViewBuilder var content: Content
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.smooth(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Image(systemName: symbol).font(.caption)
                    Text(title).font(.callout).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                content
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            }
        }
    }
}

private struct CodeBlock: View {
    var label: String?
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label { Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
            ScrollView {
                Text(text).font(.system(size: 12.5, design: .monospaced)).lineSpacing(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}

/// Renders the agent's Markdown for comfortable reading: 14 pt text at about 1.5×
/// line height, a measure capped near 70 characters, generous paragraph spacing, and
/// headings with more space above than below. SF's built-in size-specific tracking is
/// left alone; it's already tuned for this size. Handles headings, lists, block
/// quotes, tables, rules and fenced code.
struct MarkdownText: View {
    var text: String

    static let bodySize: CGFloat = 14
    static let lineSpacing: CGFloat = 5
    static let measure: CGFloat = 680

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { index, block in
                switch block {
                case .heading(let level, let content):
                    inline(content)
                        .font(.system(size: level == 1 ? 20 : (level == 2 ? 17 : 15), weight: .semibold))
                        .padding(.top, index == 0 ? 0 : 8)
                case .list(let items):
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.marker).foregroundStyle(.secondary).frame(minWidth: 16, alignment: .trailing)
                                inline(item.text)
                            }
                        }
                    }
                    .font(.system(size: Self.bodySize)).lineSpacing(Self.lineSpacing)
                case .quote(let content):
                    inline(content).font(.system(size: Self.bodySize)).lineSpacing(Self.lineSpacing).foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(.separator).frame(width: 2) }
                case .label(let content):
                    inline(content).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .textCase(nil).padding(.top, 4)
                case .rule:
                    Divider().padding(.vertical, 2)
                case .table(let header, let rows):
                    MarkdownTable(header: header, rows: rows, inline: inline)
                case .code(let content):
                    CodeBlock(label: nil, text: content)
                case .paragraph(let content):
                    inline(content).font(.system(size: Self.bodySize)).lineSpacing(Self.lineSpacing)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: Self.measure, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
             ?? AttributedString(text))
    }

    enum Block {
        case heading(Int, String), list([(marker: String, text: String)]), quote(String), code(String), paragraph(String)
        case table(header: [String], rows: [[String]]), rule, label(String)
    }

    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parsed blocks, cached by text: a long answer is otherwise re-parsed on every
    /// render while the transcript around it streams.
    nonisolated(unsafe) private static var cache: [String: [Block]] = [:]

    static func blocks(_ text: String) -> [Block] {
        if let cached = cache[text] { return cached }
        let parsed = parse(text)
        if cache.count > 64 { cache.removeAll() }
        cache[text] = parsed
        return parsed
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [[String]] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !table.isEmpty {
                // Markdown tables: header row, a |---| separator, then body rows.
                let rows = table.filter { !$0.allSatisfy { $0.allSatisfy { "-:| ".contains($0) } } }
                if let header = rows.first { blocks.append(.table(header: header, rows: Array(rows.dropFirst()))) }
                table = []
            }
        }
        func addItem(_ marker: String, _ text: String) {
            flush()
            if case .list(var items) = blocks.last {
                items.append((marker, text)); blocks[blocks.count - 1] = .list(items)
            } else {
                blocks.append(.list([(marker, text)]))
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code { blocks.append(.code(open.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.hasPrefix("|"), line.dropFirst().contains("|") {
                if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
                table.append(cells(line)); continue
            }
            if line.isEmpty { flush(); continue }
            // Rules: ---, ***, ___, or a run of box-drawing dashes (─) around a label
            // such as "★ Insight ─────".
            if line.wholeMatch(of: #/[-*_─━]{3,}/#) != nil { flush(); blocks.append(.rule); continue }
            if line.contains("───") {
                let label = line.replacingOccurrences(of: #"[─━`]{3,}"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                flush(); blocks.append(label.isEmpty ? .rule : .label(label)); continue
            }
            if let match = line.wholeMatch(of: #/(#{1,6})\s+(.+)/#) {
                flush(); blocks.append(.heading(match.1.count, String(match.2)))
            } else if let match = line.wholeMatch(of: #/[-*•]\s+(.+)/#) {
                addItem("•", String(match.1))
            } else if let match = line.wholeMatch(of: #/(\d+)[.)]\s+(.+)/#) {
                addItem("\(match.1).", String(match.2))
            } else if let match = line.wholeMatch(of: #/>\s?(.*)/#) {
                flush(); blocks.append(.quote(String(match.1)))
            } else {
                paragraph.append(line)
            }
        }
        if let open = code { blocks.append(.code(open.joined(separator: "\n"))) }
        flush()
        return blocks
    }
}

/// A Markdown table: header in semibold, hairline row dividers, compact type.
private struct MarkdownTable: View {
    var header: [String]
    var rows: [[String]]
    var inline: (String) -> Text

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
            GridRow { ForEach(Array(header.enumerated()), id: \.offset) { inline($0.element).fontWeight(.semibold) } }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow { ForEach(Array(header.indices), id: \.self) { i in inline(i < row.count ? row[i] : "") } }
                if index < rows.count - 1 { Divider().gridCellUnsizedAxes(.horizontal).opacity(0.5) }
            }
        }
        .font(.system(size: 13))
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}
