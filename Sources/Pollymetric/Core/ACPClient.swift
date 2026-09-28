import Foundation
import HarnessKit

struct ACPFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One adapter, one session. All protocol state is serialized on the main actor.
@MainActor
final class ACPClient {
    var onUpdate: (([String: Any]) -> Void)?
    var onPermission: ((String, [String: Any]) -> Void)?
    var onExit: (() -> Void)?
    private(set) var sessionID: String?
    /// The read-only mode the session runs in. Sessions only start in one: an adapter
    /// that advertises no modes may act without asking, so it goes to iTerm instead.
    private(set) var mode = "Default"
    private(set) var process: ChildProcess?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var permissions: [String: (id: Any, options: Set<String>)] = [:]
    private var closed = false
    private var cancelling = false

    func start(argv: [String], environment: [String: String], cwd: String, claude: Bool, explain: Bool) async throws {
        guard !closed else { throw ACPFailure(message: "This conversation is closed.") }
        guard let executable = HarnessProcess.executable(argv, path: environment["PATH"] ?? "") else {
            throw ACPFailure(message: "The agent adapter isn't installed. Continue in iTerm or install its ACP adapter.")
        }
        // Disclaimed: the agent reads files with its own access, never Pollymetric's Full Disk Access.
        let stdin = Pipe(), stdout = Pipe()
        let child = ChildProcess(executable: executable, arguments: Array(argv.dropFirst()), environment: environment, disclaim: true)
        child.currentDirectory = cwd
        child.standardInput = stdin; child.standardOutput = stdout
        process = child; input = stdin.fileHandleForWriting
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try child.run()
        RunningProcesses.shared.add(child)
        // Blocking pipe reads stay off the UI thread. Awaiting delivery preserves wire order.
        Task.detached { [weak self] in
            var buffer = Data()
            do {
                var bytes = [UInt8](repeating: 0, count: 16_384)
                while true {
                    let count = Darwin.read(stdout.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
                    if count <= 0 { break }
                    buffer.append(contentsOf: bytes.prefix(count))
                    guard buffer.count <= 4 * 1_024 * 1_024 else { break }
                    while let end = buffer.firstIndex(of: 10) {
                        let line = Data(buffer[..<end])
                        buffer.removeSubrange(...end)
                        await self?.receive(line)
                    }
                }
            }
            await self?.disconnected()
        }
        let initialized = try await request("initialize", ["protocolVersion": 1, "clientCapabilities": [:],
                                                           "clientInfo": ["name": "pollymetric", "version": "1.0"]])
        guard initialized["protocolVersion"] as? Int == 1 else { close(); throw ACPFailure(message: "Unsupported agent protocol version.") }
        var params: [String: Any] = ["cwd": cwd, "mcpServers": []]
        // Only the user's own settings: the inspected project's .claude/ settings could
        // pre-approve tools or run hooks, and nobody vetted that project.
        if claude { params["_meta"] = ["claudeCode": ["options": ["strictMcpConfig": true, "settingSources": ["user"],
                                                                  "env": ["ENABLE_CLAUDEAI_MCP_SERVERS": "false"]]]] }
        let session = try await request("session/new", params)
        guard let id = session["sessionId"] as? String else { close(); throw ACPFailure(message: "The agent didn't create a session.") }
        sessionID = id
        // Read-only mode names differ per adapter: Claude Code offers "plan", Codex calls
        // its approval-required preset "read-only" (its default, "agent", approves on your
        // behalf). No read-only mode, or no modes at all, means no in-app session.
        let available = (session["modes"] as? [String: Any])?["availableModes"] as? [[String: Any]] ?? []
        let ids = available.compactMap { $0["id"] as? String }
        let desired = (explain ? ["ask", "plan", "read-only"] : ["plan", "ask", "read-only"]).first { ids.contains($0) }
        guard let desired else { close(); throw ACPFailure(message: "This agent can't be kept read-only here. Continue in iTerm.") }
        _ = try await request("session/set_mode", ["sessionId": id, "modeId": desired])
        mode = desired.capitalized
    }

    func prompt(_ text: String) async throws {
        guard let sessionID, !closed else { throw ACPFailure(message: "The agent is disconnected.") }
        cancelling = false
        _ = try await request("session/prompt", ["sessionId": sessionID, "prompt": [["type": "text", "text": text]]], timeout: 1_800)
        for key in Array(permissions.keys) { answer(key, option: nil) }
    }

    func answer(_ key: String, option: String?) {
        guard let request = permissions[key] else { return }
        if let option, !request.options.contains(option) { return }
        permissions[key] = nil
        let outcome = option.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
        try? send(["jsonrpc": "2.0", "id": request.id, "result": ["outcome": outcome]])
    }

    func cancel() {
        cancelling = true
        for key in Array(permissions.keys) { answer(key, option: nil) }
        if let sessionID { try? send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionID]]) }
    }

    func close() {
        guard !closed else { return }
        cancel(); closed = true
        failPending()
        try? input?.close(); input = nil
        guard let child = process else { return }
        // Give cancellation a brief chance to flush; then reap even an uncooperative adapter.
        Task {
            try? await Task.sleep(for: .milliseconds(200))
            if child.isRunning { child.terminate() }
            try? await Task.sleep(for: .milliseconds(500))
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
            RunningProcesses.shared.remove(child)
        }
    }

    private func disconnected() {
        failPending()
        close()
        onExit?()
    }

    private func failPending() {
        let callbacks = pending.values; pending.removeAll()
        for callback in callbacks { callback.resume(throwing: ACPFailure(message: "The agent disconnected or was stopped.")) }
    }

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 30) async throws -> [String: Any] {
        guard !closed else { throw ACPFailure(message: "The agent is closed.") }
        nextID += 1; let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                if let callback = self?.pending.removeValue(forKey: id) {
                    callback.resume(throwing: ACPFailure(message: "The agent took too long to respond."))
                    self?.close()
                }
            }
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let input else { throw ACPFailure(message: "The agent is disconnected.") }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        guard !closed else { return }
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
            close(); return
        }
        if let method = message["method"] as? String {
            let params = message["params"] as? [String: Any] ?? [:]
            if method == "session/update", params["sessionId"] as? String == sessionID,
               let update = params["update"] as? [String: Any] { onUpdate?(update) }
            if let id = message["id"] {
                if method == "session/request_permission" {
                    let key = UUID().uuidString
                    let options = (params["options"] as? [[String: Any]] ?? []).compactMap { $0["optionId"] as? String }
                    permissions[key] = (id, Set(options))
                    if cancelling || params["sessionId"] as? String != sessionID { answer(key, option: nil) }
                    else { onPermission?(key, params) }
                } else {
                    try? send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Client capability not available"]])
                }
            }
        } else if let id = message["id"] as? Int, let callback = pending.removeValue(forKey: id) {
            if message["error"] != nil {
                // Adapter errors may contain environment values. Keep the UI diagnostic bounded and local.
                callback.resume(throwing: ACPFailure(message: "The agent rejected the request. Check its sign-in state or continue in iTerm."))
            } else { callback.resume(returning: message["result"] as? [String: Any] ?? [:]) }
        }
    }
}
