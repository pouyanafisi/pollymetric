import AppKit
import Darwin
import HarnessKit
import SwiftUI

/// What your agents have been given: the MCP servers and skills each one loads, what
/// they run, and what they can reach.
///
/// Read-only and never cached to disk. Only the config files listed in `Scanner` are
/// read; env values are looked at just long enough to decide a flag and never kept.
struct AgentExtensionsReport: Codable, Sendable, Equatable {
    var items: [AgentExtension] = []

    var servers: [AgentExtension] { items.filter { $0.kind == .server } }
    var skillsAndPlugins: [AgentExtension] { items.filter { $0.kind != .server } }
    /// MCP servers carrying an amber flag: the sidebar badge.
    var worthALookCount: Int { servers.filter(\.isWorthALook).count }
}

struct AgentExtension: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable { case server, skill, plugin }
    enum Transport: String, Codable, Sendable { case local, remote }

    enum Flag: String, Codable, Sendable, CaseIterable, Identifiable {
        case unpinned, plaintextKey, unencrypted, remote, runsScripts
        var id: String { rawValue }

        /// Amber means worth a second look; the rest are neutral facts.
        var isAmber: Bool { self == .unpinned || self == .plaintextKey || self == .unencrypted }

        var title: String {
            switch self {
            case .unpinned: "Runs the latest from the internet"
            case .plaintextKey: "Key stored in plain text"
            case .unencrypted: "Unencrypted"
            case .remote: "Connects to a remote server"
            case .runsScripts: "Can run scripts"
            }
        }
    }

    var id: String { "\(agent):\(kind.rawValue):\(name):\(source):\(scope):\(path)" }
    var agent: String
    var kind: Kind
    var name: String
    /// Where it comes from: "Your skill", a plugin's name, or a marketplace for plugins.
    var source: String
    /// "Global", or the project it belongs to.
    var scope: String = "Global"
    /// Accounts that have it, e.g. ["Default", "work"].
    var accounts: [String] = []
    var summary: String?
    /// What it runs, with secret-looking values masked.
    var command: String?
    /// The server it talks to, with secret-looking values masked.
    var url: String?
    var host: String?
    var transport: Transport = .local
    /// Names only, never values.
    var envNames: [String] = []
    /// Names of settings whose value is written right in the config. Never the values.
    var plaintextKeyNames: [String] = []
    /// The config file for servers, the folder for skills and plugins.
    var path: String
    /// The file "Open config" opens.
    var configPath: String
    var isEnabled = true
    var isRunning = false
    var flags: [Flag] = []
    /// Plugins only.
    var skillCount = 0
    var serverCount = 0

    var isWorthALook: Bool {
        kind == .server ? flags.contains(where: \.isAmber) : flags.contains(.runsScripts)
    }

    func detail(_ flag: Flag) -> String {
        switch flag {
        case .unpinned:
            "Each time it starts, it downloads and runs whatever version the package registry serves at that moment."
        case .plaintextKey:
            "\(Self.list(plaintextKeyNames)) \(plaintextKeyNames.count == 1 ? "is" : "are") written directly in this file. Anything that can read the file can use \(plaintextKeyNames.count == 1 ? "it" : "them")."
        case .unencrypted:
            "Talks to \(host ?? "its server") over plain http://, so anyone on the network path can read the traffic."
        case .remote:
            "Sends your agent's requests to \(host ?? "a server on the internet")."
        case .runsScripts:
            kind == .plugin ? "Ships its own programs or hooks that your agent can run." : "Ships its own programs that your agent can run."
        }
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: "A key"
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + names.last!
        }
    }
}

enum AgentExtensions {
    static func scan() async throws -> AgentExtensionsReport {
        await Task.detached(priority: .utility) { scan(home: Paths.home) }.value
    }

    /// `processes` returns the argv of live processes whose executable name is in the set;
    /// tests pass fixtures. Nothing is executed.
    static func scan(home: String, processes: (Set<String>) -> [[String]] = liveCommandLines) -> AgentExtensionsReport {
        var scanner = Scanner(home: home)
        scanner.run()
        return scanner.finish(processes: processes)
    }

    static let agentOrder = ["Claude Code", "Codex", "Claude Desktop", "Cursor", "VS Code", "Windsurf", "OpenCode"]

    /// Harness ids whose built-in logos fit each agent.
    static let logoIDs = ["Claude Code": "claude-code", "Claude Desktop": "claude-code", "Codex": "codex",
                          "Cursor": "cursor-agent", "OpenCode": "opencode"]

    // MARK: Flags

    /// The package an `npx`/`bunx`/`pnpm dlx`/`uvx`/`pipx run` launch pulls from a registry
    /// when it isn't pinned to an exact version, else nil.
    static func unpinnedPackage(command: String, args: [String]) -> String? {
        guard let (package, python) = runnerPackage(command: command, args: args) else { return nil }
        return isPinned(package, python: python) ? nil : package
    }

    /// The package spec a registry runner launches, however it's pinned.
    static func runnerPackage(command: String, args: [String]) -> (package: String, python: Bool)? {
        var rest = args
        let python: Bool
        switch program(command) {
        case "npx", "bunx": python = false
        case "pnpm", "yarn":
            guard rest.first == "dlx" else { return nil }
            rest.removeFirst(); python = false
        case "npm":
            guard let first = rest.first, first == "exec" || first == "x" else { return nil }
            rest.removeFirst(); python = false
        case "bun":
            guard rest.first == "x" else { return nil }
            rest.removeFirst(); python = false
        case "uvx": python = true
        case "uv":
            guard rest.count > 1, rest[0] == "tool", rest[1] == "run" else { return nil }
            rest.removeFirst(2); python = true
        case "pipx":
            guard rest.first == "run" else { return nil }
            rest.removeFirst(); python = true
        default: return nil
        }

        let explicit: Set<String> = python ? ["--from", "--spec"] : ["-p", "--package"]
        let valued: Set<String> = python
            ? ["--with", "-w", "--python", "-p", "--index-url", "-i", "--extra-index-url", "--index", "--default-index",
               "--constraint", "-c", "--pip-args", "--refresh-package", "--upgrade-package", "-P", "--with-requirements"]
            : ["--registry", "--cache", "--prefix", "-c", "--call", "--userconfig", "--workspace", "-w"]
        var i = 0
        while i < rest.count {
            let arg = rest[i]
            if explicit.contains(arg) { return i + 1 < rest.count ? (rest[i + 1], python) : nil }
            if let eq = arg.firstIndex(of: "="), explicit.contains(String(arg[..<eq])) {
                return (String(arg[arg.index(after: eq)...]), python)
            }
            if arg == "--" { i += 1; continue }
            if arg.hasPrefix("-") { i += valued.contains(arg) ? 2 : 1; continue }
            let isLocal = ["/", "./", "../", "~", "file:"].contains { arg.hasPrefix($0) } || arg.hasSuffix(".tgz")
            return isLocal ? nil : (arg, python)
        }
        return nil
    }

