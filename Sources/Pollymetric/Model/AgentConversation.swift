import Foundation
import HarnessKit
import Observation

struct AgentEntry: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var kind: String
    var text: String
    var status: String? = nil
    /// Tool calls: the ACP tool kind (read, edit, execute, search, fetch, think, other),
    /// what it was asked to do, and what came back. Shown only when a row is expanded.
    var toolKind: String? = nil
    var input: String? = nil
    var output: String? = nil

    var isTool: Bool { kind.hasPrefix("tool") }
}

struct AgentRecord: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var groupKey: String
    var harness: String
    var account: String
    var ask: String
    var started = Date()
    var ended: Date?
    var status = "running"
    var answer = ""
    var transcript: [AgentEntry] = []
    /// The process it's about ("tsup"), for the conversation's header.
    var subject: String? = nil

    /// The subject, falling back to the label inside the group key ("app|label|project"),
    /// which saved records always have.
    var displaySubject: String {
        if let subject, !subject.isEmpty { return subject }
        let parts = groupKey.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : "a process"
    }
}

extension AgentConversation {
    /// One-time answers only, "Don't allow" first. A standing "Always allow" would let
    /// the agent skip asking for the rest of the session, which this pane never grants.
    nonisolated static func permissionOptions(_ raw: [[String: Any]]) -> [(id: String, name: String)] {
        let rank = ["reject_once": 0, "reject_always": 1, "allow_once": 2]
        return raw.compactMap { option -> (Int, String, String)? in
            guard let id = option["optionId"] as? String, let name = option["name"] as? String,
                  let order = rank[option["kind"] as? String ?? "allow_once"] else { return nil }
            return (order, id, name)
        }
        .sorted { $0.0 < $1.0 }
        .map { ($0.1, $0.2) }
    }
}

struct AgentPermission: Identifiable {
    var id: String
    var title: String
    var details: String
    var options: [(id: String, name: String)]
}

@MainActor @Observable
final class AgentConversation {
    var record: AgentRecord
    var permissions: [AgentPermission] = []
    var mode = "Connecting…"
    var busy = true
    var closed = false
    var error: String?
    let harness: HarnessInstallation?
    @ObservationIgnored private let client = ACPClient()
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private var turn = 0
    @ObservationIgnored private var fallback: (() -> Void)?
    /// Streamed text waiting to be applied. Agents send many tiny chunks a second;
    /// applying each one re-renders the transcript, so they're batched (~12 a second).
    @ObservationIgnored private var pendingChunks: [(kind: String, text: String)] = []
    @ObservationIgnored private var flushScheduled = false

    init(record: AgentRecord, history: HistoryStore = .shared) {
        self.record = record; self.history = history; harness = nil
        busy = false; closed = true; mode = "Saved answer"
    }

