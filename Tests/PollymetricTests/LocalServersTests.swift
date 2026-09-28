import Darwin
import HarnessKit
import XCTest
@testable import Pollymetric

final class LocalServersTests: XCTestCase {
    func testReachFromAddress() {
        XCTAssertEqual(LocalServers.reach(of: "127.0.0.1"), .thisMac)
        XCTAssertEqual(LocalServers.reach(of: "127.0.0.53"), .thisMac)
        XCTAssertEqual(LocalServers.reach(of: "::1"), .thisMac)
        XCTAssertEqual(LocalServers.reach(of: "::ffff:127.0.0.1"), .thisMac)
        XCTAssertEqual(LocalServers.reach(of: "0.0.0.0"), .network)
        XCTAssertEqual(LocalServers.reach(of: "::"), .network)
        XCTAssertEqual(LocalServers.reach(of: "192.168.1.20"), .network)
        XCTAssertEqual(LocalServers.reach(of: "100.119.241.24"), .network)
        XCTAssertEqual(LocalServers.reach(of: "fe80::1%en0"), .network)
        XCTAssertEqual(LocalServers.reach(of: "::ffff:10.0.0.2"), .network)
    }

    func testHostShownAndOpened() {
        XCTAssertEqual(LocalServers.host(for: ["127.0.0.1"]), "localhost")
        XCTAssertEqual(LocalServers.host(for: ["0.0.0.0", "::"]), "localhost")
        XCTAssertEqual(LocalServers.host(for: ["192.168.1.20"]), "192.168.1.20")
        XCTAssertEqual(LocalServers.host(for: ["fe80::1"]), "[fe80::1]")
    }

    func testMergeDedupesIPv4AndIPv6AndSharedSockets() {
        let merged = LocalServers.merge([
            .init(pid: 20, port: 5432, address: "127.0.0.1", socket: 1, start: 5),
            .init(pid: 20, port: 5432, address: "::1", socket: 2, start: 5),
            // php-fpm: a master and its workers hold one inherited socket.
            .init(pid: 31, port: 9000, address: "127.0.0.1", socket: 9, start: 50),
            .init(pid: 30, port: 9000, address: "127.0.0.1", socket: 9, start: 40),
            .init(pid: 32, port: 9000, address: "127.0.0.1", socket: 9, start: 60),
            .init(pid: 40, port: 3000, address: "::", socket: 3, start: 1),
            .init(pid: 40, port: 3000, address: "0.0.0.0", socket: 4, start: 1),
        ])
        XCTAssertEqual(merged, [
            .init(pid: 40, port: 3000, addresses: ["0.0.0.0", "::"]),
            .init(pid: 20, port: 5432, addresses: ["127.0.0.1", "::1"]),
            .init(pid: 30, port: 9000, addresses: ["127.0.0.1"]),
        ])
    }

    func testStarterFromParentChain() {
        let agents = LocalServers.agentNames(HarnessDescriptor.builtIns)
        XCTAssertEqual(agents["claude"], "Claude Code")
        XCTAssertEqual(agents["cursor-agent"], "Cursor Agent")

        func starter(_ name: String, _ chain: [String], exe: String?, appPath: String? = nil, app: String? = nil) -> LocalServer.Starter {
            LocalServers.starter(name: name, chain: chain, executable: exe, appPath: appPath, app: app, agents: agents)
        }
        // A dev server Claude Code started in iTerm2.
        XCTAssertEqual(starter("node", ["node", "zsh", "claude", "zsh", "login", "iTermServer"], exe: "/opt/homebrew/bin/node", app: "iTerm2"),
                       .agent("Claude Code"))
        XCTAssertEqual(starter("python3", ["zsh", "codex"], exe: "/usr/bin/python3", app: "iTerm2"), .agent("Codex"))
        XCTAssertEqual(starter("opencode", [], exe: "/Users/me/.opencode/bin/opencode"), .agent("OpenCode"))
        // The same python3 from your own terminal is yours, not macOS's.
        XCTAssertEqual(starter("python3", ["zsh", "login", "iTermServer"], exe: "/usr/bin/python3", app: "iTerm2"), .app("iTerm2"))
        // macOS's own listeners.
        XCTAssertEqual(starter("ControlCenter", [], exe: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
                               appPath: "/System/Library/CoreServices/ControlCenter.app", app: "Control Center"), .macOS)
        XCTAssertEqual(starter("rapportd", [], exe: "/usr/libexec/rapportd"), .macOS)
        // Homebrew services on Intel live under /usr/local, which isn't macOS.
        XCTAssertEqual(starter("postgres", [], exe: "/usr/local/opt/postgresql/bin/postgres"), .background)
        XCTAssertEqual(starter("Spotify", [], exe: "/Applications/Spotify.app/Contents/MacOS/Spotify",
                               appPath: "/Applications/Spotify.app", app: "Spotify"), .app("Spotify"))
    }