    static func isPinned(_ spec: String, python: Bool) -> Bool {
        if spec.contains("://") || spec.hasPrefix("github:") || spec.hasPrefix("git+") { return spec.contains("#") }
        let exact = #/v?\d+\.\d+(\.\d+)?([-+.][0-9A-Za-z.+-]+)?/#
        if python {
            if let range = spec.range(of: "==") {
                return spec[range.upperBound...].trimmingPrefix("=").wholeMatch(of: exact) != nil
            }
            if let at = spec.firstIndex(of: "@") {
                return spec[spec.index(after: at)...].trimmingCharacters(in: .whitespaces).wholeMatch(of: exact) != nil
            }
            return false
        }
        // npm: "@scope/name@1.2.3" or "name@1.2.3". Tags ("latest") and ranges aren't pins.
        let body = spec.hasPrefix("@") ? spec.dropFirst() : Substring(spec)
        guard let at = body.lastIndex(of: "@") else { return false }
        return body[body.index(after: at)...].wholeMatch(of: #/v?\d+\.\d+\.\d+([-+][0-9A-Za-z.+-]+)?/#) != nil
    }

    /// Env and header names that usually hold a credential.
    static func looksSecret(_ name: String) -> Bool {
        var spaced = ""
        var previousLower = false
        for c in name {
            if c.isUppercase, previousLower { spaced.append("_") }
            spaced.append(c)
            previousLower = c.isLowercase || c.isNumber
        }
        let words = spaced.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let exact: Set<String> = ["KEY", "KEYS", "APIKEY", "TOKEN", "TOKENS", "SECRET", "SECRETS", "PASSWORD", "PASSWD",
                                  "PWD", "PASS", "PASSPHRASE", "CREDENTIAL", "CREDENTIALS", "AUTHORIZATION", "COOKIE",
                                  "PAT", "BEARER", "SESSION", "DSN"]
        return words.contains { word in
            exact.contains(word) || word.hasSuffix("TOKEN") || word.hasSuffix("SECRET") || word.hasSuffix("APIKEY")
                || word.hasSuffix("PASSWORD")
        }
    }

    /// True when a config value is the secret itself rather than a reference to one
    /// (`${VAR}`, `$VAR`, `{env:VAR}`) or a placeholder.
    static func isLiteral(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return false }
        if v.contains("${") || v.hasPrefix("$") || v.contains("{env:") || v.contains("{file:") || v.hasPrefix("{{") { return false }
        if v.hasPrefix("<"), v.hasSuffix(">") { return false }
        let upper = v.uppercased()
        if upper.hasPrefix("YOUR") || upper.contains("YOUR_") || upper.contains("YOUR-") || upper.hasPrefix("REPLACE")
            || upper == "CHANGEME" || upper == "XXX" || upper == "TODO" { return false }
        if ["bearer", "basic", "token"].contains(v.lowercased()) { return false }
        return true
    }

