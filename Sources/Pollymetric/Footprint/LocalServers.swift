import AppKit
import Darwin
import HarnessKit
import SwiftUI

/// Everything listening for connections on this Mac: which process, which port, who
/// started it, and whether other machines on the network can reach it.
struct LocalServersReport: Codable, Sendable, Equatable {
    /// Yours: started by an agent, an app, or in the background. macOS's own are kept
    /// apart so the sidebar count only shows things you might want to stop.
    var servers: [LocalServer] = []
    var system: [LocalServer] = []
}

struct LocalServer: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(pid):\(port)" }
    var pid: Int32
    var port: Int
    /// The host to show and open: "localhost", or the one address it's bound to.
    var address: String
    /// Every address it listens on, IPv4 and IPv6 merged.
    var addresses: [String] = []
    var reach: Reach = .thisMac
    var starter: Starter = .background
    var identity: ProcessIdentity?
    var memoryBytes: Int64 = 0
    /// Its agent has quit and it's still running: the forgotten dev server.
    var leftRunning = false

    enum Reach: String, Codable, Sendable { case thisMac, network }

    /// Who started it, which is how the page groups servers.
    enum Starter: Codable, Sendable, Hashable {
        case agent(String)   // the harness's display name, e.g. "Claude Code"
        case app(String)
        case background      // launched on its own, e.g. a Homebrew service
        case macOS

        /// No live agent above it, but one may have started it and quit.
        var mayBeOrphan: Bool {
            switch self {
            case .app, .background: true
            case .agent, .macOS: false
            }
        }
    }

    /// Loopback reads as "localhost", the way people type it.
    var hostAndPort: String { "\(["127.0.0.1", "::1"].contains(address) ? "localhost" : address):\(port)" }
    var url: URL? { URL(string: "http://\(address):\(port)") }

    /// "next dev in storefront".
    var what: String {
        guard let identity else { return "PID \(pid)" }
        // `python3 -m http.server 4173` is labelled "http.server 4173"; the port is already shown.
        var label = identity.label
        if label.hasSuffix(" \(port)") { label.removeLast(" \(port)".count) }
        return identity.context.map { "\(label) in \($0)" } ?? label
    }

    /// "started by Claude Code in iTerm2".
    var origin: String {
        let app = identity?.app
        switch starter {
        case .agent(let agent) where leftRunning: return "\(agent) has quit; this is still running"
        case .agent(let agent): return app.map { $0 == agent ? "started by \(agent)" : "started by \(agent) in \($0)" } ?? "started by \(agent)"
        case .app(let name):
            // Its own executable inside the bundle means it's part of the app, not run from it.
            if let exe = identity?.executable, let bundle = identity?.appPath, exe.hasPrefix(bundle + "/") { return "part of \(name)" }
            return "started in \(name)"
        case .background: return "runs in the background"
        case .macOS: return "part of macOS"
        }
    }
}

enum LocalServers {
    /// One listening socket as the kernel reports it, before merging.
    struct Listener: Equatable, Sendable {
        var pid: Int32
        var port: Int
        var address: String
        var socket: UInt64       // the kernel socket, shared by processes that inherited it
        var start: UInt64 = 0    // process start time, to keep the oldest holder of a shared socket
    }

    struct Merged: Equatable, Sendable {
        var pid: Int32
        var port: Int
        var addresses: [String]
    }

