import Foundation
import SQLite3

/// Aggregated usage for one group (the same thing across restarts) over a time window.
struct UsageGroup: Identifiable, Equatable, Codable, Sendable {
    var id: String { groupKey }
    var groupKey: String
    var label: String
    var context: String?
    var via: String?
    var app: String?
    var appPath: String?
    var cpuSeconds: Double
    var peakCPU: Double
    var peakMemory: Int64
    var instances: Int
    var firstSeen: Date
    var lastSeen: Date
    /// 15-minute windows in which it went above 50% CPU: "how many times did it flare up".
    var spikes: Int

    var subtitle: String {
        let owner = [via, app].compactMap { $0 }.joined(separator: " › ")
        return [context, owner.isEmpty ? nil : owner].compactMap { $0 }.joined(separator: " · ")
    }
}

struct UsageInstance: Identifiable, Equatable, Codable, Sendable {
    var id: String { key }
    var key: String
    var pid: Int32
    var startedAt: Date
    var command: String
    var cwd: String?
    var executable: String?
    var chain: [String]
    var cpuSeconds: Double
    var peakCPU: Double
    var lastSeen: Date
}

struct TimePoint: Identifiable, Equatable, Codable, Sendable {
    var id: Date { date }
    var date: Date
    var value: Double
}