    static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0" || host.hasPrefix("127.")
    }

    /// A URL with secret-looking parts masked: passwords, tokens and key-like query values.
    static func redactURL(_ url: String) -> String {
        var text = ProcessDescriber.maskInline(url)
        guard var parts = URLComponents(string: text), let items = parts.queryItems, !items.isEmpty else { return text }
        var changed = false
        parts.queryItems = items.map { item in
            guard looksSecret(item.name), let value = item.value, !value.isEmpty else { return item }
            changed = true
            return URLQueryItem(name: item.name, value: "••••")
        }
        if changed, let masked = parts.string { text = masked.replacingOccurrences(of: "%E2%80%A2", with: "•") }
        return text
    }

    // MARK: Running now

    /// Executable names normalized for matching: lowercased, no extension, no "-cli", and
    /// every python3.x as "python".
    static func program(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent.lowercased()
        for ext in [".js", ".cjs", ".mjs", ".py", ".sh"] where name.hasSuffix(ext) { name.removeLast(ext.count) }
        if name.hasSuffix("-cli") { name.removeLast(4) }
        if name.hasPrefix("python") { return "python" }
        return name
    }

    /// Process names worth reading argv for. Shebang scripts (`npx`) show up as their
    /// interpreter, so interpreters are always included.
    static func processNames(for command: String) -> Set<String> {
        let name = program(command)
        var names: Set<String> = [name, "node", "python", "bun", "deno", "uv"]
        if name == "uvx" { names.insert("uv") }
        return names
    }

    /// One live process, tokenized once so every server can be checked against it cheaply.
    struct LiveProcess {
        var tokens: [String]
        var heads: Set<String>
        var packages: Set<String>
        var shortNames: Set<String>
        /// Packages run from inside a node_modules folder.
        var installed: Set<String>

        init(argv: [String]) {
            // Node rewrites its title ("npm exec pkg@1.0"), which folds argv into one string.
            tokens = argv.flatMap { $0.split(separator: " ").map(String.init) }
            heads = Set(tokens.prefix(2).map(AgentExtensions.program))
            packages = Set(tokens.map { token in
                token.hasPrefix("@") ? "@" + token.dropFirst().prefix { $0 != "@" } : String(token.prefix { $0 != "@" && $0 != "=" })
            })
            shortNames = Set(packages.map { ($0 as NSString).lastPathComponent })
            installed = Set(tokens.compactMap { token -> String? in
                guard let range = token.range(of: "/node_modules/", options: .backwards) else { return nil }
                let parts = token[range.upperBound...].split(separator: "/", maxSplits: 2)
                guard let first = parts.first else { return nil }
                return first.hasPrefix("@") && parts.count > 1 ? "\(first)/\(parts[1])" : String(first)
            })
        }
    }

    /// Decides whether a live process looks like one server. Package runners match on the
    /// package they fetched; everything else on its program and arguments.
    struct ProcessMatcher {
        private enum Rule {
            case package(name: String, short: String?)
            case program(aliases: Set<String>, needed: [String])
            case never
        }
        private let rule: Rule

        init(command: String, args: [String], home: String) {
            if let (package, python) = AgentExtensions.runnerPackage(command: command, args: args) {
                let name = python ? String(package.prefix { !"=<>~![@ ".contains($0) })
                    : (package.hasPrefix("@") ? "@" + package.dropFirst().prefix { $0 != "@" } : String(package.prefix { $0 != "@" }))
                let short = (name as NSString).lastPathComponent
                rule = .package(name: name, short: short.count >= 6 ? short : nil)
                return
            }
            let wanted = AgentExtensions.program(command)
            let needed = args.filter { !$0.contains("$") }.map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 }
            if needed.isEmpty, ProcessDescriber.wrappers.contains(wanted) || ProcessDescriber.isInterpreter(wanted) {
                rule = .never
            } else {
                rule = .program(aliases: wanted == "uvx" ? ["uvx", "uv"] : [wanted], needed: needed)
            }
        }

        func matches(_ process: LiveProcess) -> Bool {
            switch rule {
            case .never:
                return false
            case let .package(name, short):
                if process.packages.contains(name) { return true }
                if let short, process.shortNames.contains(short) { return true }
                return process.installed.contains(name)
            case let .program(aliases, needed):
                guard !process.heads.isDisjoint(with: aliases) else { return false }
                var index = 0
                for token in process.tokens.dropFirst() where index < needed.count && token == needed[index] { index += 1 }
                return index == needed.count
            }
        }
    }

    /// argv of your own processes whose name is in `names`. Read in memory to decide
    /// "Running now", then dropped.
    static func liveCommandLines(named names: Set<String>) -> [[String]] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        let me = getpid()
        var result: [[String]] = []
        for pid in pids.prefix(Int(max(0, count))) where pid > 0 && pid != me {
            guard let raw = IdentityResolver.name(pid: pid) else { continue }
            let name = program(raw)
            guard names.contains(name) || (name.count >= 15 && names.contains { $0.hasPrefix(name) }) else { continue }
            let argv = IdentityResolver.arguments(pid: pid).1
            if !argv.isEmpty { result.append(argv) }
        }
        return result
    }

    // MARK: Parsing

    /// JSON that may carry comments and trailing commas (VS Code, OpenCode).
    static func parseJSON(_ data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        let relaxed = stripJSONC(String(decoding: data, as: UTF8.self))
        return (try? JSONSerialization.jsonObject(with: Data(relaxed.utf8))) as? [String: Any]
    }

    static func stripJSONC(_ text: String) -> String {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var inString = false, escaped = false
        while i < chars.count {
            let c = chars[i]
            if inString {
                out.append(c)
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; out.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            if c == "," {
                var j = i + 1
                while j < chars.count, chars[j].properties.isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    /// `name` and `description` from a SKILL.md's YAML frontmatter, including folded
    /// (`>`) and literal (`|`) block values.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        func trimmed(_ s: some StringProtocol) -> String { s.trimmingCharacters(in: .whitespaces) }
        func indented(_ s: String) -> Bool { s.hasPrefix(" ") || s.hasPrefix("\t") }
        var result: [String: String] = [:]
        var i = 1
        while i < lines.count, trimmed(lines[i]) != "---" {
            let line = lines[i]
            guard !indented(line), let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = trimmed(line[..<colon])
            var value = trimmed(line[line.index(after: colon)...])
            if value.isEmpty || ["|", ">", "|-", ">-", "|+", ">+"].contains(value) {
                var block: [String] = []
                i += 1
                while i < lines.count, trimmed(lines[i]) != "---", indented(lines[i]) || trimmed(lines[i]).isEmpty {
                    block.append(trimmed(lines[i]))
                    i += 1
                }
                let text = block.filter { !$0.isEmpty }
                result[key] = value.hasPrefix("|") ? block.drop { $0.isEmpty }.joined(separator: "\n") : text.joined(separator: " ")
                continue
            }
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: "\n")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
            }
            result[key] = value
            i += 1
        }
        return result
    }

    static func firstLine(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        return line.count > 240 ? String(line.prefix(239)) + "…" : line
    }
}

// MARK: - Scanner

private struct Scanner {
    let home: String
    private var drafts: [Draft] = []
    private let fm = FileManager.default
    /// Accounts often share skill and plugin folders through symlinks; each is read once.
    private var scriptCache: [String: Bool] = [:]
    private var frontmatterCache: [String: [String: String]] = [:]
    private var jsonCache: [String: [String: Any]] = [:]
    /// The same server usually appears in several accounts, and masking isn't free.
    private var redactCache: [[String]: [String]] = [:]

    private struct Draft {
        var item: AgentExtension
        /// Raw launch line, used only to spot a live process, then dropped.
        var command: String?
        var args: [String] = []
    }

    init(home: String) {
        self.home = home
    }

    mutating func run() {
        claudeCode()
        codex()
        for (agent, file, key) in [
            ("Claude Desktop", "Library/Application Support/Claude/claude_desktop_config.json", "mcpServers"),
            ("Cursor", ".cursor/mcp.json", "mcpServers"),
            ("VS Code", "Library/Application Support/Code/User/mcp.json", "servers"),
            ("Windsurf", ".codeium/windsurf/mcp_config.json", "mcpServers"),
            ("OpenCode", ".config/opencode/opencode.json", "mcp"),
            ("OpenCode", ".config/opencode/opencode.jsonc", "mcp"),
        ] {
            let path = inHome(file)
            guard let json = readJSON(path) else { continue }
            addServers(json[key], agent: agent, account: "Default", scope: "Global", source: nil, configPath: path)
        }
    }

