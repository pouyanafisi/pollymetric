import Foundation

public struct HarnessAccount: Codable, Hashable, Sendable, Identifiable {
    public var id: String { home ?? "default" }
    /// The config home, or nil for a harness without accounts.
    public var home: String?
    /// "default" or the home's suffix: `~/.claude-work` → "work".
    public var label: String
    public var isDefault: Bool
    public var status: AuthStatus
    /// Usually the signed-in email, when the harness reports one.
    public var identity: String?
    /// The plan, when the status check reports it ("Max", "Pro").
    public var plan: String?

    public init(home: String?, label: String, isDefault: Bool, status: AuthStatus, identity: String? = nil, plan: String? = nil) {
        self.home = home; self.label = label; self.isDefault = isDefault
        self.status = status; self.identity = identity; self.plan = plan
    }
}

public enum AuthStatus: String, Codable, Sendable {
    case signedIn, signedOut
    /// No safe way to check, or the check failed.
    case unknown
}

public struct HarnessInstallation: Codable, Hashable, Sendable, Identifiable {
    public var id: String { descriptor.id }
    public var descriptor: HarnessDescriptor
    /// nil when not installed.
    public var executable: String?
    public var accounts: [HarnessAccount]

    public var isInstalled: Bool { executable != nil }

    public init(descriptor: HarnessDescriptor, executable: String?, accounts: [HarnessAccount]) {
        self.descriptor = descriptor
        self.executable = executable
        self.accounts = accounts
    }
}