/// Local diagnostics history in SQLite, using the system's libsqlite3 (no dependency).
///
/// It keeps only what helps diagnose: processes above 20% CPU (sampled every 10 s) or
/// holding more than 2 GB (every minute), plus one system sample per minute. After 14
/// days rows are pruned. A busy day is a few hundred KB.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()
    static let retention: TimeInterval = 14 * 86_400

    private let queue = DispatchQueue(label: "pollymetric.history", qos: .utility)
    private var db: OpaquePointer?
    private var rowIDs: [String: Int64] = [:]
    private var lastPrune = Date.distantPast

    let url: URL

    init(url: URL = Lynis.dataDirectory.appendingPathComponent("history.sqlite")) {
        self.url = url
        queue.sync { open() }
    }

    deinit { if let db { sqlite3_close(db) } }

    private func open() {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            NSLog("Pollymetric: couldn't open history database")
            sqlite3_close(db) // a failed open still allocates a handle
            db = nil
            return
        }
        exec("""
            CREATE TABLE IF NOT EXISTS interaction (
                ts REAL NOT NULL, kind TEXT NOT NULL, target TEXT, context TEXT
            );
            CREATE INDEX IF NOT EXISTS interaction_kind_time ON interaction(kind, ts);
            CREATE TABLE IF NOT EXISTS mcp_client (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, scope TEXT NOT NULL,
                token_hash TEXT NOT NULL UNIQUE, created REAL NOT NULL, last_used REAL,
                call_count INTEGER NOT NULL DEFAULT 0, revoked INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS mcp_call (
                id INTEGER PRIMARY KEY, client_id TEXT NOT NULL REFERENCES mcp_client(id),
                ts REAL NOT NULL, tool TEXT NOT NULL, allowed INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS mcp_call_time ON mcp_call(ts);
            CREATE TABLE IF NOT EXISTS agent_session (
                id TEXT PRIMARY KEY, group_key TEXT NOT NULL, harness TEXT NOT NULL, account TEXT NOT NULL,
                ask TEXT NOT NULL, started REAL NOT NULL, ended REAL, status TEXT NOT NULL,
                answer TEXT NOT NULL, transcript TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS agent_group ON agent_session(group_key, started);
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA busy_timeout = 3000;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS process (
                id INTEGER PRIMARY KEY,
                key TEXT NOT NULL UNIQUE,
                group_key TEXT NOT NULL,
                pid INTEGER NOT NULL,
                started_at REAL NOT NULL,
                name TEXT NOT NULL,
                label TEXT NOT NULL,
                context TEXT,
                via TEXT,
                app TEXT,
                app_path TEXT,
                executable TEXT,
                command TEXT NOT NULL,
                cwd TEXT,
                chain TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS process_group ON process(group_key);
            CREATE TABLE IF NOT EXISTS process_sample (
                ts REAL NOT NULL,
                process_id INTEGER NOT NULL REFERENCES process(id) ON DELETE CASCADE,
                cpu REAL NOT NULL,
                memory INTEGER NOT NULL,
                duration REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS process_sample_ts ON process_sample(ts);
            CREATE INDEX IF NOT EXISTS process_sample_process ON process_sample(process_id, ts);
            CREATE TABLE IF NOT EXISTS system_sample (
                ts REAL PRIMARY KEY,
                cpu REAL NOT NULL,
                memory REAL NOT NULL,
                pressure INTEGER NOT NULL,
                disk_free INTEGER NOT NULL,
                score INTEGER NOT NULL
            );
            """)
        pruneInteractions()
        pruneMCPCalls()
    }

    // MARK: Writing

    func record(_ records: [ProcessRecord], duration: TimeInterval, at date: Date = .now) {
        guard !records.isEmpty else { return }
        queue.async { [self] in
            // If another connection holds the lock (a snapshot run, tests), BEGIN or COMMIT
            // can fail. Never leave a transaction open: later writes would pile up uncommitted.
            guard exec("BEGIN IMMEDIATE") else { return }
            let insert = prepare("INSERT INTO process_sample (ts, process_id, cpu, memory, duration) VALUES (?, ?, ?, ?, ?)")
            for record in records {
                guard let id = rowID(for: record.identity) else { continue }
                sqlite3_reset(insert)
                sqlite3_bind_double(insert, 1, date.timeIntervalSince1970)
                sqlite3_bind_int64(insert, 2, id)
                sqlite3_bind_double(insert, 3, record.cpu)
                sqlite3_bind_int64(insert, 4, record.memory)
                sqlite3_bind_double(insert, 5, duration)
                sqlite3_step(insert)
            }
            sqlite3_finalize(insert)
            if !exec("COMMIT") { exec("ROLLBACK") }
            pruneIfDue()
        }
    }

    func recordSystem(_ snapshot: SystemSnapshot, score: Int) {
        queue.async { [self] in
            let statement = prepare("INSERT OR REPLACE INTO system_sample VALUES (?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, snapshot.date.timeIntervalSince1970.rounded())
            sqlite3_bind_double(statement, 2, snapshot.cpuSustained)
            sqlite3_bind_double(statement, 3, snapshot.memoryUsedPercent)
            sqlite3_bind_int(statement, 4, snapshot.memoryPressure == .critical ? 2 : (snapshot.memoryPressure == .warn ? 1 : 0))
            sqlite3_bind_int64(statement, 5, snapshot.diskFreeBytes)
            sqlite3_bind_int(statement, 6, Int32(score))
            sqlite3_step(statement)
        }
    }

    private func rowID(for identity: ProcessIdentity) -> Int64? {
        if let cached = rowIDs[identity.key] { return cached }
        let insert = prepare("""
            INSERT OR IGNORE INTO process
            (key, group_key, pid, started_at, name, label, context, via, app, app_path, executable, command, cwd, chain)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """)
        bind(insert, [
            identity.key, identity.groupKey, Int64(identity.pid), identity.startedAt.timeIntervalSince1970,
            identity.name, identity.label, identity.context, identity.via, identity.app, identity.appPath,
            identity.executable, identity.command, identity.cwd, identity.chain.joined(separator: "\n"),
        ])
        sqlite3_step(insert)
        sqlite3_finalize(insert)

        let select = prepare("SELECT id FROM process WHERE key = ?")
        defer { sqlite3_finalize(select) }
        bind(select, [identity.key])
        guard sqlite3_step(select) == SQLITE_ROW else { return nil }
        let id = sqlite3_column_int64(select, 0)
        if rowIDs.count > 5_000 { rowIDs.removeAll() }
        rowIDs[identity.key] = id
        return id
    }

    private func pruneIfDue() {
        guard Date().timeIntervalSince(lastPrune) > 6 * 3_600 else { return }
        lastPrune = .now
        pruneInteractions()
        pruneMCPCalls()
        let cutoff = Date().addingTimeInterval(-Self.retention).timeIntervalSince1970
        exec("DELETE FROM process_sample WHERE ts < \(cutoff)")
        exec("DELETE FROM system_sample WHERE ts < \(cutoff)")
        exec("DELETE FROM process WHERE id NOT IN (SELECT DISTINCT process_id FROM process_sample)")
        rowIDs.removeAll()
        exec("PRAGMA optimize")
    }

    // MARK: Reading

    func usage(since: Date, limit: Int = 60) async -> [UsageGroup] {
        await read { [self] in
            let statement = prepare("""
                SELECT p.group_key, MAX(p.label), MAX(p.context), MAX(p.via), MAX(p.app), MAX(p.app_path),
                       SUM(s.cpu * s.duration) / 100.0, MAX(s.cpu), MAX(s.memory), COUNT(DISTINCT p.id),
                       MIN(s.ts), MAX(s.ts),
                       COUNT(DISTINCT CASE WHEN s.cpu >= 50 THEN CAST(s.ts / 900 AS INTEGER) END)
                FROM process_sample s JOIN process p ON p.id = s.process_id
                WHERE s.ts >= ?
                GROUP BY p.group_key
                ORDER BY 7 DESC
                LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, [since.timeIntervalSince1970, Int64(limit)])
            var groups: [UsageGroup] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                groups.append(UsageGroup(
                    groupKey: text(statement, 0) ?? "",
                    label: text(statement, 1) ?? "?",
                    context: text(statement, 2),
                    via: text(statement, 3),
                    app: text(statement, 4),
                    appPath: text(statement, 5),
                    cpuSeconds: sqlite3_column_double(statement, 6),
                    peakCPU: sqlite3_column_double(statement, 7),
                    peakMemory: sqlite3_column_int64(statement, 8),
                    instances: Int(sqlite3_column_int(statement, 9)),
                    firstSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
                    lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 11)),
                    spikes: Int(sqlite3_column_int(statement, 12))
                ))
            }
            return groups
        }
    }

    func instances(of groupKey: String, since: Date) async -> [UsageInstance] {
        await read { [self] in
            let statement = prepare("""
                SELECT p.key, p.pid, p.started_at, p.command, p.cwd, p.executable, p.chain,
                       SUM(s.cpu * s.duration) / 100.0, MAX(s.cpu), MAX(s.ts)
                FROM process_sample s JOIN process p ON p.id = s.process_id
                WHERE p.group_key = ? AND s.ts >= ?
                GROUP BY p.id
                ORDER BY 10 DESC
                LIMIT 25
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, [groupKey, since.timeIntervalSince1970])
            var rows: [UsageInstance] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(UsageInstance(
                    key: text(statement, 0) ?? "",
                    pid: sqlite3_column_int(statement, 1),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    command: text(statement, 3) ?? "",
                    cwd: text(statement, 4),
                    executable: text(statement, 5),
                    chain: (text(statement, 6) ?? "").split(separator: "\n").map(String.init),
                    cpuSeconds: sqlite3_column_double(statement, 7),
                    peakCPU: sqlite3_column_double(statement, 8),
                    lastSeen: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
                ))
            }
            return rows
        }
    }

    /// Average CPU % (of one core) for a group, bucketed over time.
    func timeline(of groupKey: String, since: Date, bucket: TimeInterval) async -> [TimePoint] {
        await read { [self] in
            let statement = prepare("""
                SELECT CAST(s.ts / ?1 AS INTEGER) * ?1, SUM(s.cpu * s.duration) / ?1
                FROM process_sample s JOIN process p ON p.id = s.process_id
                WHERE p.group_key = ?2 AND s.ts >= ?3
                GROUP BY 1 ORDER BY 1
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, [bucket, groupKey, since.timeIntervalSince1970])
            return points(statement)
        }
    }

    /// System CPU % (of total capacity), bucketed over time.
    func systemTimeline(since: Date, bucket: TimeInterval) async -> [TimePoint] {
        await read { [self] in
            let statement = prepare("""
                SELECT CAST(ts / ?1 AS INTEGER) * ?1, AVG(cpu)
                FROM system_sample WHERE ts >= ?2
                GROUP BY 1 ORDER BY 1
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, [bucket, since.timeIntervalSince1970])
            return points(statement)
        }
    }

    func saveAgent(_ record: AgentRecord) {
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(record.transcript) else { return }
            let statement = prepare("INSERT OR REPLACE INTO agent_session VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(statement, [record.id, record.groupKey, record.harness, record.account, record.ask,
                             record.started.timeIntervalSince1970, record.ended?.timeIntervalSince1970,
                             record.status, record.answer, String(decoding: data, as: UTF8.self)])
            sqlite3_step(statement)
        }
    }

    func agentSessions(group: String) async -> [AgentRecord] {
        await read { [self] in
            let statement = prepare("SELECT id, harness, account, ask, started, ended, status, answer, transcript FROM agent_session WHERE group_key = ? ORDER BY started DESC LIMIT 20")
            defer { sqlite3_finalize(statement) }
            bind(statement, [group])
            var records: [AgentRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let transcript = (text(statement, 8)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([AgentEntry].self, from: $0) } ?? []
                records.append(AgentRecord(id: text(statement, 0) ?? "", groupKey: group, harness: text(statement, 1) ?? "", account: text(statement, 2) ?? "",
                    ask: text(statement, 3) ?? "", started: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    ended: sqlite3_column_type(statement, 5) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    status: text(statement, 6) ?? "", answer: text(statement, 7) ?? "", transcript: transcript))
            }
            return records
        }
    }

    /// Every conversation Pollymetric started, newest first, without transcripts (the
    /// list doesn't need them; `agentSession(id:)` loads one in full).
    func allAgentSessions(limit: Int = 300) async -> [AgentRecord] {
        await read { [self] in
            let statement = prepare("SELECT id, group_key, harness, account, ask, started, ended, status, substr(answer, 1, 400) FROM agent_session ORDER BY started DESC LIMIT ?")
            defer { sqlite3_finalize(statement) }
            bind(statement, [Int64(limit)])
            var records: [AgentRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                records.append(AgentRecord(id: text(statement, 0) ?? "", groupKey: text(statement, 1) ?? "", harness: text(statement, 2) ?? "",
                    account: text(statement, 3) ?? "", ask: text(statement, 4) ?? "",
                    started: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    ended: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    status: text(statement, 7) ?? "", answer: text(statement, 8) ?? ""))
            }
            return records
        }
    }

    func agentSession(id: String) async -> AgentRecord? {
        await read { [self] in
            let statement = prepare("SELECT id, group_key, harness, account, ask, started, ended, status, answer, transcript FROM agent_session WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            bind(statement, [id])
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            let transcript = (text(statement, 9)?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([AgentEntry].self, from: $0) } ?? []
            return AgentRecord(id: text(statement, 0) ?? "", groupKey: text(statement, 1) ?? "", harness: text(statement, 2) ?? "",
                account: text(statement, 3) ?? "", ask: text(statement, 4) ?? "",
                started: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                ended: sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                status: text(statement, 7) ?? "", answer: text(statement, 8) ?? "", transcript: transcript)
        }
    }

    func pairClient(name: String, scope: String, token: String) async -> MCPClientRecord? {
        guard ["read", "read+act"].contains(scope), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 100, !token.isEmpty else { return nil }
        let hash = MCPToken.hash(token)
        return await read { [self] in
            let record = MCPClientRecord(id: UUID().uuidString, name: name, scope: scope, created: .now, callCount: 0, revoked: false)
            let statement = prepare("INSERT INTO mcp_client (id, name, scope, token_hash, created) VALUES (?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(statement, [record.id, name, scope, hash, record.created.timeIntervalSince1970])
            return sqlite3_step(statement) == SQLITE_DONE ? record : nil
        }
    }

    func mcpClient(hash: String) async -> MCPClientRecord? {
        await read { [self] in
            let statement = prepare("SELECT id, name, scope, created, last_used, call_count, revoked FROM mcp_client WHERE token_hash = ? AND revoked = 0")
            defer { sqlite3_finalize(statement) }
            bind(statement, [hash])
            return sqlite3_step(statement) == SQLITE_ROW ? clientRecord(statement) : nil
        }
    }

    func mcpClients() async -> [MCPClientRecord] {
        await read { [self] in
            let statement = prepare("SELECT id, name, scope, created, last_used, call_count, revoked FROM mcp_client ORDER BY created DESC")
            defer { sqlite3_finalize(statement) }
            var records: [MCPClientRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW { records.append(clientRecord(statement)) }
            return records
        }
    }

    private func clientRecord(_ s: OpaquePointer?) -> MCPClientRecord {
        MCPClientRecord(id: text(s, 0) ?? "", name: text(s, 1) ?? "", scope: text(s, 2) ?? "read",
            created: Date(timeIntervalSince1970: sqlite3_column_double(s, 3)),
            lastUsed: sqlite3_column_type(s, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(s, 4)),
            callCount: Int(sqlite3_column_int64(s, 5)), revoked: sqlite3_column_int(s, 6) != 0)
    }

    func revokeClient(_ id: String) async {
        await read { [self] in
            let statement = prepare("UPDATE mcp_client SET revoked = 1 WHERE id = ?")
            defer { sqlite3_finalize(statement) }
            bind(statement, [id]); sqlite3_step(statement)
        }
    }

    func recordMCPCall(clientID: String, tool: String, allowed: Bool, at date: Date = .now) async {
        await read { [self] in
            let insert = prepare("INSERT INTO mcp_call (client_id, ts, tool, allowed) VALUES (?, ?, ?, ?)")
            bind(insert, [clientID, date.timeIntervalSince1970, tool, Int64(allowed ? 1 : 0)])
            sqlite3_step(insert); sqlite3_finalize(insert)
            let update = prepare("UPDATE mcp_client SET last_used = ?, call_count = call_count + 1 WHERE id = ?")
            bind(update, [date.timeIntervalSince1970, clientID]); sqlite3_step(update); sqlite3_finalize(update)
            pruneMCPCalls()
        }
    }

    func mcpCalls() async -> [MCPCallRecord] {
        await read { [self] in
            pruneMCPCalls()
            let statement = prepare("SELECT id, client_id, ts, tool, allowed FROM mcp_call ORDER BY ts DESC LIMIT 200")
            defer { sqlite3_finalize(statement) }
            var records: [MCPCallRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                records.append(MCPCallRecord(id: sqlite3_column_int64(statement, 0), clientID: text(statement, 1) ?? "",
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), tool: text(statement, 3) ?? "",
                    allowed: sqlite3_column_int(statement, 4) != 0))
            }
            return records
        }
    }

    private func pruneMCPCalls() {
        let statement = prepare("DELETE FROM mcp_call WHERE ts < ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, [Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970]); sqlite3_step(statement)
    }

    func recordInteraction(_ kind: InteractionKind, target: String?, context: String?, at date: Date = .now) {
        queue.async { [self] in
            let statement = prepare("INSERT INTO interaction (ts, kind, target, context) VALUES (?, ?, ?, ?)")
            defer { sqlite3_finalize(statement) }
            bind(statement, [date.timeIntervalSince1970, kind.rawValue, target, context]); sqlite3_step(statement)
            pruneInteractions()
        }
    }

    func inspectionPatterns(since: Date, now: Date = .now) async -> [InspectionPattern] {
        await read { [self] in
            pruneInteractions(now: now)
            let statement = prepare("""
                SELECT i.target, MAX(i.context), COUNT(*), MAX(i.ts),
                    (SELECT p.label FROM process p WHERE p.group_key = i.target ORDER BY p.started_at DESC LIMIT 1)
                FROM interaction i WHERE i.kind = 'process_inspect' AND i.ts >= ? AND i.ts <= ? AND i.target IS NOT NULL
                GROUP BY i.target ORDER BY COUNT(*) DESC, MAX(i.ts) DESC, i.target LIMIT 200
                """)
            defer { sqlite3_finalize(statement) }
            bind(statement, [since.timeIntervalSince1970, now.timeIntervalSince1970])
            var patterns: [InspectionPattern] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let target = text(statement, 0) ?? ""
                // Group keys are app|label|project, including processes too quiet to be sampled.
                let parts = target.split(separator: "|", omittingEmptySubsequences: false)
                let label = text(statement, 4) ?? (parts.count == 3 ? String(parts[1]) : target)
                patterns.append(InspectionPattern(target: target, context: text(statement, 1), count: Int(sqlite3_column_int64(statement, 2)),
                    lastInspected: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), label: label))
            }
            return patterns
        }
    }

    func clearInteractions() async {
        await read { [self] in exec("DELETE FROM interaction") }
    }

    func interactionCount() async -> Int {
        await read { [self] in
            pruneInteractions()
            let statement = prepare("SELECT COUNT(*) FROM interaction")
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
        }
    }

    private func pruneInteractions(now: Date = .now) {
        let statement = prepare("DELETE FROM interaction WHERE ts < ?")
        defer { sqlite3_finalize(statement) }
        bind(statement, [now.addingTimeInterval(-90 * 86_400).timeIntervalSince1970]); sqlite3_step(statement)
    }

    // MARK: SQLite plumbing

    private func read<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func points(_ statement: OpaquePointer?) -> [TimePoint] {
        var points: [TimePoint] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            points.append(TimePoint(
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                value: sqlite3_column_double(statement, 1)
            ))
        }
        return points
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            NSLog("Pollymetric: SQL error: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        return statement
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ statement: OpaquePointer?, _ values: [Any?]) {
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let v as String: sqlite3_bind_text(statement, index, v, -1, Self.transient)
            case let v as Int64: sqlite3_bind_int64(statement, index, v)
            case let v as Double: sqlite3_bind_double(statement, index, v)
            default: sqlite3_bind_null(statement, index)
            }
        }
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }
}