    func finish(processes: (Set<String>) -> [[String]]) -> AgentExtensionsReport {
        let candidates = drafts.indices.filter {
            drafts[$0].item.kind == .server && drafts[$0].item.isEnabled && drafts[$0].command != nil
        }
        let names = candidates.reduce(into: Set<String>()) { $0.formUnion(AgentExtensions.processNames(for: drafts[$1].command!)) }
        let live = (names.isEmpty ? [] : processes(names)).map(AgentExtensions.LiveProcess.init)
        let checked = Set(candidates)

        var items: [AgentExtension] = []
        var index: [String: Int] = [:]
        for (n, draft) in drafts.enumerated() {
            var item = draft.item
            if checked.contains(n), let command = draft.command {
                let matcher = AgentExtensions.ProcessMatcher(command: command, args: draft.args, home: home)
                item.isRunning = live.contains(where: matcher.matches)
            }
            // The same server or skill in several accounts is one row listing each account.
            let key: String = switch item.kind {
            case .server: [item.agent, item.name, item.scope, item.source, item.command ?? "", item.url ?? "",
                           "\(item.isEnabled)", item.flags.map(\.rawValue).joined(), item.plaintextKeyNames.joined()].joined(separator: "|")
            case .skill: [item.agent, "skill", item.path].joined(separator: "|")
            case .plugin: [item.agent, "plugin", item.name, item.source, item.scope].joined(separator: "|")
            }
            if let existing = index[key] {
                for account in item.accounts where !items[existing].accounts.contains(account) { items[existing].accounts.append(account) }
                items[existing].isRunning = items[existing].isRunning || item.isRunning
            } else {
                index[key] = items.count
                items.append(item)
            }
        }
        let order = { (agent: String) in AgentExtensions.agentOrder.firstIndex(of: agent) ?? .max }
        let kindOrder: [AgentExtension.Kind: Int] = [.server: 0, .plugin: 1, .skill: 2]
        items.sort {
            if $0.agent != $1.agent { return order($0.agent) < order($1.agent) }
            if $0.kind != $1.kind { return kindOrder[$0.kind]! < kindOrder[$1.kind]! }
            let ownA = $0.source == "Your skill" || $0.source == "Config", ownB = $1.source == "Your skill" || $1.source == "Config"
            if ownA != ownB { return ownA }
            if $0.source != $1.source { return $0.source.localizedStandardCompare($1.source) == .orderedAscending }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return AgentExtensionsReport(items: items)
    }

    // MARK: Claude Code

    private mutating func claudeCode() {
        var projects: [(root: String, accounts: [String])] = []
        var projectIndex: [String: Int] = [:]
        for (account, dir) in accounts(harness: "claude-code", fallback: ("~/.claude", "~/.claude-*")) {
            // The default account keeps its state beside its folder; others inside it.
            let statePath = account == "Default" ? dir + ".json" : dir + "/.claude.json"
            if let state = readJSON(statePath) {
                addServers(state["mcpServers"], agent: "Claude Code", account: account, scope: "Global", source: nil, configPath: statePath)
                if let entries = state["projects"] as? [String: Any] {
                    for (root, value) in entries.sorted(by: { $0.key < $1.key }) {
                        if let i = projectIndex[root] { projects[i].accounts.append(account) }
                        else { projectIndex[root] = projects.count; projects.append((root, [account])) }
                        if let project = value as? [String: Any] {
                            addServers(project["mcpServers"], agent: "Claude Code", account: account,
                                       scope: projectName(root), source: nil, configPath: statePath)
                        }
                    }
                }
            }
            addSkills(in: dir + "/skills", agent: "Claude Code", account: account, source: "Your skill", scope: "Global")
            addPlugins(accountDir: dir, account: account)
        }
        for (root, accounts) in projects where isDirectory(root) {
            let file = (root as NSString).appendingPathComponent(".mcp.json")
            guard let json = readJSON(file) else { continue }
            for account in accounts {
                addServers(Self.serverTable(json), agent: "Claude Code", account: account, scope: projectName(root), source: nil, configPath: file)
            }
        }
    }

    private mutating func addPlugins(accountDir: String, account: String) {
        let enabled = readJSON(accountDir + "/settings.json")?["enabledPlugins"] as? [String: Any] ?? [:]
        guard let manifest = readJSON(accountDir + "/plugins/installed_plugins.json"),
              let plugins = manifest["plugins"] as? [String: Any] else { return }
        for (key, value) in plugins.sorted(by: { $0.key < $1.key }) {
            let entries = (value as? [[String: Any]]) ?? ((value as? [String: Any]).map { [$0] } ?? [])
            let name = String(key.split(separator: "@", maxSplits: 1).first ?? Substring(key))
            let marketplace = key.split(separator: "@", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            var chosen: [(install: String, scope: String)] = []
            if (enabled[key] as? Bool) == true,
               let user = entries.last(where: { ($0["scope"] as? String ?? "user") == "user" }),
               let install = user["installPath"] as? String {
                chosen.append((install, "Global"))
            }
            for entry in entries where ["project", "local"].contains(entry["scope"] as? String ?? "") {
                guard let project = entry["projectPath"] as? String, isDirectory(project),
                      let install = entry["installPath"] as? String else { continue }
                chosen.append((install, projectName(project)))
            }
            for (install, scope) in chosen where isDirectory(install) {
                addPlugin(name: name, marketplace: marketplace, install: install, scope: scope, account: account)
            }
        }
    }

    private mutating func addPlugin(name: String, marketplace: String, install: String, scope: String, account: String) {
        let manifestPath = install + "/.claude-plugin/plugin.json"
        let meta = readJSON(manifestPath)
        let display = (meta?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name
        let before = drafts.count
        addSkills(in: install + "/skills", agent: "Claude Code", account: account, source: display, scope: scope)
        let skillCount = drafts.count - before

        let serversBefore = drafts.count
        let mcpFile = install + "/.mcp.json"
        if let json = readJSON(mcpFile) {
            addServers(Self.serverTable(json), agent: "Claude Code", account: account, scope: scope, source: display,
                       configPath: mcpFile, pluginRoot: install)
        }
        if let inline = meta?["mcpServers"] as? [String: Any] {
            addServers(inline, agent: "Claude Code", account: account, scope: scope, source: display, configPath: manifestPath, pluginRoot: install)
        } else if let relative = meta?["mcpServers"] as? String {
            let file = (install as NSString).appendingPathComponent(relative)
            if let json = readJSON(file) {
                addServers(Self.serverTable(json), agent: "Claude Code", account: account, scope: scope, source: display,
                           configPath: file, pluginRoot: install)
            }
        }

        let real = resolved(install)
        var item = AgentExtension(
            agent: "Claude Code", kind: .plugin, name: display, source: marketplace, scope: scope, accounts: [account],
            summary: AgentExtensions.firstLine(meta?["description"] as? String), path: real,
            configPath: fm.fileExists(atPath: manifestPath) ? manifestPath : real
        )
        item.skillCount = skillCount
        item.serverCount = drafts.count - serversBefore
        if hasScripts(real) { item.flags.append(.runsScripts) }
        drafts.append(Draft(item: item))
    }

    // MARK: Codex

    private mutating func codex() {
        for (account, dir) in accounts(harness: "codex", fallback: ("~/.codex", "~/.codex-*")) {
            let file = dir + "/config.toml"
            if let text = readText(file) {
                addServers(MiniTOML.parse(text)["mcp_servers"], agent: "Codex", account: account, scope: "Global", source: nil, configPath: file)
            }
            addSkills(in: dir + "/skills", agent: "Codex", account: account, source: "Your skill", scope: "Global")
        }
    }

    // MARK: Servers

    /// `.mcp.json` files either wrap servers in `mcpServers` or list them at the top level.
    static func serverTable(_ json: [String: Any]) -> [String: Any] {
        if let wrapped = json["mcpServers"] as? [String: Any] { return wrapped }
        return json.filter { ($0.value as? [String: Any]).map { $0["command"] != nil || $0["url"] != nil || $0["type"] != nil } ?? false }
    }

    private mutating func addServers(_ table: Any?, agent: String, account: String, scope: String, source: String?,
                                     configPath: String, pluginRoot: String? = nil) {
        guard let table = table as? [String: Any] else { return }
        for (name, spec) in table.sorted(by: { $0.key < $1.key }) {
            guard let spec = spec as? [String: Any] else { continue }
            addServer(name: name, spec: spec, agent: agent, account: account, scope: scope, source: source,
                      configPath: configPath, pluginRoot: pluginRoot)
        }
    }

    private mutating func addServer(name: String, spec: [String: Any], agent: String, account: String, scope: String,
                                    source: String?, configPath: String, pluginRoot: String?) {
        func text(_ value: Any) -> String? { (value as? String) ?? (value as? NSNumber)?.stringValue ?? (value as? Int).map(String.init) }
        func expandRoot(_ s: String) -> String {
            guard let pluginRoot else { return s }
            return s.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: pluginRoot)
        }

        var command: String?
        var args: [String] = []
        if let list = spec["command"] as? [Any] {
            let parts = list.compactMap(text)
            command = parts.first
            args = Array(parts.dropFirst())
        } else if let single = spec["command"] as? String, !single.isEmpty {
            command = single
        }
        args += (spec["args"] as? [Any] ?? []).compactMap(text)
        if let single = command, args.isEmpty, single.contains(" "), !fm.fileExists(atPath: single) {
            let parts = single.split(separator: " ").map(String.init)
            command = parts.first
            args = Array(parts.dropFirst())
        }
        command = command.map(expandRoot)
        args = args.map(expandRoot)

        let rawURL = ["url", "serverUrl", "httpUrl"].lazy.compactMap { spec[$0] as? String }.first
        let type = (spec["type"] as? String)?.lowercased() ?? ""
        let remote = command == nil && (rawURL != nil || ["http", "sse", "remote", "streamable-http", "streamablehttp", "ws"].contains(type))
        guard command != nil || rawURL != nil else { return }

        var envNames: [String] = []
        var plaintext: [String] = []
        for key in ["env", "environment"] {
            guard let env = spec[key] as? [String: Any] else { continue }
            for (variable, value) in env.sorted(by: { $0.key < $1.key }) {
                envNames.append(variable)
                if AgentExtensions.looksSecret(variable), let value = value as? String, AgentExtensions.isLiteral(value) {
                    plaintext.append(variable)
                }
            }
        }
        for key in ["env_vars"] { envNames += (spec[key] as? [Any] ?? []).compactMap { $0 as? String } }
        if let variable = spec["bearer_token_env_var"] as? String { envNames.append(variable) }
        if let headers = spec["env_http_headers"] as? [String: Any] { envNames += headers.values.compactMap { $0 as? String } }
        for key in ["headers", "http_headers"] {
            guard let headers = spec[key] as? [String: Any] else { continue }
            for (header, value) in headers.sorted(by: { $0.key < $1.key }) {
                let lowered = header.lowercased()
                guard AgentExtensions.looksSecret(header) || lowered == "authorization" || lowered.hasPrefix("x-api"),
                      let value = value as? String, AgentExtensions.isLiteral(value) else { continue }
                plaintext.append(header)
            }
        }
        if let token = spec["bearer_token"] as? String, AgentExtensions.isLiteral(token) { plaintext.append("bearer_token") }
        if let rawURL, let parts = URLComponents(string: rawURL) {
            if let password = parts.password, AgentExtensions.isLiteral(password) { plaintext.append("the address's password") }
            for item in parts.queryItems ?? [] where AgentExtensions.looksSecret(item.name) && AgentExtensions.isLiteral(item.value ?? "") {
                plaintext.append(item.name)
            }
        }

        // What it runs, masked, and any key the masking caught in the arguments.
        var shown: String?
        if let command {
            let line = [command] + args
            let masked = redactCache[line] ?? ProcessDescriber.redact(line)
            redactCache[line] = masked
            for (i, (original, safe)) in zip(line, masked).enumerated() where original != safe {
                let value = original.firstIndex(of: "=").map { String(original[original.index(after: $0)...]) } ?? original
                guard AgentExtensions.isLiteral(value), !value.contains("$") else { continue }
                if let eq = original.firstIndex(of: "="), AgentExtensions.looksSecret(String(original[..<eq])) {
                    plaintext.append(String(original[..<eq]))
                } else if i > 0, line[i - 1].hasPrefix("-") {
                    plaintext.append(line[i - 1])
                } else {
                    plaintext.append("a value in its command line")
                }
            }
            shown = masked.map { abbreviate($0) }.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        }

        let enabled = (spec["enabled"] as? Bool ?? true) && !(spec["disabled"] as? Bool ?? false)
        var flags: [AgentExtension.Flag] = []
        if enabled, let command, AgentExtensions.unpinnedPackage(command: command, args: args) != nil { flags.append(.unpinned) }
        if !plaintext.isEmpty { flags.append(.plaintextKey) }
        var host: String?
        if remote, let rawURL, let parts = URLComponents(string: rawURL) {
            host = parts.host
            if !AgentExtensions.isLoopback(parts.host) {
                if ["http", "ws"].contains(parts.scheme?.lowercased() ?? "") { flags.append(.unencrypted) }
                flags.append(.remote)
            }
        }

        var seenEnv = Set<String>(), seenKeys = Set<String>()
        let item = AgentExtension(
            agent: agent, kind: .server, name: name, source: source ?? "Config", scope: scope, accounts: [account],
            summary: nil, command: shown, url: rawURL.map(AgentExtensions.redactURL), host: host,
            transport: remote ? .remote : .local, envNames: envNames.filter { seenEnv.insert($0).inserted },
            plaintextKeyNames: plaintext.filter { seenKeys.insert($0).inserted },
            path: configPath, configPath: configPath, isEnabled: enabled, flags: flags
        )
        drafts.append(Draft(item: item, command: remote ? nil : command, args: args))
    }

    // MARK: Skills

    private mutating func addSkills(in dir: String, agent: String, account: String, source: String, scope: String) {
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names.sorted() where !name.hasPrefix(".") {
            let folder = resolved((dir as NSString).appendingPathComponent(name))
            guard isDirectory(folder),
                  let file = ["SKILL.md", "skill.md"].map({ folder + "/" + $0 }).first(where: fm.fileExists(atPath:))
            else { continue }
            let meta = frontmatterCache[file] ?? AgentExtensions.frontmatter(readHead(file))
            frontmatterCache[file] = meta
            var item = AgentExtension(
                agent: agent, kind: .skill, name: meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? name,
                source: source, scope: scope, accounts: [account],
                summary: AgentExtensions.firstLine(meta["description"]), path: folder, configPath: file
            )
            if hasScripts(folder) { item.flags.append(.runsScripts) }
            drafts.append(Draft(item: item))
        }
    }

    /// A `scripts`, `bin` or `hooks` folder, or any executable file (a bounded walk that
    /// skips dependencies).
    private mutating func hasScripts(_ folder: String) -> Bool {
        if let cached = scriptCache[folder] { return cached }
        let found = findScripts(folder)
        scriptCache[folder] = found
        return found
    }

    private func findScripts(_ folder: String) -> Bool {
        if ["scripts", "bin", "hooks"].contains(where: { isDirectory(folder + "/" + $0) }) { return true }
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > 400 { break }
            if url.lastPathComponent == "node_modules" { walker.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey])
            if values?.isRegularFile == true, values?.isExecutable == true { return true }
        }
        return false
    }