    init(group: String, ask: Assistant.Ask, harness: HarnessInstallation, account: HarnessAccount?, context: Assistant.Context,
         history: HistoryStore = .shared) {
        self.harness = harness; self.history = history
        record = AgentRecord(groupKey: group, harness: harness.descriptor.name,
                             account: account.map { $0.identity ?? $0.label } ?? "default", ask: ask.title, subject: context.title)
        fallback = { Assistant.open(ask, harness: harness, account: account, context: context) }
        client.onUpdate = { [weak self] in self?.update($0) }
        client.onPermission = { [weak self] key, params in
            let call = params["toolCall"] as? [String: Any] ?? [:]
            let details = (try? JSONSerialization.data(withJSONObject: call, options: [.prettyPrinted, .sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            self?.permissions.append(AgentPermission(id: key, title: call["title"] as? String ?? "Agent requests permission", details: details,
                options: Self.permissionOptions(params["options"] as? [[String: Any]] ?? [])))
        }
        client.onExit = { [weak self] in
            guard let self, !self.closed else { return }
            self.error = "The agent disconnected."; self.close()
        }
        save()
        Task {
            do {
                let path = await HarnessDetector.shared.shellPath()
                guard !closed else { return }
                let cwd = (context.focus ?? context.runs.first)?.cwd
                    .flatMap { ProcessDescriber.meaningfulFolder($0) != nil ? $0 : nil } ?? Assistant.briefsDirectory.path
                try await client.start(argv: harness.descriptor.acp ?? [], environment: HarnessProcess.environment(harness.descriptor, account: account, path: path),
                                       cwd: cwd, claude: harness.id == "claude-code", explain: ask == .explain)
                mode = client.mode
                busy = false
                await send(Assistant.markdown(ask, context: context))
            } catch {
                if !closed { self.error = error.localizedDescription; close() }
            }
        }
    }

    func send(_ text: String) async {
        guard !busy, !closed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        turn += 1
        busy = true; record.status = "running"; record.ended = nil
        record.answer = ""
        record.transcript.append(AgentEntry(kind: "user", text: text)); save()
        do { try await client.prompt(text); flushChunks(); if !closed && record.status != "stopped" { record.status = "answered" } }
        catch { if !closed { self.error = error.localizedDescription; close() } }
        busy = false; permissions = []; save()
    }

    func answer(_ request: AgentPermission, option: String) {
        client.answer(request.id, option: option)
        permissions.removeAll { $0.id == request.id }
    }

    func stop() {
        guard client.sessionID != nil else { close(); return }
        let stoppedTurn = turn
        client.cancel(); permissions = []
        record.status = "stopped"; save()
        Task {
            try? await Task.sleep(for: .seconds(2))
            if busy && turn == stoppedTurn { close() }
        }
    }

    func close() {
        guard !closed else { return }
        flushChunks()
        closed = true; client.close(); permissions = []; busy = false
        record.ended = .now
        if record.status == "running" { record.status = error == nil ? "stopped" : "failed" }
        save()
    }

    func continueInTerminal() { close(); fallback?() }

    func update(_ update: [String: Any]) {
        guard let kind = update["sessionUpdate"] as? String else { return }
        // Keep transcript order: text that arrived before this update lands first.
        if kind != "agent_message_chunk", kind != "agent_thought_chunk" { flushChunks() }
        switch kind {
        case "agent_message_chunk", "agent_thought_chunk":
            guard let content = update["content"] as? [String: Any], let text = content["text"] as? String else { return }
            pendingChunks.append((kind, text))
            if !flushScheduled {
                flushScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.flushChunks() }
            }
            return
        case "tool_call", "tool_call_update":
            guard let id = update["toolCallId"] as? String else { return }
            let i = record.transcript.firstIndex(where: { $0.id == id }) ?? {
                record.transcript.append(AgentEntry(id: id, kind: "tool", text: "Working", toolKind: "other"))
                return record.transcript.count - 1
            }()
            if let title = update["title"] as? String, !title.isEmpty { record.transcript[i].text = title }
            if let status = update["status"] as? String { record.transcript[i].status = status }
            if let kind = update["kind"] as? String { record.transcript[i].toolKind = kind }
            if let input = Self.toolInput(update["rawInput"]) { record.transcript[i].input = input }
            if let output = Self.toolOutput(update["content"]) { record.transcript[i].output = output }
        case "plan":
            record.transcript.removeAll { $0.kind == "plan" }
            for entry in update["entries"] as? [[String: Any]] ?? [] {
                record.transcript.append(AgentEntry(kind: "plan", text: entry["content"] as? String ?? "", status: entry["status"] as? String))
            }
        default: break
        }
    }

    /// Applies batched chunks in arrival order, merging consecutive text of one kind.
    func flushChunks() {
        flushScheduled = false
        guard !pendingChunks.isEmpty else { return }
        var transcript = record.transcript
        var answer = record.answer
        for (kind, text) in pendingChunks {
            if transcript.last?.kind == kind { transcript[transcript.count - 1].text += text }
            else { transcript.append(AgentEntry(kind: kind, text: text)) }
            if kind == "agent_message_chunk" { answer += text }
        }
        pendingChunks.removeAll()
        record.transcript = transcript
        record.answer = answer
    }

    private func save() { history.saveAgent(record) }

    /// The command for shell tools, else the arguments as compact JSON.
    nonisolated static func toolInput(_ raw: Any?) -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let dict = raw as? [String: Any] {
            if let command = dict["command"] as? String { return command }
            if let command = dict["command"] as? [String] { return command.joined(separator: " ") }
            if let path = dict["file_path"] as? String ?? dict["path"] as? String, dict.count == 1 { return path }
        }
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Text output and file diffs from a tool call's content blocks, capped so a huge
    /// log can't swamp the transcript.
    nonisolated static func toolOutput(_ raw: Any?) -> String? {
        guard let blocks = raw as? [[String: Any]], !blocks.isEmpty else { return nil }
        let parts: [String] = blocks.compactMap { block in
            switch block["type"] as? String {
            case "content":
                return (block["content"] as? [String: Any])?["text"] as? String
            case "diff":
                let path = block["path"] as? String ?? "a file"
                let added = (block["newText"] as? String)?.split(separator: "\n", omittingEmptySubsequences: false).count ?? 0
                return "Edited \(path) (\(added) lines)"
            default:
                return nil
            }
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > 8_000 ? String(text.prefix(8_000)) + "\n…" : text
    }
}
