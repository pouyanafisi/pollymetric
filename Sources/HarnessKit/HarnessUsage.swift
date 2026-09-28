import Foundation

public struct UsageWindow: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// As the vendor's own view names it: "Current session", "Weekly, all models".
    public var label: String
    public var usedPercent: Int
    public var resetsAt: Date?
    public var windowMinutes: Int?
}

public struct AccountUsage: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, expired, signedOut, unavailable }

    public var status: Status
    /// What to do about anything other than `.ok`, in plain words.
    public var message: String?
    /// The plan as the vendor names it: "Max (20x)", "Pro", "Plus".
    public var plan: String?
    /// Who the account is, when the read learned it (fills in emails Codex doesn't print).
    public var identity: String?
    public var windows: [UsageWindow]
    public var at: Date

    static func failure(_ status: Status, _ message: String, plan: String? = nil) -> AccountUsage {
        AccountUsage(status: status, message: message, plan: plan, identity: nil, windows: [], at: .now)
    }
}

/// Reads one account's plan usage the way the harness itself does. Vendor specifics
/// live here, behind a name a descriptor can refer to (`"usage": "claude-cli"`).
public protocol UsageReader: Sendable {
    func read(home: String?, isDefault: Bool, path: String) async -> AccountUsage
}

public enum UsageReaders {
    /// Built-in readers by name. Register more with `register(_:as:)`.
    nonisolated(unsafe) public private(set) static var byName: [String: UsageReader] = [
        "claude-cli": ClaudeUsageReader(),
        "codex-app-server": CodexUsageReader(),
    ]

    public static func register(_ reader: UsageReader, as name: String) { byName[name] = reader }
}

extension HarnessDetector {
    /// Usage for one account, or nil when the harness has no usage reader.
    public func usage(_ harness: HarnessInstallation, _ account: HarnessAccount) async -> AccountUsage? {
        guard let name = harness.descriptor.usage, let reader = UsageReaders.byName[name] else { return nil }
        return await reader.read(home: account.home, isDefault: account.isDefault, path: await shellPath())
    }
}

// MARK: Claude

/// Asks Claude Code itself: `claude -p /usage` in the account's config home.
///
/// `/usage` is a local command. It runs no model turn and costs nothing. Claude Code
/// reads its own credentials, so Pollymetric never touches the keychain or a token and
/// there are no permission prompts. `--no-session-persistence` keeps it from writing a
/// transcript, and `--strict-mcp-config` skips starting your MCP servers.
struct ClaudeUsageReader: UsageReader {
    func read(home: String?, isDefault: Bool, path: String) async -> AccountUsage {
        guard let claude = HarnessDetector.find(["claude"], in: path) else {
            return .failure(.unavailable, "Claude Code isn't installed.")
        }
        var env = HarnessDetector.baseEnvironment(path: path)
        if !isDefault, let home { env["CLAUDE_CONFIG_DIR"] = home }
        guard let result = await CommandRunner.run(
            [claude, "-p", "/usage", "--output-format", "json", "--no-session-persistence", "--strict-mcp-config"],
            environment: env, timeout: 60
        ) else { return .failure(.unavailable, "Claude Code didn't answer.") }

        guard let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              let text = json["result"] as? String
        else { return .failure(.unavailable, "Claude Code's answer couldn't be read.") }
        // Even without persistence, Claude Code creates an empty session-env/<id> folder.
        // Remove exactly that folder, and only if it's still empty, so reads leave no trace.
        if let sessionID = json["session_id"] as? String, !sessionID.isEmpty, !sessionID.contains("/") {
            let base = home ?? (NSHomeDirectory() + "/.claude")
            let folder = URL(fileURLWithPath: base).appendingPathComponent("session-env").appendingPathComponent(sessionID)
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
        if json["is_error"] as? Bool == true { return .failure(.unavailable, text) }
        let lowered = text.lowercased()
        let windows = Self.windows(text)
        if windows.isEmpty, lowered.contains("not logged in") || lowered.contains("/login") {
            return .failure(.signedOut, "Not signed in on this Mac.")
        }
        if windows.isEmpty { return .failure(.unavailable, text.split(separator: "\n").first.map(String.init) ?? "No usage reported.") }
        return AccountUsage(status: .ok, message: nil, plan: nil, identity: nil, windows: windows, at: .now)
    }

    /// Lines like `Current week (all models): 12% used · resets Oct 3 at 5:59pm (America/Los_Angeles)`.
    static func windows(_ text: String, now: Date = .now) -> [UsageWindow] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = line.wholeMatch(of: #/(Current [^:]+):\s*(\d+)% used(?:\s*·\s*resets\s+(.+))?/#) else { return nil }
            let name = String(m.1)
            let isSession = name.lowercased().contains("session")
            let label: String
            if isSession {
                label = "Current session"
            } else if let scope = name.firstMatch(of: #/\((.+)\)/#) {
                label = scope.1 == "all models" ? "Weekly, all models" : "Weekly, \(scope.1)"
            } else {
                label = name
            }
            return UsageWindow(
                id: label, label: label, usedPercent: min(100, Int(m.2) ?? 0),
                resetsAt: m.3.flatMap { parseReset(String($0), now: now) },
                windowMinutes: isSession ? 300 : 10_080
            )
        }
    }

