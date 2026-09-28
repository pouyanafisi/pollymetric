import SwiftUI

struct ConnectionsPage: View {
    @Bindable var model: ConnectionsModel
    @State private var pairing = false
    @State private var revoke: MCPClientRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Connections", subtitle: "Agents you allow to use Pollymetric.", updatedAt: nil,
                       isFetching: false, error: model.error, refresh: nil)
            HStack {
                Text("Each connection has its own access. Actions always need your approval.").foregroundStyle(.secondary)
                Spacer()
                Button("Connect an agent…") { pairing = true }
            }
            ForEach(model.approvals) { request in
                Card {
                    Text("\(request.client.name) requests an action").font(.headline)
                    Text(request.tool.name).font(.callout.monospaced())
                    Text(request.effect).font(.callout)
                    DisclosureGroup("Arguments") { Text(request.arguments).font(.caption.monospaced()).textSelection(.enabled) }
                    Text("Expires \(request.expires, style: .relative)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Deny") { model.resolve(request.id, allowed: false) }
                        Button("Approve with Touch ID…") { Task { await model.confirm(request) } }
                    }
                }
            }
            if model.clients.isEmpty {
                Card { EmptyState(symbol: "cable.connector", title: "No connected agents", message: "Connect an agent to let it read your Mac’s health and process history.") }
            }
            ForEach(model.clients) { client in
                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.name).font(.headline)
                            Text(client.revoked ? "Revoked" : (client.scope == "read" ? "Read access" : "Read and request actions"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Created \(client.created.formatted(date: .abbreviated, time: .omitted)) · Last used \(Relative.string(client.lastUsed))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !client.revoked { Button("Revoke…", role: .destructive) { revoke = client } }
                    }
                    DisclosureGroup("\(client.callCount) calls · Recent activity") {
                        let calls = model.calls.filter { $0.clientID == client.id }
                        if calls.isEmpty { Text("No calls in the last 30 days.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(calls) { call in
                            HStack {
                                Text(call.date.formatted(date: .abbreviated, time: .shortened))
                                Text(call.tool).lineLimit(1)
                                Spacer()
                                Text(call.allowed ? "Allowed" : "Denied")
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task { await model.refresh() }
        .onChange(of: model.approvals.count) { _, _ in Task { await model.refresh() } }
        .sheet(isPresented: $pairing) { PairConnectionSheet(model: model) }
        .confirmationDialog("Revoke this connection?", isPresented: Binding(get: { revoke != nil }, set: { if !$0 { revoke = nil } })) {
            if let client = revoke { Button("Revoke \(client.name)", role: .destructive) { Task { await model.revoke(client) }; revoke = nil } }
        } message: { Text("Its token will stop working immediately, including on open connections.") }
    }
}

private struct PairConnectionSheet: View {
    @Bindable var model: ConnectionsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scope = "read"
    @State private var token: String?
    @State private var format = "Claude Code"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(token == nil ? "Connect an agent" : "Save this connection token").font(.title2.weight(.semibold))
            if let token {
                Text("Shown once. Save it in your agent’s configuration; Pollymetric keeps only its hash.").foregroundStyle(.secondary)
                Text(token).font(.callout.monospaced()).textSelection(.enabled)
                Picker("Configuration", selection: $format) {
                    ForEach(["Claude Code", "Codex", "Generic JSON"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented)
                ScrollView { Text(configuration(token)).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 150)
                HStack {
                    Button("Copy configuration") {
                        // This Mac only: never synced to other devices by Universal Clipboard,
                        // and marked so clipboard managers don't keep it.
                        let board = NSPasteboard.general
                        board.prepareForNewContents(with: .currentHostOnly)
                        board.setString(configuration(token), forType: .string)
                        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
                            board.setString("", forType: NSPasteboard.PasteboardType(marker))
                        }
                    }
                    Spacer()
                    Button("Done") { self.token = nil; dismiss() }
                }
            } else {
                TextField("Agent name", text: $name)
                Picker("Access", selection: $scope) {
                    Text("Read only").tag("read")
                    Text("Read and request actions").tag("read+act")
                }
                Text("macOS will confirm your identity. Every action needs a separate approval.").font(.callout).foregroundStyle(.secondary)
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") { dismiss() }.disabled(model.authenticating)
                    Spacer()
                    Button(model.authenticating ? "Confirming…" : "Connect with Touch ID…") {
                        Task { token = await model.pair(name: name.trimmingCharacters(in: .whitespacesAndNewlines), scope: scope) }
                    }.disabled(model.authenticating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100)
                }
            }
        }.padding(24).frame(width: 540)
        .interactiveDismissDisabled(model.authenticating)
        .onDisappear { token = nil }
    }

    private func configuration(_ token: String) -> String {
        let binary = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        switch format {
        case "Claude Code":
            return "claude mcp add pollymetric --env \(Assistant.shellQuote("POLLYMETRIC_MCP_TOKEN=" + token)) -- \(Assistant.shellQuote(binary)) --mcp"
        case "Codex":
            func quoted(_ text: String) -> String { String(decoding: try! JSONEncoder().encode(text), as: UTF8.self) }
            return "[mcp_servers.pollymetric]\ncommand = \(quoted(binary))\nargs = [\"--mcp\"]\n\n[mcp_servers.pollymetric.env]\nPOLLYMETRIC_MCP_TOKEN = \(quoted(token))"
        default:
            let config: [String: Any] = ["mcpServers": ["pollymetric": ["command": binary, "args": ["--mcp"], "env": ["POLLYMETRIC_MCP_TOKEN": token]]]]
            return String(decoding: (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
        }
    }
}