    // MARK: Files

    /// Account homes from the harness descriptor: the default plus any `glob` matches.
    private func accounts(harness: String, fallback: (String, String)) -> [(label: String, dir: String)] {
        let spec = HarnessDescriptor.builtIns.first { $0.id == harness }?.accounts
        var result = [(label: "Default", dir: expand(spec?.default ?? fallback.0))]
        let pattern = expand(spec?.glob ?? fallback.1)
        let parent = (pattern as NSString).deletingLastPathComponent
        let namePattern = (pattern as NSString).lastPathComponent
        let prefix = namePattern.components(separatedBy: "*").first ?? namePattern
        for name in ((try? fm.contentsOfDirectory(atPath: parent)) ?? []).sorted()
        where name.hasPrefix(prefix) && name.count > prefix.count && fnmatch(namePattern, name, 0) == 0 {
            let full = (parent as NSString).appendingPathComponent(name)
            if isDirectory(full) { result.append((String(name.dropFirst(prefix.count)), full)) }
        }
        return result
    }

    private func inHome(_ relative: String) -> String { (home as NSString).appendingPathComponent(relative) }
    private func expand(_ path: String) -> String { path.hasPrefix("~") ? home + path.dropFirst() : path }
    private func resolved(_ path: String) -> String { (path as NSString).resolvingSymlinksInPath }