    /// "Oct 3 at 5:59pm (America/Los_Angeles)" or "5:09pm (America/Los_Angeles)".
    static func parseReset(_ text: String, now: Date) -> Date? {
        var body = text
        var zone = TimeZone.current
        if let m = text.firstMatch(of: #/\s*\(([^)]+)\)\s*$/#) {
            zone = TimeZone(identifier: String(m.1)) ?? zone
            body = String(text[..<m.range.lowerBound])
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: now)
        for format in ["MMM d 'at' h:mma yyyy", "MMM d 'at' ha yyyy"] {
            formatter.dateFormat = format
            if var date = formatter.date(from: "\(body) \(year)") {
                // A reset is always ahead; "Jan 2" seen on Dec 30 belongs to next year.
                if date < now.addingTimeInterval(-86_400) { date = calendar.date(byAdding: .year, value: 1, to: date) ?? date }
                return date
            }
        }
        for format in ["h:mma", "ha"] {
            formatter.dateFormat = format
            if let time = formatter.date(from: body) {
                let parts = calendar.dateComponents([.hour, .minute], from: time)
                var date = calendar.date(bySettingHour: parts.hour ?? 0, minute: parts.minute ?? 0, second: 0, of: now) ?? now
                if date < now { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
                return date
            }
        }
        return nil
    }

    static func plan(_ subscription: String?) -> String? {
        guard let subscription, !subscription.isEmpty else { return nil }
        return subscription.prefix(1).uppercased() + subscription.dropFirst()
    }
}

// MARK: Codex

/// Codex's local app server, over JSON-RPC on stdio: `account/read` and
/// `account/rateLimits/read`, with CODEX_HOME pointed at the account. No tokens pass
/// through Pollymetric.
struct CodexUsageReader: UsageReader {
    func read(home: String?, isDefault: Bool, path: String) async -> AccountUsage {
        guard let codex = HarnessDetector.find(["codex"], in: path) else {
            return .failure(.unavailable, "Codex isn't installed.")
        }
        var env = HarnessDetector.baseEnvironment(path: path)
        if !isDefault, let home { env["CODEX_HOME"] = home }
        let replies = await JSONRPCSession.exchange(
            [codex, "app-server"], environment: env,
            requests: [
                (1, "account/read", ["refreshToken": false]),
                (2, "account/rateLimits/read", nil),
            ],
            timeout: 30
        )
        let account = (replies[1] as? [String: Any])?["account"]
        if account is NSNull { return .failure(.signedOut, "Not signed in on this Mac.") }
        let accountInfo = account as? [String: Any]
        let identity = accountInfo?["email"] as? String
        guard let limits = (replies[2] as? [String: Any])?["rateLimits"] as? [String: Any] else {
            var usage = AccountUsage.failure(.unavailable, "Codex didn't report its limits.", plan: Self.plan(accountInfo?["planType"]))
            usage.identity = identity
            return usage
        }
        var windows = [Self.window("primary", limits["primary"]), Self.window("secondary", limits["secondary"])].compactMap { $0 }
        if let byID = (replies[2] as? [String: Any])?["rateLimitsByLimitId"] as? [String: [String: Any]] {
            for (id, entry) in byID.sorted(by: { $0.key < $1.key }) {
                guard let name = entry["limitName"] as? String else { continue }
                for side in ["primary", "secondary"] {
                    if let w = Self.window("\(id):\(side)", entry[side], prefix: name), w.usedPercent > 0 { windows.append(w) }
                }
            }
        }
        return AccountUsage(status: .ok, message: nil, plan: Self.plan(limits["planType"] ?? accountInfo?["planType"]),
                            identity: identity, windows: windows, at: .now)
    }

    static func window(_ id: String, _ value: Any?, prefix: String = "") -> UsageWindow? {
        guard let w = value as? [String: Any], let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
        let minutes = (w["windowDurationMins"] as? NSNumber)?.intValue
        let span: String = switch minutes {
        case nil: "Limit"
        case 300: "5-hour limit"
        case 10_080: "Weekly limit"
        case let m? where m % 1440 == 0: "\(m / 1440)-day limit"
        case let m? where m % 60 == 0: "\(m / 60)-hour limit"
        case let m?: "\(m)-minute limit"
        }
        return UsageWindow(
            id: id, label: prefix.isEmpty ? span : "\(prefix), \(span.lowercased())",
            usedPercent: Int(max(0, min(100, used.rounded()))),
            resetsAt: (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            windowMinutes: minutes
        )
    }

    static func plan(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// One short-lived JSON-RPC conversation over a child process's stdio: initialize,
/// send the requests, collect their replies, stop the process.
enum JSONRPCSession {
    static func exchange(
        _ argv: [String], environment: [String: String],
        requests: [(id: Int, method: String, params: Any?)], timeout: TimeInterval
    ) async -> [Int: Any] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = ChildProcess(executable: argv[0], arguments: Array(argv.dropFirst()), environment: environment, disclaim: true)
                let input = Pipe(), output = Pipe()
                process.standardInput = input
                process.standardOutput = output
                guard (try? process.run()) != nil else { continuation.resume(returning: [:]); return }

                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                func send(_ object: [String: Any]) {
                    if let data = try? JSONSerialization.data(withJSONObject: object) {
                        input.fileHandleForWriting.write(data + Data([0x0A]))
                    }
                }
                send(["jsonrpc": "2.0", "id": 0, "method": "initialize",
                      "params": ["clientInfo": ["name": "pollymetric", "version": "0.1.0"]]])
                for r in requests {
                    send(["jsonrpc": "2.0", "id": r.id, "method": r.method, "params": r.params ?? NSNull()])
                }

                var replies: [Int: Any] = [:]
                let wanted = Set(requests.map(\.id))
                var buffer = Data()
                let handle = output.fileHandleForReading
                while replies.count < wanted.count {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let id = message["id"] as? Int, wanted.contains(id) else { continue }
                        replies[id] = message["error"].map { ["error": $0] } ?? message["result"] ?? NSNull()
                    }
                }
                killer.cancel()
                if process.isRunning { process.terminate() }
                continuation.resume(returning: replies)
            }
        }
    }
}