    static func scan(history: HistoryStore = .shared, agents: [String: String]? = nil) async throws -> LocalServersReport {
        let merged = merge(listeners())
        guard !merged.isEmpty else { return LocalServersReport() }

        let agents = agents ?? agentNames(HarnessRegistry.load().descriptors)
        let resolver = IdentityResolver()
        var servers: [LocalServer] = []
        for entry in merged {
            guard let usage = rusage(entry.pid) else { continue }
            let name = IdentityResolver.name(pid: entry.pid) ?? "pid \(entry.pid)"
            let identity = resolver.identity(pid: entry.pid, start: usage.start, name: name)
            var server = LocalServer(
                pid: entry.pid, port: entry.port,
                address: host(for: entry.addresses), addresses: entry.addresses,
                reach: entry.addresses.contains { reach(of: $0) == .network } ? .network : .thisMac,
                starter: starter(name: identity.name, chain: identity.chain, executable: identity.executable,
                                 appPath: identity.appPath, app: identity.app, agents: agents),
                identity: identity,
                memoryBytes: usage.footprint
            )
            if server.starter.mayBeOrphan, let agent = interpretedAgent(above: entry.pid, chain: identity.chain, agents: agents) {
                server.starter = .agent(agent)
            }
            servers.append(server)
        }

        // An agent that quit leaves its servers parented to launchd. If the process history
        // recorded this same process (pid and start time) while the agent was still its
        // parent, that's who started it. One query, for those servers only.
        let orphans = servers.filter(\.starter.mayBeOrphan).compactMap(\.identity?.key)
        if !orphans.isEmpty {
            let recorded = await history.chains(forKeys: orphans)
                .compactMapValues { chain in chain.lazy.compactMap { agents[$0] }.first }
            servers = attributeLeftRunning(servers, recorded: recorded)
        }

        var report = LocalServersReport()
        for server in servers {
            if server.starter == .macOS { report.system.append(server) } else { report.servers.append(server) }
        }
        return report
    }

    /// Marks servers whose agent has quit, given process key → agent recorded earlier.
    static func attributeLeftRunning(_ servers: [LocalServer], recorded: [String: String]) -> [LocalServer] {
        servers.map { server in
            guard server.starter.mayBeOrphan, let key = server.identity?.key, let agent = recorded[key] else { return server }
            var server = server
            server.starter = .agent(agent)
            server.leftRunning = true
            return server
        }
    }

