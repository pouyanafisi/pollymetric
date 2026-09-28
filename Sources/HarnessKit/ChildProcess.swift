import Darwin
import Foundation

/// A child process that can be launched "disclaimed": macOS then treats it as responsible
/// for itself instead of attributing its file access to the app that started it.
///
/// That matters for an app with Full Disk Access. A normal child inherits it, so anything
/// that can change what the child runs (a line in ~/.zshrc, a package in a user-owned
/// PATH folder, a harness command in ~/.config) would get Full Disk Access too. Disclaimed
/// children get only what they'd have if you ran them yourself. Terminals like iTerm2 and
/// editors like VS Code launch shells and tasks the same way.
///
/// The subset of `Process` the app uses: pipes or /dev/null for stdio, a working folder,
/// terminate, and a termination handler.
public final class ChildProcess: @unchecked Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public var currentDirectory: String?
    public var standardInput: Pipe?
    public var standardOutput: Pipe?
    public var standardError: Pipe?
    public let disclaim: Bool
    public var terminationHandler: (@Sendable (ChildProcess) -> Void)?

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var running = false
    private var status: Int32 = 0
    private let exited = DispatchSemaphore(value: 0)

    public init(executable: String, arguments: [String], environment: [String: String], disclaim: Bool) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.disclaim = disclaim
    }

    public var processIdentifier: pid_t { lock.withLock { pid } }
    public var isRunning: Bool { lock.withLock { running } }
    /// The exit code, or the signal number if a signal ended it (as `Process` reports it).
    public var terminationStatus: Int32 { lock.withLock { status } }

    public func run() throws {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        func wire(_ pipe: Pipe?, to target: Int32, reading: Bool) {
            if let pipe {
                let end = reading ? pipe.fileHandleForReading : pipe.fileHandleForWriting
                posix_spawn_file_actions_adddup2(&actions, end.fileDescriptor, target)
            } else {
                posix_spawn_file_actions_addopen(&actions, target, "/dev/null", reading ? O_RDONLY : O_WRONLY, 0)
            }
        }
        wire(standardInput, to: 0, reading: true)
        wire(standardOutput, to: 1, reading: false)
        wire(standardError, to: 2, reading: false)
        if let currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, currentDirectory) }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only stdio crosses over, and signals start from their defaults (the app ignores SIGPIPE).
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        if disclaim {
            guard let setDisclaim = Self.setDisclaim, setDisclaim(&attributes, 1) == 0 else {
                throw POSIXError(.ENOTSUP) // never fall back to a child that inherits the app's access
            }
        }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }

        // The child has its own copies now; close ours so EOF arrives when it exits.
        try? standardInput?.fileHandleForReading.close()
        try? standardOutput?.fileHandleForWriting.close()
        try? standardError?.fileHandleForWriting.close()
        lock.withLock { pid = child; running = true }

        let thread = Thread { [self] in
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) < 0 && errno == EINTR {}
            let signal = raw & 0x7f
            lock.withLock { running = false; status = signal == 0 ? (raw >> 8) & 0xff : signal }
            exited.signal()
            terminationHandler?(self)
        }
        thread.name = "ChildProcess \(child)"
        thread.start()
    }

    public func terminate() { signal(SIGTERM) }

    public func signal(_ number: Int32) {
        lock.withLock { if running { _ = kill(pid, number) } }
    }

    public func waitUntilExit() {
        guard isRunning else { return }
        exited.wait()
        exited.signal() // let any other waiter through too
    }

    /// Whether this Mac can launch disclaimed children at all.
    public static var canDisclaim: Bool { setDisclaim != nil }

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private static let setDisclaim: SetDisclaim? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: SetDisclaim.self)
    }()
}
