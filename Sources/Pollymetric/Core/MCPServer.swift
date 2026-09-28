import Foundation
import CoreFoundation

/// Protocol state belongs to one socket, and is accessed only by MCPServer's main actor.
final class MCPSession: @unchecked Sendable {
    var initialized = false
    var ready = false
}

struct MCPTool {
    var name: String
    var description: String
    var action = false
    var properties: [String: Any] = [:]
    var required: [String] = []

    var schema: [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": !action, "destructiveHint": action, "openWorldHint": false]]
    }

    func validate(_ args: [String: Any]) -> Bool {
        guard Set(args.keys).isSubset(of: Set(properties.keys)), required.allSatisfy({ args[$0] != nil }) else { return false }
        for (key, value) in args {
            guard let property = properties[key] as? [String: Any] else { return false }
            switch property["type"] as? String {
            case "string":
                guard let string = value as? String, !string.isEmpty, string.utf8.count <= 4096 else { return false }
            case "integer":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.doubleValue.rounded() == number.doubleValue, number.doubleValue > 1,
                      number.doubleValue <= Double(Int32.max) else { return false }
            default: return false
            }
        }
        return true
    }

    static let group: [String: Any] = ["group_key": ["type": "string", "description": "Exact group_key returned by top_processes or process_history."]]
    static let all: [MCPTool] = [
        .init(name: "health", description: "Current health score, band and issues; null until measured."),
        .init(name: "attention", description: "Ranked attention items with plain-English explanations."),
        .init(name: "top_processes", description: "Current top processes with PID, group_key, attribution, CPU percent of one core and memory bytes."),
        .init(name: "process_history", description: "Usage, recent runs and 15-minute CPU timeline for one group over the last 24 hours.", properties: group, required: ["group_key"]),
        .init(name: "process_brief", description: "Read-only investigation brief Markdown for one process group.", properties: group, required: ["group_key"]),
        .init(name: "agents", description: "Last detected agent accounts and cached plan usage. Does not sign in or spend model quota."),
        .init(name: "cache_preview", description: "Last cache cleanup preview, with measurement time; null if not measured."),
        .init(name: "build_preview", description: "Last build-folder purge preview, with measurement time; null if not measured."),
        .init(name: "launch_items", description: "Last launch-item scan and flagged paths; null if not scanned."),
        .init(name: "security_audit", description: "Latest loaded Lynis report summary; does not run an audit."),
        .init(name: "quit_process", description: "Request quitting this currently observed PID and group. Requires read+act and in-app approval with Touch ID. Unsaved work may be lost.", action: true,
              properties: group.merging(["process_key": ["type": "string", "description": "Exact process_key returned by top_processes, protecting against PID reuse."], "pid": ["type": "integer", "minimum": 2, "maximum": Int32.max, "description": "PID returned by top_processes."]]) { a, _ in a }, required: ["group_key", "pid", "process_key"]),
        .init(name: "clean_caches", description: "Request Mole cache cleanup according to its current rules and protections. Requires read+act and in-app approval with Touch ID; returns when the job starts.", action: true),
        .init(name: "purge_build_folders", description: "Request Mole purge of eligible build folders. Requires read+act and in-app approval with Touch ID; returns when the job starts.", action: true),
    ]
}

@MainActor
final class MCPServer {
    typealias Approval = (MCPClientRecord, MCPTool, [String: Any]) async -> Bool
    typealias Execute = (String, [String: Any]) async throws -> Any
    let history: HistoryStore
    var approve: Approval
    var execute: Execute
    var didCall: ((String) -> Void)?

    init(history: HistoryStore, approve: @escaping Approval = { _, _, _ in false }, execute: @escaping Execute) {
        self.history = history; self.approve = approve; self.execute = execute
    }

    func handle(hash: String, data: Data, session: MCPSession) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data), let message = object as? [String: Any],
              message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return try? MCPJSON.encode(MCPJSON.error(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request."))
        }
        let id = message["id"]
        func error(_ text: String, code: Int = -32000) -> Data? {
            guard let id else { return nil }
            return try? MCPJSON.encode(MCPJSON.error(id: id, code: code, message: text))
        }
        guard let client = await history.mcpClient(hash: hash) else { return error("Connection revoked or token unknown.") }
        if method == "notifications/initialized" { if session.initialized { session.ready = true }; return nil }
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        var result: [String: Any]
        switch method {
        case "initialize":
            guard !session.initialized else { return error("Already initialized.") }
            session.initialized = true
            let requested = params["protocolVersion"] as? String ?? ""
            let version = ["2024-11-05", "2025-03-26", "2025-06-18"].contains(requested) ? requested : "2025-06-18"
            result = ["protocolVersion": version, "capabilities": ["tools": [:]], "serverInfo": ["name": "pollymetric", "version": "1.0"]]
        case "ping": result = [:]
        case "tools/list":
            guard session.ready else { return error("Initialize the connection first.") }
            result = ["tools": MCPTool.all.filter { !$0.action || client.scope == "read+act" }.map(\.schema)]
        case "tools/call":
            guard session.ready else { return error("Initialize the connection first.") }
            guard let name = params["name"] as? String, let tool = MCPTool.all.first(where: { $0.name == name }) else {
                return error("Unknown tool.", code: -32602)
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            var allowed = false
            do {
                guard params["arguments"] == nil || params["arguments"] is [String: Any], tool.validate(args) else {
                    throw MCPFailure(message: "Arguments do not match this tool's schema.")
                }
                if tool.action {
                    guard client.scope == "read+act" else { throw MCPFailure(message: "This connection has read access only.") }
                    guard await approve(client, tool, args) else { throw MCPFailure(message: "The action was denied, cancelled or timed out.") }
                    guard let current = await history.mcpClient(hash: hash), current.scope == "read+act" else {
                        throw MCPFailure(message: "Connection revoked before the action was approved.")
                    }
                }
                let output = try await execute(name, args)
                if !tool.action, await history.mcpClient(hash: hash) == nil { throw MCPFailure(message: "Connection revoked.") }
                let text = String(decoding: try MCPJSON.encode(output), as: UTF8.self)
                allowed = true
                result = ["content": [["type": "text", "text": text]], "isError": false]
            } catch {
                // Only our bounded errors are presented; underlying tools may include sensitive output.
                let reason = (error as? MCPFailure)?.message ?? "The tool could not complete. Check Pollymetric."
                result = ["content": [["type": "text", "text": reason]], "isError": true]
            }
            await history.recordMCPCall(clientID: client.id, tool: name, allowed: allowed)
            didCall?(name)
        default: return error("Method not found.", code: -32601)
        }
        return try? MCPJSON.encode(["jsonrpc": "2.0", "id": id, "result": result])
    }
}