    /// An agent run by an interpreter shows up in the parent chain as "node". Its script
    /// path names it: `node ~/.local/share/cursor-agent/…/index.js`, or
    /// `node …/node_modules/@anthropic-ai/claude-code/cli.js`. Only installed-tool
    /// locations count (under node_modules or a hidden folder), so a project folder that
    /// happens to be called "codex" doesn't.
    static func agent(inArguments arguments: [String], agents: [String: String]) -> String? {
        guard let program = arguments.first.map({ ($0 as NSString).lastPathComponent.lowercased() }),
              ProcessDescriber.isInterpreter(program),
              let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return nil }
        let parts = script.split(separator: "/").map(String.init)
        guard let anchor = parts.firstIndex(where: { $0 == "node_modules" || ($0.hasPrefix(".") && $0.count > 1 && $0 != "..") })
        else { return nil }
        return parts[(anchor + 1)...].lazy.compactMap { agents[$0] }.first
    }

    /// Reads arguments only of interpreter ancestors, and only when the chain has one.
    private static func interpretedAgent(above pid: Int32, chain: [String], agents: [String: String]) -> String? {
        guard chain.contains(where: { ProcessDescriber.isInterpreter($0.lowercased()) }) else { return nil }
        var current = pid
        for _ in 0..<12 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return nil }
            current = Int32(info.pbi_ppid)
            guard let name = IdentityResolver.name(pid: current), ProcessDescriber.isInterpreter(name.lowercased()) else { continue }
            if let agent = agent(inArguments: IdentityResolver.arguments(pid: current).1, agents: agents) { return agent }
        }
        return nil
    }

    // MARK: Classification (pure)

    /// Wildcard (0.0.0.0, ::) or any non-loopback address can be reached from other
    /// machines, firewall permitting. Only loopback stays on this Mac.
    static func reach(of address: String) -> LocalServer.Reach {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return UInt32(bigEndian: v4.s_addr) >> 24 == 127 ? .thisMac : .network
        }
        var v6 = in6_addr()
        let bare = address.split(separator: "%").first.map(String.init) ?? address   // drop a zone like %lo0
        guard inet_pton(AF_INET6, bare, &v6) == 1 else { return .network }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return .thisMac }                // ::1
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {          // ::ffff:a.b.c.d
            return bytes[12] == 127 ? .thisMac : .network
        }
        return .network
    }

    /// The host people type: "localhost" when it answers there (loopback or wildcard),
    /// otherwise the one address it's bound to.
    static func host(for addresses: [String]) -> String {
        let wildcard: Set<String> = ["0.0.0.0", "::", "*"]
        if addresses.isEmpty || addresses.contains(where: { wildcard.contains($0) || reach(of: $0) == .thisMac }) { return "localhost" }
        let first = addresses.sorted()[0]
        return first.contains(":") ? "[\(first)]" : first
    }

    /// Collapses the kernel's view into one entry per process and port. Processes that
    /// inherited the same socket (php-fpm workers, forked servers) count once, under the
    /// oldest; a server listening on both IPv4 and IPv6 is one server.
    static func merge(_ listeners: [Listener]) -> [Merged] {
        var holder: [UInt64: Listener] = [:]
        for l in listeners {
            if let existing = holder[l.socket], (existing.start, existing.pid) <= (l.start, l.pid) { continue }
            holder[l.socket] = l
        }
        var byKey: [String: Merged] = [:]
        for l in holder.values {
            let key = "\(l.pid):\(l.port)"
            var entry = byKey[key] ?? Merged(pid: l.pid, port: l.port, addresses: [])
            if !entry.addresses.contains(l.address) { entry.addresses.append(l.address) }
            byKey[key] = entry
        }
        return byKey.values
            .map { var m = $0; m.addresses.sort(); return m }
            .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Executable name (and harness id, which is how its package folder is often named)
    /// → harness name, e.g. "claude" and "claude-code" → "Claude Code".
    static func agentNames(_ descriptors: [HarnessDescriptor]) -> [String: String] {
        var names: [String: String] = [:]
        for descriptor in descriptors {
            for exe in descriptor.executables + [descriptor.id] where names[exe] == nil { names[exe] = descriptor.name }
        }
        return names
    }

    /// Macs ship these listening; they're not something to stop.
    static let macOSNames: Set<String> = [
        "ControlCenter", "rapportd", "sharingd", "AirPlayXPCHelper", "AirPlayUIAgent", "remoted",
        "identityservicesd", "UserEventAgent", "WiFiAgent", "screensharingd", "ARDAgent",
    ]

    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/", "/Library/Apple/"]

    /// Who started it. An agent anywhere in the parent chain (or the agent itself) wins,
    /// so `python3 -m http.server` run by Claude Code groups under Claude Code even
    /// though python3 ships with macOS.
    static func starter(name: String, chain: [String], executable: String?, appPath: String?, app: String?,
                        agents: [String: String]) -> LocalServer.Starter {
        if let agent = ([name] + chain).lazy.compactMap({ agents[$0] }).first { return .agent(agent) }
        if macOSNames.contains(name) { return .macOS }
        let systemBinary = executable.map { exe in systemPrefixes.contains { exe.hasPrefix($0) } } ?? (app == nil)
        // A system binary only counts as macOS when macOS itself launched it: /usr/bin/python3
        // run from your terminal is yours.
        if systemBinary, chain.isEmpty || appPath?.hasPrefix("/System/") == true { return .macOS }
        if let app { return .app(app) }
        return .background
    }

    /// "up 3 days". Long-running servers are the ones people forget.
    static func uptime(since start: Date, now: Date = .now) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        func unit(_ n: Int, _ word: String) -> String { "up \(n) \(word)\(n == 1 ? "" : "s")" }
        switch seconds {
        case ..<60: return "just started"
        case ..<3_600: return unit(Int(seconds / 60), "minute")
        case ..<86_400: return unit(Int(seconds / 3_600), "hour")
        default: return unit(Int(seconds / 86_400), "day")
        }
    }

    // MARK: libproc

    /// Every listening TCP socket in processes you own. About 10 ms for ~1,500 processes:
    /// one call per process lists its descriptors, and only sockets get a second look.
    static func listeners() -> [Listener] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 1_024)
        var result: [Listener] = []

        for pid in allPIDs() where pid > 0 {
            var bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
            guard bytes > 0 else { continue }   // not yours, or gone
            if Int(bytes) >= fds.count * stride {
                // A full buffer may be truncated: ask for the real size and read again.
                let needed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)) / stride
                fds = [proc_fdinfo](repeating: proc_fdinfo(), count: max(needed + 64, fds.count * 2))
                bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
                guard bytes > 0 else { continue }
            }
            var start: UInt64?
            for fd in fds.prefix(Int(bytes) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let size = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                      info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
                let tcp = info.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                let ini = tcp.tcpsi_ini
                let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
                if start == nil { start = rusage(pid)?.start ?? 0 }
                result.append(Listener(pid: pid, port: port, address: address(ini), socket: info.psi.soi_so, start: start ?? 0))
            }
        }
        return result
    }

    private static func address(_ ini: in_sockinfo) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ini.insi_vflag & UInt8(INI_IPV6) != 0 {
            var v6 = ini.insi_laddr.ina_6
            guard inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil else { return "::" }
        } else {
            var v4 = ini.insi_laddr.ina_46.i46a_addr4
            guard inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil else { return "0.0.0.0" }
        }
        return String(cString: buffer)
    }

    /// Start time (the same one `ProcessIdentity.key` uses) and memory footprint.
    static func rusage(_ pid: Int32) -> (start: UInt64, footprint: Int64)? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? (info.ri_proc_start_abstime, Int64(info.ri_phys_footprint)) : nil
    }

    /// True while the PID still belongs to the process that was scanned, not a new one
    /// that reused the number.
    static func isSameProcess(_ server: LocalServer) -> Bool {
        guard let key = server.identity?.key, let usage = rusage(server.pid) else { return false }
        return key == "\(server.pid)-\(usage.start)"
    }

    private static func allPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return Array(pids.prefix(Int(max(0, count))))
    }
}