    private func abbreviate(_ text: String) -> String {
        text.hasPrefix(home + "/") ? "~" + text.dropFirst(home.count) : text
    }

    private func projectName(_ root: String) -> String {
        root == home ? "Home folder" : (root as NSString).lastPathComponent
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private mutating func readJSON(_ path: String) -> [String: Any]? {
        let real = resolved(path)
        if let cached = jsonCache[real] { return cached }
        guard let data = readData(real), let json = AgentExtensions.parseJSON(data) else { return nil }
        jsonCache[real] = json
        return json
    }

    private func readText(_ path: String) -> String? {
        readData(path).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Config files are small; anything past 20 MB isn't one.
    private func readData(_ path: String) -> Data? {
        guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size < 20_000_000 else { return nil }
        return fm.contents(atPath: path)
    }

    /// Frontmatter lives at the top, so only the first 32 KB are read.
    private func readHead(_ path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        return String(decoding: (try? handle.read(upToCount: 32_768)) ?? Data(), as: UTF8.self)
    }
}

// MARK: - TOML subset

/// Just enough TOML for `[mcp_servers.<name>]` tables: basic, literal and multi-line
/// strings, numbers, booleans, arrays, inline tables, dotted and quoted keys, and nested
/// table headers. Arrays of tables are skipped. Malformed lines are skipped, never fatal.
struct MiniTOML {
    private let chars: [Character]
    private var i = 0
    /// Ends a bare value. "\r\n" is its own Character in Swift, so it's listed separately.
    private static let terminators: Set<Character> = [" ", "\t", "\r", "\n", "\r\n", ",", "]", "}", "#"]

    private init(_ text: String) {
        chars = Array(text)
    }

    static func parse(_ text: String) -> [String: Any] {
        var parser = MiniTOML(text)
        return parser.document()
    }

    private var peek: Character? { i < chars.count ? chars[i] : nil }
    private func peek(_ offset: Int) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }

    private mutating func skipSpaces() { while let c = peek, c == " " || c == "\t" { i += 1 } }
    private mutating func skipToNextLine() {
        while let c = peek, c != "\n" { i += 1 }
        if peek == "\n" { i += 1 }
    }

    /// Whitespace, newlines and comments.
    private mutating func skipBlank() {
        while let c = peek {
            if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\r\n" { i += 1 }
            else if c == "#" { while let c = peek, c != "\n", c != "\r\n" { i += 1 } }
            else { break }
        }
    }

    private mutating func document() -> [String: Any] {
        var root: [String: Any] = [:]
        var table: [String]? = []
        while true {
            skipBlank()
            guard let c = peek else { break }
            let start = i
            if c == "[" {
                table = nil
                if peek(1) != "[" {
                    i += 1
                    if let path = keyPath() {
                        skipSpaces()
                        if peek == "]" {
                            table = path
                            Self.ensureTable(&root, path)
                        }
                    }
                }
                skipToNextLine()
                continue
            }
            if let path = keyPath() {
                skipSpaces()
                if peek == "=" {
                    i += 1
                    skipSpaces()
                    if let value = value(), let table { Self.set(&root, table + path, value) }
                }
            }
            skipToNextLine()
            if i == start { i += 1 }
        }
        return root
    }

    private mutating func keyPath() -> [String]? {
        var parts: [String] = []
        while true {
            skipSpaces()
            guard let c = peek else { return nil }
            if c == "\"" {
                guard let s = basicString() else { return nil }
                parts.append(s)
            } else if c == "'" {
                guard let s = literalString() else { return nil }
                parts.append(s)
            } else {
                var s = ""
                while let c = peek, c.isASCII, c.isLetter || c.isNumber || c == "_" || c == "-" { s.append(c); i += 1 }
                guard !s.isEmpty else { return nil }
                parts.append(s)
            }
            skipSpaces()
            guard peek == "." else { return parts }
            i += 1
        }
    }

    private mutating func value() -> Any? {
        guard let c = peek else { return nil }
        switch c {
        case "\"": return peek(1) == "\"" && peek(2) == "\"" ? multiline(literal: false) : basicString()
        case "'": return peek(1) == "'" && peek(2) == "'" ? multiline(literal: true) : literalString()
        case "[": return array()
        case "{": return inlineTable()
        default:
            var raw = ""
            while let c = peek, !Self.terminators.contains(c) { raw.append(c); i += 1 }
            if raw == "true" { return true }
            if raw == "false" { return false }
            guard !raw.isEmpty else { return nil }
            let number = raw.replacingOccurrences(of: "_", with: "")
            if let int = Int(number) { return int }
            if let double = Double(number) { return double }
            return raw
        }
    }

    private mutating func basicString() -> String? {
        i += 1
        var out = ""
        while let c = peek {
            if c == "\n" || c == "\r\n" { return nil }
            i += 1
            if c == "\"" { return out }
            if c == "\\" {
                guard let escaped = escape() else { return nil }
                out += escaped
            } else {
                out.append(c)
            }
        }
        return nil
    }

    private mutating func literalString() -> String? {
        i += 1
        var out = ""
        while let c = peek {
            if c == "\n" || c == "\r\n" { return nil }
            i += 1
            if c == "'" { return out }
            out.append(c)
        }
        return nil
    }

    private mutating func multiline(literal: Bool) -> String? {
        let quote: Character = literal ? "'" : "\""
        i += 3
        if peek == "\n" || peek == "\r\n" { i += 1 }
        var out = ""
        while let c = peek {
            if c == quote {
                var run = 0
                while peek(run) == quote { run += 1 }
                if run >= 3 {
                    out += String(repeating: quote, count: min(run - 3, 2))
                    i += run
                    return out
                }
                out += String(repeating: quote, count: run)
                i += run
                continue
            }
            i += 1
            if !literal, c == "\\" {
                // A backslash at the end of a line trims the newline and leading whitespace.
                if let next = peek, next.isWhitespace {
                    var j = i
                    while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
                    if j < chars.count, chars[j].isNewline {
                        i = j
                        while let n = peek, n.isWhitespace { i += 1 }
                        continue
                    }
                }
                guard let escaped = escape() else { return nil }
                out += escaped
            } else {
                out.append(c)
            }
        }
        return nil
    }

    /// Reads the character after a backslash.
    private mutating func escape() -> String? {
        guard let c = peek else { return nil }
        i += 1
        switch c {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        case "e": return "\u{1B}"
        case "\"": return "\""
        case "\\": return "\\"
        case "u", "U":
            let length = c == "u" ? 4 : 8
            guard i + length <= chars.count, let code = UInt32(String(chars[i..<i + length]), radix: 16),
                  let scalar = Unicode.Scalar(code) else { return nil }
            i += length
            return String(Character(scalar))
        default: return nil
        }
    }

    private mutating func array() -> [Any]? {
        i += 1
        var out: [Any] = []
        while true {
            skipBlank()
            if peek == "]" { i += 1; return out }
            guard let v = value() else { return nil }
            out.append(v)
            skipBlank()
            if peek == "," { i += 1; continue }
            if peek == "]" { i += 1; return out }
            return nil
        }
    }

    private mutating func inlineTable() -> [String: Any]? {
        i += 1
        var out: [String: Any] = [:]
        while true {
            skipBlank()
            if peek == "}" { i += 1; return out }
            guard let path = keyPath() else { return nil }
            skipSpaces()
            guard peek == "=" else { return nil }
            i += 1
            skipSpaces()
            guard let v = value() else { return nil }
            Self.set(&out, path, v)
            skipBlank()
            if peek == "," { i += 1; continue }
            if peek == "}" { i += 1; return out }
            return nil
        }
    }

    private static func set(_ dict: inout [String: Any], _ path: [String], _ value: Any) {
        guard let first = path.first else { return }
        if path.count == 1 { dict[first] = value; return }
        var child = dict[first] as? [String: Any] ?? [:]
        set(&child, Array(path.dropFirst()), value)
        dict[first] = child
    }

    private static func ensureTable(_ dict: inout [String: Any], _ path: [String]) {
        guard let first = path.first else { return }
        var child = dict[first] as? [String: Any] ?? [:]
        ensureTable(&child, Array(path.dropFirst()))
        dict[first] = child
    }
}

// MARK: - Page

struct AgentExtensionsPage: View {
    @Bindable var store: AppStore
    @State private var tab: Tab
    @State private var worthALookOnly = false