/// Finds installed harnesses, their accounts and whether each is signed in.
///
/// GUI apps don't get your shell's PATH (no ~/.local/bin, no version managers), so the
/// detector asks your login shell for it once. Status commands run with a scrubbed
/// environment (HOME, USER, LOGNAME, PATH plus the account's home variable), no stdin,
/// and stderr discarded, because some CLIs print credentials there.
public actor HarnessDetector {
    public static let shared = HarnessDetector()
    private var loginPath: String?

    public init() {}

    public func detect(_ descriptors: [HarnessDescriptor]) async -> [HarnessInstallation] {
        let path = await shellPath()
        var results: [HarnessInstallation] = []
        for descriptor in descriptors {
            let executable = Self.find(descriptor.executables, in: path)
            var accounts: [HarnessAccount] = []
            if executable != nil {
                for (home, label, isDefault) in Self.homes(for: descriptor) {
                    let (status, identity, plan) = await authStatus(descriptor, home: home, path: path)
                    accounts.append(HarnessAccount(home: home, label: label, isDefault: isDefault, status: status, identity: identity, plan: plan))
                }
            }
            results.append(HarnessInstallation(descriptor: descriptor, executable: executable, accounts: accounts))
        }
        return results
    }

    /// Your login shell's PATH, asked once and cached. Falls back to common locations.
    public func shellPath() async -> String {
        if let loginPath { return loginPath }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = await CommandRunner.run([shell, "-ilc", "printf %s \"$PATH\""], environment: ["HOME": NSHomeDirectory()], timeout: 8)
        let fallback = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .map(Self.expand).joined(separator: ":")
        let resolved = (result?.status == 0 && result?.stdout.contains("/") == true) ? result!.stdout : fallback
        loginPath = resolved
        return resolved
    }

    // MARK: Accounts

    static func homes(for descriptor: HarnessDescriptor) -> [(home: String?, label: String, isDefault: Bool)] {
        guard let accounts = descriptor.accounts else { return [(nil, "default", true)] }
        var homes: [(String?, String, Bool)] = [(expand(accounts.default), "default", true)]
        if let glob = accounts.glob {
            let pattern = expand(glob)
            let dir = (pattern as NSString).deletingLastPathComponent
            let namePattern = (pattern as NSString).lastPathComponent
            let prefix = namePattern.components(separatedBy: "*").first ?? namePattern
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in names.sorted() where name.hasPrefix(prefix) && name.count > prefix.count && fnmatch(namePattern, name, 0) == 0 {
                var isDir: ObjCBool = false
                let full = (dir as NSString).appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
                homes.append((full, String(name.dropFirst(prefix.count)), false))
            }
        }
        return homes
    }

    // MARK: Auth

    private func authStatus(_ descriptor: HarnessDescriptor, home: String?, path: String) async -> (AuthStatus, String?, String?) {
        guard let auth = descriptor.auth else { return (.unknown, nil, nil) }
        func planName(_ json: Any?) -> String? {
            guard let raw = auth.plan.flatMap({ Self.string(at: $0.jsonKey, in: json) }), !raw.isEmpty else { return nil }
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }

        if let file = auth.file {
            let url = URL(fileURLWithPath: Self.resolve(file, home: home))
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return (.signedOut, nil, nil) }
            let json = try? JSONSerialization.jsonObject(with: data)
            let signedIn = auth.signedIn.map { Self.evaluate($0, text: "", json: json, exit: 0) }
                ?? ((json as? [String: Any]).map { !$0.isEmpty } ?? true)
            return (signedIn ? .signedIn : .signedOut, auth.identity.flatMap { Self.string(at: $0.jsonKey, in: json) }, planName(json))
        }

        if let command = auth.command, let first = command.first,
           let executable = Self.find([first], in: path) {
            var env = Self.baseEnvironment(path: path)
            if let accounts = descriptor.accounts, let home, home != Self.expand(accounts.default) {
                env[accounts.env] = home
            }
            guard let result = await CommandRunner.run([executable] + command.dropFirst(), environment: env, timeout: 10,
                                                       captureStderr: auth.matchStderr == true)
            else { return (.unknown, nil, nil) }
            let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
            let match = auth.signedIn ?? HarnessDescriptor.Match(exitCode: 0)
            let signedIn = Self.evaluate(match, text: result.stdout + "\n" + result.stderr, json: json, exit: result.status)
            return (signedIn ? .signedIn : .signedOut, auth.identity.flatMap { Self.string(at: $0.jsonKey, in: json) }, planName(json))
        }
        return (.unknown, nil, nil)
    }

    static func evaluate(_ match: HarnessDescriptor.Match, text: String, json: Any?, exit: Int32) -> Bool {
        if let key = match.jsonKey {
            let value = value(at: key, in: json)
            if let bool = value as? Bool { return bool }
            if let string = value as? String { return !string.isEmpty }
            return value != nil && !(value is NSNull)
        }
        if let needle = match.contains { return text.contains(needle) }
        if let code = match.exitCode { return exit == code }
        return false
    }

    static func value(at key: String, in json: Any?) -> Any? {
        key.split(separator: ".").reduce(json) { node, part in (node as? [String: Any])?[String(part)] }
    }

    static func string(at key: String?, in json: Any?) -> String? {
        guard let key else { return nil }
        return value(at: key, in: json) as? String
    }

    // MARK: Helpers

    static func baseEnvironment(path: String) -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        let user = env["USER"] ?? NSUserName()
        return ["HOME": NSHomeDirectory(), "USER": user, "LOGNAME": env["LOGNAME"] ?? user, "PATH": path]
    }

    static func find(_ names: [String], in path: String) -> String? {
        for name in names {
            if name.hasPrefix("/") { if FileManager.default.isExecutableFile(atPath: name) { return name }; continue }
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
    }

    static func resolve(_ file: String, home: String?) -> String {
        if file.hasPrefix("/") || file.hasPrefix("~") { return expand(file) }
        return ((home ?? NSHomeDirectory()) as NSString).appendingPathComponent(file)
    }
}

/// Minimal process runner for status probes: no stdin, stderr discarded, hard timeout.
enum CommandRunner {
    struct Result { var status: Int32; var stdout: String; var stderr: String = "" }

    static func run(_ argv: [String], environment: [String: String], timeout: TimeInterval, captureStderr: Bool = false) async -> Result? {
        guard let executable = argv.first else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                // Disclaimed: probes run user-editable code (shell profiles, CLIs on a
                // user-owned PATH, commands from harnesses.json) and get none of the app's access.
                let process = ChildProcess(executable: executable, arguments: Array(argv.dropFirst()), environment: environment, disclaim: true)
                let errPipe = captureStderr ? Pipe() : nil
                process.standardError = errPipe
                let pipe = Pipe()
                process.standardOutput = pipe
                guard (try? process.run()) != nil else { continuation.resume(returning: nil); return }

                let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                // Read stderr concurrently so a chatty CLI can't fill the pipe and stall.
                var errData = Data()
                let group = DispatchGroup()
                if let errPipe {
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                group.wait()
                killer.cancel()
                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: String(decoding: data, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }
}