// MARK: Page

struct LocalServersPage: View {
    @Bindable var store: AppStore
    @State private var showMacOS = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "Local Servers", subtitle: "Servers you started, who started them, and whether other machines can reach them.",
                       updatedAt: store.servers.updatedAt, isFetching: store.servers.isFetching, error: store.servers.error,
                       refresh: { store.servers.refresh() })

            if let report = store.servers.value {
                let servers = report.servers
                if servers.isEmpty {
                    EmptyState(symbol: "network", title: "Nothing is listening",
                               message: "No servers you started are running right now. Dev servers and tools your agents start will show up here.")
                } else {
                    Hero(value: servers.count == 1 ? "1 server" : "\(servers.count) servers", caption: caption(servers)) { EmptyView() }
                    ForEach(groups(servers), id: \.title) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            GroupLabel(title: group.title, agent: group.agent, count: group.servers.count)
                            Card {
                                ForEach(Array(group.servers.enumerated()), id: \.element.id) { index, server in
                                    if index > 0 { Divider() }
                                    LocalServerRow(server: server, store: store)
                                }
                            }
                        }
                    }
                }
                if !report.system.isEmpty {
                    DisclosureGroup(isExpanded: $showMacOS) {
                        Card {
                            ForEach(Array(report.system.enumerated()), id: \.element.id) { index, server in
                                if index > 0 { Divider() }
                                LocalServerRow(server: server, store: store)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        SectionLabel(title: "macOS", trailing: "\(report.system.count)")
                    }
                }
            } else if store.servers.isFetching {
                EmptyState(symbol: "network", title: "Looking…", message: "Checking what's listening on this Mac.")
            } else {
                EmptyState(symbol: "network", title: "No scan yet", message: "Click the refresh button to look.")
            }
        }
        .onAppear { store.servers.refreshIfStale() }
    }

    /// "1 open to your network · 3 started by Claude Code and Codex".
    private func caption(_ servers: [LocalServer]) -> String {
        let open = servers.filter { $0.reach == .network }.count
        var parts = [open == 0 ? "All reachable only from this Mac" : "\(open) open to your network"]
        var agents: [String] = []
        var byAgents = 0
        for server in servers {
            guard case .agent(let name) = server.starter else { continue }
            byAgents += 1
            if !agents.contains(name) { agents.append(name) }
        }
        if byAgents > 0 {
            let names = agents.count <= 2 ? agents.sorted().joined(separator: " and ") : "\(agents.count) agents"
            parts.append("\(byAgents) started by \(names)")
        }
        let left = servers.filter(\.leftRunning).count
        if left > 0 { parts.append("\(left) left running") }
        return parts.joined(separator: " · ")
    }

    private struct Group { var title: String; var agent: String?; var rank: Int; var servers: [LocalServer] }

    /// Agents first, then apps, then background services, each alphabetical.
    private func groups(_ servers: [LocalServer]) -> [Group] {
        var groups: [String: Group] = [:]
        for server in servers {
            let (title, agent, rank): (String, String?, Int) = switch server.starter {
            case .agent(let name): ("Started by \(name)", name, 0)
            case .app(let name): (name, nil, 1)
            case .background, .macOS: ("In the background", nil, 2)
            }
            groups[title, default: Group(title: title, agent: agent, rank: rank, servers: [])].servers.append(server)
        }
        return groups.values.sorted { ($0.rank, $0.title) < ($1.rank, $1.title) }
    }
}

