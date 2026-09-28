import AppKit
import Foundation
import LocalAuthentication
import Observation

struct MCPApproval: Identifiable {
    var id = UUID()
    var client: MCPClientRecord
    var tool: MCPTool
    var arguments: String
    var effect: String
    var expires: Date
}

@MainActor @Observable
final class ConnectionsModel {
    var clients: [MCPClientRecord] = []
    var calls: [MCPCallRecord] = []
    var approvals: [MCPApproval] = []
    var error: String?
    var authenticating = false
    @ObservationIgnored let history: HistoryStore
    @ObservationIgnored private var pending: [UUID: CheckedContinuation<Bool, Never>] = [:]
    @ObservationIgnored private var authentication: [UUID: LAContext] = [:]

    init(history: HistoryStore = .shared) { self.history = history }

    func refresh() async {
        clients = await history.mcpClients(); calls = await history.mcpCalls()
    }

    func pair(name: String, scope: String) async -> String? {
        guard !authenticating else { return nil }
        authenticating = true; defer { authenticating = false }
        let context = LAContext()
        guard await authenticate(context, reason: "Connect \(name) to Pollymetric with \(scope) access") else {
            error = "Connection was not approved."; return nil
        }
        let token = MCPToken.generate()
        guard await history.pairClient(name: name, scope: scope, token: token) != nil else {
            error = "Could not save the connection."; return nil
        }
        await refresh()
        return token
    }

    func revoke(_ client: MCPClientRecord) async {
        await history.revokeClient(client.id)
        for request in approvals.filter({ $0.client.id == client.id }) { resolve(request.id, allowed: false) }
        await refresh()
    }

    func request(_ client: MCPClientRecord, tool: MCPTool, args: [String: Any], effect: String, timeout: TimeInterval = 60) async -> Bool {
        // One open request per agent, eight in all: an agent can't bury you in prompts.
        guard approvals.count < 8, !approvals.contains(where: { $0.client.id == client.id }) else { return false }
        let request = MCPApproval(client: client, tool: tool,
            arguments: String(decoding: (try? MCPJSON.encode(args)) ?? Data(), as: UTF8.self),
            effect: effect, expires: Date().addingTimeInterval(timeout))
        return await withCheckedContinuation { continuation in
            pending[request.id] = continuation; approvals.append(request)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.resolve(request.id, allowed: false)
            }
        }
    }

    func confirm(_ request: MCPApproval) async {
        guard pending[request.id] != nil, authentication[request.id] == nil else { return }
        let context = LAContext(); authentication[request.id] = context
        let accepted = await authenticate(context, reason: "Approve \(request.tool.name) for \(request.client.name)")
        resolve(request.id, allowed: accepted && Date() < request.expires)
    }

    func resolve(_ id: UUID, allowed: Bool) {
        authentication.removeValue(forKey: id)?.invalidate()
        approvals.removeAll { $0.id == id }
        pending.removeValue(forKey: id)?.resume(returning: allowed)
    }

    func close() { for id in Array(pending.keys) { resolve(id, allowed: false) } }

    private func authenticate(_ context: LAContext, reason: String) async -> Bool {
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }
}