    init(store: AppStore, tab: Tab = .servers) {
        self.store = store
        _tab = State(initialValue: tab)
    }

    enum Tab: String, CaseIterable, Identifiable {
        case servers = "MCP Servers"
        case skills = "Skills & Plugins"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Plugins & Skills",
                subtitle: "What your agents can use, what each one runs, and anything worth a second look.",
                updatedAt: store.extensions.updatedAt, isFetching: store.extensions.isFetching, error: store.extensions.error,
                refresh: { store.extensions.refresh() }
            )

            Picker("Show", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            if let report = store.extensions.value {
                content(report)
            } else if store.extensions.isFetching || store.extensions.error == nil {
                EmptyState(symbol: "puzzlepiece.extension", title: "Looking…", message: "Checking what your agents have been given.")
            } else {
                EmptyState(symbol: "puzzlepiece.extension", title: "No scan yet", message: "Click the refresh button to look again.")
            }
        }
        .onAppear { store.extensions.refreshIfStale() }
    }

    @ViewBuilder
    private func content(_ report: AgentExtensionsReport) -> some View {
        let all = tab == .servers ? report.servers : report.skillsAndPlugins
        let flagged = all.filter(\.isWorthALook)
        let agents = Set(all.map(\.agent)).count
        let across = agents > 1 ? " · across \(agents) agents" : ""

        Hero(value: heroValue(all), caption: heroCaption(all, flagged: flagged.count) + across) {
            Toggle("Only what's worth a look", isOn: $worthALookOnly)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(all.isEmpty)
        }

        let shown = worthALookOnly ? flagged : all
        if all.isEmpty {
            if tab == .servers {
                EmptyState(symbol: "puzzlepiece.extension", title: "No MCP servers",
                           message: "None of your agents has been given extra tools. Servers you add to Claude Code, Codex, Cursor, Claude Desktop, VS Code, Windsurf or OpenCode show up here.")
            } else {
                EmptyState(symbol: "puzzlepiece.extension", title: "No skills or plugins",
                           message: "Skills and plugins you add to Claude Code or Codex show up here.")
            }
        } else if shown.isEmpty {
            EmptyState(symbol: "checkmark.shield", title: "Nothing worth a look",
                       message: tab == .servers
                           ? "No server runs unpinned code from the internet, keeps a key in plain text, or talks over an unencrypted connection."
                           : "None of your skills or plugins ships its own programs.")
        }

        ForEach(groups(shown), id: \.agent) { group in
            let everyAccount = Set(all.filter { $0.agent == group.agent }.flatMap(\.accounts))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    AgentLogo(agent: group.agent)
                    SectionLabel(title: group.agent, trailing: "\(group.items.count)")
                }
                Card {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        ExtensionRow(item: item, showAccounts: everyAccount.count > 1 && Set(item.accounts) != everyAccount)
                    }
                }
            }
        }
    }

    private func groups(_ items: [AgentExtension]) -> [(agent: String, items: [AgentExtension])] {
        var result: [(agent: String, items: [AgentExtension])] = []
        for item in items {
            if let i = result.firstIndex(where: { $0.agent == item.agent }) { result[i].items.append(item) }
            else { result.append((item.agent, [item])) }
        }
        return result
    }

    private func heroValue(_ items: [AgentExtension]) -> String {
        if tab == .servers { return count(items.count, "MCP server") }
        return count(items.filter { $0.kind == .skill }.count, "skill")
    }

    private func heroCaption(_ items: [AgentExtension], flagged: Int) -> String {
        if tab == .servers {
            let running = items.filter(\.isRunning).count
            return (flagged == 0 ? "Nothing worth a look" : "\(flagged) worth a look") + " · \(running) running now"
        }
        return count(items.filter { $0.kind == .plugin }.count, "plugin") + " · \(flagged) can run scripts"
    }

    private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

