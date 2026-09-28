import XCTest
@testable import Pollymetric

@MainActor
final class MCPTests: XCTestCase {
    private func database() throws -> (URL, HistoryStore) {
        let root = URL(fileURLWithPath: "/tmp/pm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, HistoryStore(url: root.appendingPathComponent("history.sqlite")))
    }

    private func request(_ server: MCPServer, _ hash: String, _ session: MCPSession,
                         _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try MCPJSON.encode(["jsonrpc": "2.0", "id": 7, "method": method, "params": params])
        let result = await server.handle(hash: hash, data: data, session: session)
        return try JSONSerialization.jsonObject(with: XCTUnwrap(result)) as! [String: Any]
    }

    private func ready(_ server: MCPServer, _ hash: String) async throws -> MCPSession {
        let session = MCPSession()
        let reply = try await request(server, hash, session, "initialize", ["protocolVersion": "2025-06-18"])
        XCTAssertEqual((reply["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-06-18")
        _ = await server.handle(hash: hash, data: try MCPJSON.encode(["jsonrpc": "2.0", "method": "notifications/initialized"]), session: session)
        return session
    }

    func testTokenHashPairingRevocationAndRetention() async throws {
        let (root, db) = try database(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(MCPToken.hash("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let token = MCPToken.generate(), hash = MCPToken.hash(token)
        XCTAssertNotEqual(token, MCPToken.generate())
        let paired = await db.pairClient(name: "Test", scope: "read", token: token)
        let client = try XCTUnwrap(paired)
        let found = await db.mcpClient(hash: hash)
        XCTAssertEqual(found?.id, client.id)
        let unknown = await db.mcpClient(hash: MCPToken.hash("unknown"))
        XCTAssertNil(unknown)
        await db.recordMCPCall(clientID: client.id, tool: "health", allowed: true, at: Date().addingTimeInterval(-31 * 86_400))
        await db.recordMCPCall(clientID: client.id, tool: "health", allowed: false)
        let calls = await db.mcpCalls(), clients = await db.mcpClients()
        XCTAssertEqual(calls.count, 1); XCTAssertFalse(calls[0].allowed)
        XCTAssertEqual(clients[0].callCount, 2)
        await db.revokeClient(client.id)
        let revoked = await db.mcpClient(hash: hash)
        XCTAssertNil(revoked)
        // Only the digest is ever persisted, including the WAL.
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data(token.utf8)))
        }
    }

    func testScopesApprovalAndLiveRevocation() async throws {
        let (root, db) = try database(); defer { try? FileManager.default.removeItem(at: root) }
        let readToken = MCPToken.generate(), actToken = MCPToken.generate()
        _ = await db.pairClient(name: "Reader", scope: "read", token: readToken)
        let actor = await db.pairClient(name: "Actor", scope: "read+act", token: actToken)
        var executions = 0, approvals = 0
        let server = MCPServer(history: db, approve: { _, _, _ in approvals += 1; return false }, execute: { _, _ in executions += 1; return ["ok": true] })
        let readHash = MCPToken.hash(readToken), actHash = MCPToken.hash(actToken)
        let reader = try await ready(server, readHash), writer = try await ready(server, actHash)
        let list = try await request(server, readHash, reader, "tools/list")
        let tools = (list["result"] as! [String: Any])["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.count, 10)
        let denied = try await request(server, readHash, reader, "tools/call", ["name": "clean_caches"])
        XCTAssertEqual((denied["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(approvals, 0); XCTAssertEqual(executions, 0)
        _ = try await request(server, actHash, writer, "tools/call", ["name": "clean_caches"])
        XCTAssertEqual(approvals, 1); XCTAssertEqual(executions, 0)
        server.approve = { _, _, _ in true }
        _ = try await request(server, actHash, writer, "tools/call", ["name": "clean_caches"])
        XCTAssertEqual(executions, 1)
        server.approve = { client, _, _ in await db.revokeClient(client.id); return true }
        _ = try await request(server, actHash, writer, "tools/call", ["name": "clean_caches"])
        XCTAssertEqual(executions, 1)
        let revoked = try await request(server, actHash, writer, "tools/list")
        XCTAssertNotNil(revoked["error"])
        XCTAssertNotNil(actor)
    }

    func testApprovalTimeoutAndCloseDeny() async throws {
        let (root, db) = try database(); defer { try? FileManager.default.removeItem(at: root) }
        let paired = await db.pairClient(name: "Actor", scope: "read+act", token: MCPToken.generate())
        let client = try XCTUnwrap(paired), model = ConnectionsModel(history: db)
        let tool = try XCTUnwrap(MCPTool.all.first { $0.action })
        let timeout = await model.request(client, tool: tool, args: [:], effect: "Test only", timeout: 0.01)
        XCTAssertFalse(timeout); XCTAssertTrue(model.approvals.isEmpty)
        let pending = Task { await model.request(client, tool: tool, args: [:], effect: "Test only") }
        await Task.yield()
        model.close()
        let closed = await pending.value
        XCTAssertFalse(closed)
    }

    func testToolSchemasAndReadOutputShapes() async throws {
        let store = AppStore()
        let identity = ProcessIdentity(key: "fixture-1", pid: 12345, startedAt: .now, name: "stub", label: "stub", context: "fixture", via: nil, app: nil, appPath: nil, executable: nil, command: "stub", cwd: "/tmp/fixture", chain: [])
        HistoryStore.shared.record([ProcessRecord(identity: identity, cpu: 30, memory: 100)], duration: 10)
        for tool in MCPTool.all {
            XCTAssertNoThrow(try MCPJSON.encode(tool.schema))
            XCTAssertFalse(tool.validate(["unexpected": true]))
            if tool.action { continue }
            let output = try await store.mcpOutput(tool.name, args: ["group_key": identity.groupKey])
            XCTAssertNoThrow(try MCPJSON.encode(output))
            let keys: [String: Set<String>] = [
                "health": ["score", "band", "issues", "measured_at"], "attention": ["items"], "top_processes": ["processes"],
                "process_history": ["group_key", "since", "usage", "runs", "timeline"], "process_brief": ["markdown"],
                "agents": ["agents", "updated_at"], "cache_preview": ["data", "updated_at", "stale"],
                "build_preview": ["data", "updated_at", "stale"], "launch_items": ["data", "updated_at", "stale", "flagged_paths"],
                "security_audit": ["data", "updated_at", "stale"]
            ]
            XCTAssertEqual(Set((output as? [String: Any] ?? [:]).keys), keys[tool.name])
        }
    }

    func testUnixSocketRelayAndRevocation() async throws {
        let (root, db) = try database(); defer { try? FileManager.default.removeItem(at: root) }
        let token = MCPToken.generate()
        let paired = await db.pairClient(name: "Relay", scope: "read", token: token)
        let client = try XCTUnwrap(paired)
        let server = MCPServer(history: db, execute: { _, _ in ["score": 100] })
        let socket = MCPSocketServer(directory: root)
        try socket.start(authenticate: { await db.mcpClient(hash: $0) != nil }, handle: { await server.handle(hash: $0, data: $1, session: $2) })
        defer { socket.stop() }
        let path = root.appendingPathComponent("mcp.sock").path
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let fd = try MCPWire.connect(path: path)
        defer { Darwin.close(fd) }
        let wire = MCPWire(fd)
        let auth = try await Task.detached { () throws -> Data? in
            try wire.write(MCPJSON.encode(["token": token])); return try wire.readLine()
        }.value
        XCTAssertEqual((try JSONSerialization.jsonObject(with: XCTUnwrap(auth)) as? [String: Bool])?["authenticated"], true)
        let initReply = try await Task.detached { () throws -> Data? in
            try wire.write(MCPJSON.encode(["jsonrpc": "2.0", "id": "init", "method": "initialize", "params": ["protocolVersion": "2025-06-18"]]))
            return try wire.readLine()
        }.value
        XCTAssertEqual((try JSONSerialization.jsonObject(with: XCTUnwrap(initReply)) as? [String: Any])?["id"] as? String, "init")
        // Exercise the actual --mcp executable without launching AppKit or any agent.
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/Pollymetric")
        let relay = try await Task.detached { () throws -> (Int32, String) in
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = binary; process.arguments = ["--mcp"]
            process.environment = ["POLLYMETRIC_DATA_DIR": root.path, "POLLYMETRIC_MCP_TOKEN": token, "PATH": "/usr/bin:/bin"]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: deadline)
            let frames: [[String: Any]] = [
                ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
                ["jsonrpc": "2.0", "method": "notifications/initialized"],
                ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "health"]]
            ]
            for frame in frames { try MCPWire(input.fileHandleForWriting.fileDescriptor).write(MCPJSON.encode(frame)) }
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); deadline.cancel()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }.value
        XCTAssertEqual(relay.0, 0)
        let replies = try relay.1.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual((replies.last?["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertFalse(relay.1.contains(token))
        await db.revokeClient(client.id)
        let denied = try await Task.detached { () throws -> Data? in
            try wire.write(MCPJSON.encode(["jsonrpc": "2.0", "id": 2, "method": "ping"]))
            return try wire.readLine()
        }.value
        XCTAssertNotNil((try JSONSerialization.jsonObject(with: XCTUnwrap(denied)) as? [String: Any])?["error"])
    }
}
