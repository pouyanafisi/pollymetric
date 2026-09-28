import Darwin
import Foundation

/// Newline framing is shared by the local relay and MCP stdio. Never log frames.
final class MCPWire {
    let fd: Int32
    private var buffer = Data()
    init(_ fd: Int32) { self.fd = fd }

    /// The next line, at most `limit` bytes. With a `deadline`, the whole line must arrive
    /// by then, so a peer can't hold a connection open by trickling one byte at a time.
    func readLine(limit: Int = 4 * 1_024 * 1_024, deadline: Date? = nil) throws -> Data? {
        var scanned = buffer.startIndex
        while true {
            if let end = buffer[scanned...].firstIndex(of: 10) {
                guard buffer.distance(from: buffer.startIndex, to: end) <= limit else { throw MCPFailure(message: "Message too large.") }
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                return line
            }
            guard buffer.count <= limit else { throw MCPFailure(message: "Message too large.") }
            if let deadline, Date() > deadline { throw MCPFailure(message: "Timed out.") }
            scanned = buffer.endIndex // only search what arrives next
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                throw MCPFailure(message: "Connection closed.")
            }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    func write(_ data: Data) throws {
        var frame = data; frame.append(10)
        try frame.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MCPFailure(message: "Connection closed.") }
                offset += count
            }
        }
    }

    static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw MCPFailure(message: "Data folder path is too long for a local socket.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func configure(_ fd: Int32, timeout: Int = 0) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var interval = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        interval.tv_sec = 5
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout.size(ofValue: interval)))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func ownedPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }

    static func connect(path: String) throws -> Int32 {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              info.st_mode & S_IFMT == S_IFSOCK else { throw MCPFailure(message: "Pollymetric is not running, or its local socket is unavailable.") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPFailure(message: "Could not create local connection.") }
        configure(fd)
        do {
            let status = try address(path) { Darwin.connect(fd, $0, $1) }
            guard status == 0, ownedPeer(fd) else { throw MCPFailure(message: "Pollymetric is not running, or its local socket is unavailable.") }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
}

final class MCPSocketServer: @unchecked Sendable {
    typealias Authenticate = @Sendable (String) async -> Bool
    typealias Handler = @Sendable (String, Data, MCPSession) async -> Data?
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var lockFD: Int32 = -1
    private var peers = Set<Int32>()
    private let path: String

    init(directory: URL) { path = directory.appendingPathComponent("mcp.sock").path }

    func start(authenticate: @escaping Authenticate, handle: @escaping Handler) throws {
        lockFD = Darwin.open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw MCPFailure(message: "Could not open the local server lock.") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(lockFD); lockFD = -1
            throw MCPFailure(message: "Another Pollymetric instance is serving connections.")
        }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        // Bind privately, set permissions, then publish atomically. No world-readable interval.
        let staging = directory.appendingPathComponent(".mcp-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            let privatePath = staging.appendingPathComponent("s").path
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw MCPFailure(message: "Could not create local server.") }
            listener = fd; MCPWire.configure(fd)
            let bound = try MCPWire.address(privatePath) { Darwin.bind(fd, $0, $1) }
            guard bound == 0 else { throw MCPFailure(message: "Could not bind the local server socket (errno \(errno)).") }
            guard chmod(privatePath, 0o600) == 0, listen(fd, 16) == 0,
                  rename(privatePath, path) == 0 else { throw MCPFailure(message: "Could not publish the local server socket (errno \(errno)).") }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                while let self {
                    let peer = accept(fd, nil, nil)
                    if peer < 0 { if errno == EINTR { continue }; break }
                    self.lock.lock()
                    let allowed = self.listener == fd && self.peers.count < 32
                    if allowed { self.peers.insert(peer) }
                    self.lock.unlock()
                    guard allowed else { Darwin.close(peer); continue }
                    DispatchQueue.global(qos: .utility).async { [self] in
                        defer {
                            self.lock.lock(); self.peers.remove(peer); self.lock.unlock()
                            Darwin.close(peer)
                        }
                        self.serve(peer, authenticate: authenticate, handle: handle)
                    }
                }
            }
        } catch { stop(); throw error }
    }

    private func serve(_ fd: Int32, authenticate: @escaping Authenticate, handle: @escaping Handler) {
        MCPWire.configure(fd, timeout: 5)
        guard MCPWire.ownedPeer(fd) else { return }
        let wire = MCPWire(fd)
        do {
            // Before a valid token: one small line, within 10 seconds.
            guard let data = try wire.readLine(limit: 2_048, deadline: Date().addingTimeInterval(10)), let auth = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let token = auth["token"], token.utf8.count <= 1024 else { return }
            let hash = MCPToken.hash(token)
            let approved = blocking { await authenticate(hash) }
            try wire.write(MCPJSON.encode(["authenticated": approved]))
            guard approved else { return }
            MCPWire.configure(fd)
            let session = MCPSession()
            while let data = try wire.readLine() {
                let reply = blocking { await handle(hash, data, session) }
                if let reply { try wire.write(reply) }
            }
        } catch { /* Disconnects never include protocol data in logs. */ }
    }

    private func blocking<T>(_ work: @escaping @Sendable () async -> T) -> T {
        let ready = DispatchSemaphore(value: 0)
        var result: T!
        Task { result = await work(); ready.signal() }
        ready.wait()
        return result
    }

    func stop() {
        lock.lock()
        let fd = listener; listener = -1
        for peer in peers { shutdown(peer, SHUT_RDWR) }
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        if lockFD >= 0 {
            unlink(path); flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1
        }
    }
    deinit { stop() }
}

enum MCPShim {
    static func run() -> Int32 {
        do {
            guard let token = ProcessInfo.processInfo.environment["POLLYMETRIC_MCP_TOKEN"], !token.isEmpty else {
                throw MCPFailure(message: "Set POLLYMETRIC_MCP_TOKEN using Connections in Pollymetric.")
            }
            let fd = try MCPWire.connect(path: Lynis.dataDirectory.appendingPathComponent("mcp.sock").path)
            MCPWire.configure(fd, timeout: 5)
            let wire = MCPWire(fd)
            try wire.write(MCPJSON.encode(["token": token]))
            guard let reply = try wire.readLine(),
                  let auth = try JSONSerialization.jsonObject(with: reply) as? [String: Bool], auth["authenticated"] == true else {
                Darwin.close(fd); throw MCPFailure(message: "Pairing was rejected. Create a new connection in Pollymetric.")
            }
            MCPWire.configure(fd)
            DispatchQueue.global().async {
                do {
                    let output = MCPWire(STDOUT_FILENO)
                    while let line = try wire.readLine() { try output.write(line) }
                    exit(0)
                } catch { exit(1) }
            }
            let input = MCPWire(STDIN_FILENO)
            while let line = try input.readLine() { try wire.write(line) }
            shutdown(fd, SHUT_WR)
            dispatchMain()
        } catch {
            // A clear protocol error works even for clients that discard stderr.
            if let data = try? MCPJSON.encode(MCPJSON.error(id: NSNull(), message: error.localizedDescription)) {
                try? MCPWire(STDOUT_FILENO).write(data)
            }
            return 1
        }
    }
}