private struct AgentLogo: View {
    var agent: String

    var body: some View {
        if let id = AgentExtensions.logoIDs[agent],
           let descriptor = HarnessDescriptor.builtIns.first(where: { $0.id == id }),
           let image = ProviderLogos.image(for: descriptor, size: 13) {
            Image(nsImage: image).frame(width: 13, height: 13)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 13, height: 13)
        }
    }
}

private struct ExtensionRow: View {
    var item: AgentExtension
    var showAccounts: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(item.kind == .server && item.isWorthALook ? Color.orange : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.callout.weight(.medium)).foregroundStyle(item.isEnabled ? Color.label : .secondary).lineLimit(1)
                    if item.isRunning {
                        HStack(spacing: 3) {
                            Circle().fill(HealthBand.excellent.color).frame(width: 6, height: 6)
                            Text("Running now")
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("A process for this server is running right now.")
                    }
                    if !item.isEnabled { ExtensionTag(text: "Turned off", amber: false).help("Your agent won't start this until it's turned back on.") }
                }
                if let runs = item.command ?? item.url {
                    Text(runs)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(runs)
                        .textSelection(.enabled)
                }
                if let summary = item.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(summary)
                }
                Text(context).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                if !item.flags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(item.flags) { flag in
                            ExtensionTag(text: flag.title, amber: flag.isAmber).help(item.detail(flag))
                        }
                    }
                    ForEach(item.flags.filter(\.isAmber)) { flag in
                        Text(item.detail(flag)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button { Paths.reveal(item.kind == .server ? item.configPath : item.path) } label: { Image(systemName: "folder") }
                    .help("Show in Finder")
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: item.configPath)) } label: { Image(systemName: "doc.text") }
                    .help(openLabel)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show in Finder") { Paths.reveal(item.kind == .server ? item.configPath : item.path) }
            Button(openLabel) { NSWorkspace.shared.open(URL(fileURLWithPath: item.configPath)) }
            Button("Copy Path") { Paths.copy(item.kind == .server ? item.configPath : item.path) }
        }
    }

    private var symbol: String {
        switch item.kind {
        case .server: item.transport == .remote ? "globe" : "terminal"
        case .plugin: "puzzlepiece.extension"
        case .skill: "book.closed"
        }
    }

    private var openLabel: String {
        switch item.kind {
        case .server: "Open config"
        case .plugin: "Open plugin details"
        case .skill: "Open skill"
        }
    }

    private var context: String {
        var parts: [String] = []
        switch item.kind {
        case .server:
            parts.append(item.source == "Config" ? item.scope : "From \(item.source)" + (item.scope == "Global" ? "" : " · \(item.scope)"))
            parts.append(Paths.abbreviate(item.configPath))
            if !item.envNames.isEmpty { parts.append("Uses " + item.envNames.joined(separator: ", ")) }
        case .plugin:
            parts.append("Plugin" + (item.source.isEmpty ? "" : " from \(item.source)"))
            if item.scope != "Global" { parts.append(item.scope) }
            if item.skillCount > 0 { parts.append("\(item.skillCount) skill\(item.skillCount == 1 ? "" : "s")") }
            if item.serverCount > 0 { parts.append("\(item.serverCount) MCP server\(item.serverCount == 1 ? "" : "s")") }
        case .skill:
            parts.append(item.source == "Your skill" ? "Your skill" : "From \(item.source)")
            if item.scope != "Global" { parts.append(item.scope) }
            parts.append(Paths.abbreviate(item.path))
        }
        if showAccounts { parts.insert(item.accounts.joined(separator: ", "), at: 0) }
        return parts.joined(separator: " · ")
    }
}

private struct ExtensionTag: View {
    var text: String
    var amber: Bool

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(amber ? Color.orange : Color.secondary)
            .background((amber ? Color.orange : Color.primary).opacity(amber ? 0.14 : 0.07), in: Capsule())
    }
}
