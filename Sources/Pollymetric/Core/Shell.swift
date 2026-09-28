import HarnessKit
import Foundation

struct ShellResult: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

enum ShellError: LocalizedError {
    case notInstalled(String)
    case failed(String, Int32, String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let tool): "\(tool) isn't installed"
        case .failed(let tool, let code, let err):
            "\(tool) exited with code \(code)" + (err.isEmpty ? "" : ": \(err.prefix(200))")
        case .timedOut(let tool): "\(tool) took too long and was stopped"
        }
    }
}

/// Runs command-line tools off the main thread.
///
/// `background: true` launches the tool through `taskpolicy -c utility`: below your
/// apps in priority, with throttled disk I/O. (The stricter `-b` background clamp
/// starved scans completely on a busy Mac. A cache scan never finished at 90% CPU.)
enum Shell {
    static let searchPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }

    static func which(_ tool: String) -> String? {
        searchPath.split(separator: ":")
            .map { "\($0)/\(tool)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(
        _ tool: String,
        _ arguments: [String] = [],
        background: Bool = false,
        disclaim: Bool = false,
        timeout: TimeInterval = 120,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ShellResult {
        let executable: String
        if tool.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: tool) else { throw ShellError.notInstalled(tool) }
            executable = tool
        } else {
            guard let found = which(tool) else { throw ShellError.notInstalled(tool) }
            executable = found
        }
        let name = (executable as NSString).lastPathComponent
        let launchPath = background ? "/usr/sbin/taskpolicy" : executable
        let launchArgs = background ? ["-c", "utility", executable] + arguments : arguments

        return try await withCheckedThrowingContinuation { continuation in
            // `disclaim`: the tool gets none of Pollymetric's Full Disk Access (see ChildProcess).
            let process = ChildProcess(executable: launchPath, arguments: launchArgs, environment: environment, disclaim: disclaim)
            process.currentDirectory = NSHomeDirectory()
            // stdin stays /dev/null, no TTY: tools like `mo clean` take their non-interactive path.

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let stdout = OutputCollector(onLine: onLine)
            let stderr = OutputCollector(onLine: nil)
            out.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
            err.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

            let timedOut = Flag()
            let watchdog = DispatchWorkItem {
                if process.isRunning { timedOut.set(); process.terminate() }
            }

            process.terminationHandler = { finished in
                watchdog.cancel()
                RunningProcesses.shared.remove(finished)
                // A grandchild can inherit the pipe and keep it open, so never block
                // waiting for EOF: take what's buffered and finish.
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                stdout.append(drainNonBlocking(out.fileHandleForReading))
                stderr.append(drainNonBlocking(err.fileHandleForReading))
                stdout.flush()

                if timedOut.isSet {
                    continuation.resume(throwing: ShellError.timedOut(name))
                    return
                }
                continuation.resume(returning: ShellResult(
                    status: finished.terminationStatus,
                    stdout: stdout.text,
                    stderr: stderr.text
                ))
            }

            RunningProcesses.shared.add(process) // before run: a quick tool can finish first
            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
            } catch {
                RunningProcesses.shared.remove(process)
                continuation.resume(throwing: error)
            }
        }
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
    }

    private static func drainNonBlocking(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Tracks child processes so quitting Pollymetric mid-scan doesn't leave them running.
final class RunningProcesses: @unchecked Sendable {
    static let shared = RunningProcesses()
    private let lock = NSLock()
    private var processes: [ObjectIdentifier: ChildProcess] = [:]

    func add(_ p: ChildProcess) { lock.withLock { processes[ObjectIdentifier(p)] = p } }
    func remove(_ p: ChildProcess) { lock.withLock { processes[ObjectIdentifier(p)] = nil } }

    func terminateAll() {
        for p in lock.withLock({ Array(processes.values) }) where p.isRunning { p.terminate() }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Thread-safe accumulator that also splits the stream into lines for live progress.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            data.append(chunk)
            guard onLine != nil else { return }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        lines.forEach { onLine?(Shell.stripANSI($0)) }
    }

    func flush() {
        let rest: String? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            defer { pending.removeAll() }
            return String(decoding: pending, as: UTF8.self)
        }
        if let rest { onLine?(Shell.stripANSI(rest)) }
    }

    var text: String { Shell.stripANSI(lock.withLock { String(decoding: data, as: UTF8.self) }) }
}