    func testOriginLine() {
        var server = LocalServer(pid: 1, port: 3000, address: "localhost", starter: .agent("Claude Code"))
        server.identity = identity(label: "next dev", context: "storefront", app: "iTerm2", appPath: "/Applications/iTerm.app",
                                   executable: "/opt/homebrew/bin/node")
        XCTAssertEqual(server.what, "next dev in storefront")
        XCTAssertEqual(server.origin, "started by Claude Code in iTerm2")
        server.starter = .app("iTerm2")
        XCTAssertEqual(server.origin, "started in iTerm2")
        server.identity = identity(label: "Spotify", context: nil, app: "Spotify", appPath: "/Applications/Spotify.app",
                                   executable: "/Applications/Spotify.app/Contents/MacOS/Spotify")
        server.starter = .app("Spotify")
        XCTAssertEqual(server.origin, "part of Spotify")
        XCTAssertEqual(server.what, "Spotify")
        server.port = 4173
        server.identity = identity(label: "http.server 4173", context: "site", app: nil, appPath: nil, executable: "/usr/bin/python3")
        XCTAssertEqual(server.what, "http.server in site")
    }

    func testUptime() {
        let now = Date()
        XCTAssertEqual(LocalServers.uptime(since: now.addingTimeInterval(-20), now: now), "just started")
        XCTAssertEqual(LocalServers.uptime(since: now.addingTimeInterval(-60), now: now), "up 1 minute")
        XCTAssertEqual(LocalServers.uptime(since: now.addingTimeInterval(-45 * 60), now: now), "up 45 minutes")
        XCTAssertEqual(LocalServers.uptime(since: now.addingTimeInterval(-5 * 3_600), now: now), "up 5 hours")
        XCTAssertEqual(LocalServers.uptime(since: now.addingTimeInterval(-3 * 86_400 - 7_200), now: now), "up 3 days")
        XCTAssertEqual(LocalServers.uptime(since: now.addingTimeInterval(60), now: now), "just started")
    }

    /// A real listener in this process shows up in a scan, attributed and on this Mac only.
    func testScanFindsOwnLoopbackListener() async throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(fd, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: address.sin_port))

        let started = Date()
        let report = try await LocalServers.scan()
        let elapsed = Date().timeIntervalSince(started)
        let mine = (report.servers + report.system).first { $0.pid == getpid() && $0.port == port }
        XCTAssertNotNil(mine)
        XCTAssertEqual(mine?.reach, .thisMac)
        XCTAssertEqual(mine?.address, "localhost")
        XCTAssertEqual(mine?.addresses, ["127.0.0.1"])
        XCTAssertNotNil(mine?.identity)
        XCTAssertTrue(mine.map(LocalServers.isSameProcess) ?? false)
        XCTAssertLessThan(elapsed, 2, "a scan should stay cheap enough to run every 20 seconds")
    }

    private func identity(label: String, context: String?, app: String?, appPath: String?, executable: String?) -> ProcessIdentity {
        ProcessIdentity(key: "1-1", pid: 1, startedAt: .now, name: label, label: label, context: context, via: nil, app: app,
                        appPath: appPath, executable: executable, command: label, cwd: nil, chain: [])
    }
}
