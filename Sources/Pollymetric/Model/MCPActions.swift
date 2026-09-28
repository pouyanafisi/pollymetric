import AppKit
import Foundation

extension AppStore {
    func startMCP() {
        guard !DataDirectory.isSnapshot else { return }
        let service = MCPServer(history: .shared, approve: { [weak self] client, tool, args in
            guard let self else { return false }
            let effect: String
            switch tool.name {
            case "quit_process":
                guard let row = self.mcpProcess(args) else { return false }
                effect = "Quit \(row.title) (PID \(row.pid)). Unsaved work may be lost."
            case "clean_caches":
                effect = "Clear caches to free about \(self.clean.value.map { Bytes.format($0.totalBytes) } ?? "an unknown amount of space"). Apps quietly recreate what they need; anything you've protected is kept."
            default:
                effect = "Remove old projects' dependencies and build output to free about \(self.purge.value.map { Bytes.format($0.totalBytes) } ?? "an unknown amount of space"). They come back the next time you work on those projects."
            }
            // Come forward for the first request only, not once per request.
            if self.connections.approvals.isEmpty {
                self.dashboardSection = .connections
                self.showConnections?()
            }
            return await self.connections.request(client, tool: tool, args: args, effect: effect)
        }, execute: { [weak self] name, args in
            guard let self else { throw MCPFailure(message: "Pollymetric is closing.") }
            return try await self.mcpOutput(name, args: args)
        })
        service.didCall = { [weak self] name in
            guard let self else { return }
            self.patterns.record(.mcpCall, target: name)
            Task { await self.connections.refresh() }
        }
        let socket = MCPSocketServer(directory: Lynis.dataDirectory)
        do {
            try socket.start(authenticate: { hash in await HistoryStore.shared.mcpClient(hash: hash) != nil },
                             handle: { hash, data, session in await service.handle(hash: hash, data: data, session: session) })
            mcpServer = service; mcpSocket = socket
        } catch { connections.error = error.localizedDescription }
    }

    func mcpProcess(_ args: [String: Any]) -> ProcessRow? {
        guard let pid = args["pid"] as? Int32, pid != getpid(),
              let group = args["group_key"] as? String, let key = args["process_key"] as? String,
              let row = monitor.processes.first(where: { $0.pid == pid && $0.identity?.groupKey == group && $0.identity?.key == key }) else { return nil }
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0, key == "\(pid)-\(info.ri_proc_start_abstime)" else { return nil }
        return row
    }

    func mcpOutput(_ name: String, args: [String: Any]) async throws -> Any {
        func cached<T: Codable & Sendable>(_ query: Query<T>) throws -> [String: Any] {
            ["data": try MCPJSON.object(query.value), "updated_at": try MCPJSON.object(query.updatedAt), "stale": query.isStale]
        }
        switch name {
        case "health":
            return ["score": monitor.health?.score as Any? ?? NSNull(), "band": monitor.health?.band.title as Any? ?? NSNull(),
                    "issues": monitor.health?.issues ?? [], "measured_at": try MCPJSON.object(monitor.snapshot?.date)]
        case "attention":
            return ["items": attention.map { ["id": $0.id, "severity": $0.severity == .critical ? "critical" : ($0.severity == .warning ? "warning" : "suggestion"), "title": $0.title, "detail": $0.detail] }]
        case "top_processes":
            return ["processes": try monitor.processes.map { row -> [String: Any] in
                ["pid": row.pid, "group_key": row.identity?.groupKey as Any? ?? NSNull(), "process_key": row.identity?.key as Any? ?? NSNull(),
                 "title": row.title, "cpu_percent": row.cpu, "memory_bytes": row.memoryBytes, "attribution": try MCPJSON.object(row.identity)]
            }]
        case "process_history", "process_brief":
            let key = args["group_key"] as? String ?? ""
            let since = Date().addingTimeInterval(-86_400)
            let groups = await HistoryStore.shared.usage(since: since, limit: 10_000)
            let usage = groups.first { $0.groupKey == key }
            let runs = await HistoryStore.shared.instances(of: key, since: since)
            let timeline = await HistoryStore.shared.timeline(of: key, since: since, bucket: 900)
            if name == "process_brief" {
                let live = monitor.processes.filter { $0.identity?.groupKey == key }
                guard usage != nil || !live.isEmpty else { throw MCPFailure(message: "No process history or live process matches this group.") }
                return ["markdown": Assistant.markdown(.explain, context: .init(title: usage?.label ?? live.first!.title,
                    subtitle: usage?.subtitle ?? live.first?.subtitle ?? "", explanation: nil, usage: usage, runs: runs, focus: nil,
                    live: live, timeline: timeline, snapshot: monitor.snapshot, health: monitor.health))]
            }
            return ["group_key": key, "since": try MCPJSON.object(since), "usage": try MCPJSON.object(usage),
                    "runs": try MCPJSON.object(runs), "timeline": try MCPJSON.object(timeline)]
        case "agents":
            return ["agents": (harnesses.value ?? []).map { h -> [String: Any] in
                ["id": h.id, "name": h.descriptor.name, "installed": h.isInstalled,
                 "accounts": h.accounts.map { a -> [String: Any] in
                    ["label": a.label, "status": a.status.rawValue,
                     "usage": (try? MCPJSON.object(planUsage["\(h.id)|\(a.id)"])) ?? NSNull()]
                 }]
            }, "updated_at": try MCPJSON.object(harnesses.updatedAt)]
        case "cache_preview": return try cached(clean)
        case "build_preview": return try cached(purge)
        case "launch_items":
            var output = try cached(launchItems); output["flagged_paths"] = launchItems.value?.flaggedPaths ?? []; return output
        case "security_audit": return try cached(lynis)
        case "quit_process":
            guard let row = mcpProcess(args) else { throw MCPFailure(message: "The process ended or changed. Refresh the process list before requesting again.") }
            patterns.record(.processQuit, target: row.identity?.groupKey, context: row.identity?.cwd)
            ProcessList.quit(row)
            return ["status": "quit_requested", "pid": row.pid]
        case "clean_caches", "purge_build_folders":
            guard job?.isRunning != true else { throw MCPFailure(message: "A cleanup job is already running.") }
            if name == "clean_caches" { runClean() } else { runPurge() }
            return ["status": "started", "tool": name, "details": "Follow progress in Pollymetric."]
        default: throw MCPFailure(message: "Unknown tool.")
        }
    }
}