private struct GroupLabel: View {
    var title: String
    var agent: String?
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            if let agent, let harness = ProviderLogos.installation(named: agent) {
                ProviderLogo(harness: harness, size: 12)
            }
            SectionLabel(title: title, trailing: "\(count)")
        }
    }
}

struct LocalServerRow: View {
    var server: LocalServer
    var store: AppStore

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(server.hostAndPort).font(.callout.weight(.semibold).monospacedDigit())
                    Text(server.what).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if server.leftRunning {
                        tag("Left running", help: "The agent that started it has quit, and it's still running.")
                    }
                    if server.reach == .network, server.starter != .macOS {
                        tag("Open to your network", help: "Other devices on your network can connect to it, unless your firewall blocks them.")
                    }
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let url = server.url {
                Button("Open") { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
            if server.starter != .macOS {
                Button("Quit…") { quit() }.controlSize(.small)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(server.identity?.command ?? server.what)
        .contextMenu {
            if let key = server.identity?.groupKey {
                Button("Show in Processes") {
                    store.inspectGroup(key, context: server.identity?.cwd)
                    store.dashboardSection = .processes
                }
            }
            if let command = server.identity?.command { Button("Copy Command") { Paths.copy(command) } }
            if let cwd = server.identity?.cwd, cwd != "/" { Button("Open Folder") { Paths.reveal(cwd) } }
            Button("Copy Address") { Paths.copy(server.url?.absoluteString ?? server.hostAndPort) }
        }
    }

    private func tag(_ text: String, help: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .fixedSize()
            .help(help)
    }

    /// "started by Claude Code in iTerm2 · up 3 days · 240 MB". Uptime is worked out when
    /// the row draws, which happens on each scan, not on a timer.
    private var details: String {
        var parts = [server.origin]
        if let started = server.identity?.startedAt { parts.append(LocalServers.uptime(since: started)) }
        if server.memoryBytes > 0 { parts.append(Bytes.format(server.memoryBytes)) }
        return parts.joined(separator: " · ")
    }

    private func quit() {
        let name = server.identity?.label ?? "PID \(server.pid)"
        let alert = NSAlert()
        alert.messageText = "Quit \(name) on port \(server.port)?"
        alert.informativeText = "It's \(server.what), \(server.origin). Anything using \(server.hostAndPort) will stop working, and unsaved work in it may be lost."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // The number may belong to a different process by now.
        guard server.pid != getpid(), LocalServers.isSameProcess(server) else {
            store.servers.refresh()
            return
        }
        store.patterns.record(.processQuit, target: server.identity?.groupKey, context: server.identity?.cwd)
        ProcessList.quit(ProcessRow(pid: server.pid, name: name, cpu: 0, memoryBytes: server.memoryBytes, identity: server.identity))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [store] in
            store.servers.refresh()
            store.monitor.sampleNow()
        }
    }
}
