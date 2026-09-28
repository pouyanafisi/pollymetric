import Foundation

/// Direct argv execution keeps account selection identical across terminal and in-app flows.
public enum HarnessProcess {
    public static func environment(_ descriptor: HarnessDescriptor, account: HarnessAccount?, path: String,
                                   inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = inherited.filter { ["HOME", "USER", "LOGNAME"].contains($0.key) }
        env["HOME"] = env["HOME"] ?? NSHomeDirectory()
        env["PATH"] = path
        if let variable = descriptor.accounts?.env, let account, !account.isDefault, let home = account.home {
            env[variable] = home
        }
        return env
    }

    public static func executable(_ argv: [String], path: String) -> String? {
        guard let name = argv.first else { return nil }
        let candidates = name.hasPrefix("/") ? [name] : path.split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func run(_ argv: [String], environment: [String: String], timeout: TimeInterval = 300) async -> Int32? {
        guard let executable = executable(argv, path: environment["PATH"] ?? "") else { return nil }
        return await withCheckedContinuation { continuation in
            let process = ChildProcess(executable: executable, arguments: Array(argv.dropFirst()), environment: environment, disclaim: true)
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { finished in
                deadline.cancel()
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            } catch { continuation.resume(returning: nil) }
        }
    }
}

public struct SignInProgress: Equatable {
    public var desired: AuthStatus
    public var started: Date
    public init(desired: AuthStatus, started: Date = .now) { self.desired = desired; self.started = started }
    public func isWaiting(status: AuthStatus, now: Date = .now) -> Bool {
        status != desired && now.timeIntervalSince(started) < 300
    }
}
