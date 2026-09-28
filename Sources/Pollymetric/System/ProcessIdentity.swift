import AppKit
import Darwin
import Foundation

/// Who a process really is: its label, the project it belongs to, and the app that
/// started it. "node" becomes "next dev · storefront · claude › iTerm2".
struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
    var key: String            // pid + start time: unique for one process's lifetime
    var pid: Int32
    var startedAt: Date
    var name: String
    var label: String          // what it's doing: "next dev", "tsserver", "claude"
    var context: String?       // the project folder it's working in
    var via: String?           // the meaningful parent, e.g. "claude" for an MCP server
    var app: String?           // the app it runs under: "iTerm2", "Visual Studio Code"
    var appPath: String?
    var executable: String?
    var command: String        // full command line, with secret-looking values masked
    var cwd: String?
    var chain: [String]        // ancestor names, nearest first

    /// Restarts of the same thing share a group, so a dev server that keeps coming back
    /// builds up one history instead of dozens of unrelated PIDs.
    var groupKey: String { [app ?? "", label, context ?? ""].joined(separator: "|") }

    /// One gray line under the label.
    var subtitle: String {
        let owner = [via, app].compactMap { $0 }.joined(separator: " › ")
        return [context, owner.isEmpty ? (isSystem ? "macOS" : "background") : owner]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var isSystem: Bool {
        guard let executable else { return app == nil }
        return ["/System/", "/usr/", "/sbin/", "/bin/", "/Library/Apple/"].contains { executable.hasPrefix($0) }
    }
}

/// Resolves identities through libproc and sysctl, only for processes worth naming
/// (busy or on screen), and caches them for the process's lifetime.
final class IdentityResolver {
    private struct Key: Hashable { var pid: Int32; var start: UInt64 }
    private var cache: [Key: ProcessIdentity] = [:]
    private var appNames: [String: String] = [:]

    func identity(pid: Int32, start: UInt64, name rawName: String) -> ProcessIdentity {
        let key = Key(pid: pid, start: start)
        if let cached = cache[key] { return cached }

        let (executable, arguments) = Self.arguments(pid: pid)
        let exe = executable ?? Self.path(pid: pid)
        let name = Self.friendlyName(rawName, executable: exe, argv0: arguments.first)
        let cwd = Self.cwd(pid: pid)
        let ancestors = Self.ancestors(of: pid)
        let described = ProcessDescriber.describe(name: name, arguments: arguments, cwd: cwd)

        // The app is the outermost .app bundle among the process and its ancestors.
        let appBundle = ([exe] + ancestors.map(\.path)).compactMap { $0 }.lazy.compactMap(Self.bundlePath).first
        let appName = appBundle.map(appName(for:))
        let via = ancestors.first { ancestor in
            !ProcessDescriber.wrappers.contains(ancestor.name.lowercased())
                && !(ancestor.path.map { appBundle != nil && $0.hasPrefix(appBundle!) } ?? false)
                && ancestor.name != "launchd"
        }?.name

        let identity = ProcessIdentity(
            key: "\(pid)-\(start)",
            pid: pid,
            startedAt: Self.startDate(pid: pid) ?? .now,
            name: name,
            label: described.label,
            context: described.context,
            via: via == described.label ? nil : via,
            app: appName,
            appPath: appBundle,
            executable: exe,
            command: arguments.isEmpty ? (exe ?? name) : ProcessDescriber.redact(arguments).joined(separator: " "),
            cwd: cwd,
            chain: ancestors.map(\.name)
        )
        cache[key] = identity
        return identity
    }

    func prune(keeping alive: Set<Int32>) {
        cache = cache.filter { alive.contains($0.key.pid) }
    }

    private func appName(for bundlePath: String) -> String {
        if let cached = appNames[bundlePath] { return cached }
        // Finder's name: VS Code's own bundle keys both say "Code".
        let name = (FileManager.default.displayName(atPath: bundlePath) as NSString).deletingPathExtension
        appNames[bundlePath] = name
        return name
    }

    // MARK: libproc / sysctl

    static func path(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func name(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let name = String(cString: buffer)
        return name.isEmpty ? nil : name
    }

    private static func bsdInfo(pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func startDate(pid: Int32) -> Date? {
        guard let info = bsdInfo(pid: pid) else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
    }

    private static func ancestors(of pid: Int32) -> [(name: String, path: String?)] {
        var chain: [(String, String?)] = []
        var current = pid
        for _ in 0..<12 {
            guard let info = bsdInfo(pid: current), info.pbi_ppid > 1 else { break }
            let parent = Int32(info.pbi_ppid)
            let path = path(pid: parent)
            let raw = name(pid: parent) ?? path.map { ($0 as NSString).lastPathComponent } ?? "?"
            chain.append((friendlyName(raw, executable: path, argv0: nil), path))
            current = parent
        }
        return chain
    }

    private static func cwd(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// Reads argv through KERN_PROCARGS2. Only works for your own processes, which
    /// are the ones you can act on anyway.
    static func arguments(pid: Int32) -> (String?, [String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return (nil, []) }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return (nil, []) }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func readString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let value = String(decoding: buffer[start..<index], as: UTF8.self)
            while index < size, buffer[index] == 0 { index += 1 } // skip padding
            return value
        }
        let executable = readString()
        var args: [String] = []
        for _ in 0..<max(0, argc) {
            guard let arg = readString() else { break }
            args.append(arg)
        }
        return (executable, args)
    }

    private static func bundlePath(_ path: String) -> String? {
        if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
        // Terminals that host shells from a helper outside their bundle.
        for (marker, bundleID) in helperHosts where path.contains(marker) {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        }
        return nil
    }

    private static let helperHosts = [
        ("/iTerm2/iTermServer", "com.googlecode.iterm2"),
    ]

    /// Some tools install versioned binaries (`…/claude/versions/2.1.283`), so the kernel's
    /// name for them is a version number. Prefer argv[0] or the folder above `versions`.
    static func friendlyName(_ name: String, executable: String?, argv0: String?) -> String {
        guard name.wholeMatch(of: #/[0-9][0-9.\-]*/#) != nil else { return name }
        if let argv0 {
            let base = (argv0 as NSString).lastPathComponent
            if !base.isEmpty, base.wholeMatch(of: #/[0-9][0-9.\-]*/#) == nil { return base }
        }
        if let executable {
            let parts = executable.split(separator: "/")
            if let i = parts.lastIndex(of: "versions"), i > 0 { return String(parts[i - 1]) }
        }
        return name
    }
}

/// Turns argv into a label a person recognizes. It's heuristic on purpose: it knows
/// how interpreters (node, python, …) and node_modules layouts look, and falls back to
/// the plain process name for everything else.
enum ProcessDescriber {
    static let interpreters: Set<String> = ["node", "python", "python3", "ruby", "bun", "deno", "java", "php", "perl"]

    /// Launchers that are rarely the interesting parent.
    static let wrappers: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "sh", "fish", "dash", "login", "sudo", "env", "nohup", "script",
        "npm", "npx", "pnpm", "yarn", "node", "bun", "deno", "tsx", "ts-node", "uv", "python", "python3",
        "tmux", "screen", "caffeinate", "timeout", "gtimeout", "time", "xargs", "launchd",
    ]

    static func describe(name: String, arguments: [String], cwd: String?) -> (label: String, context: String?) {
        if let model = LocalModels.match(name: name, arguments: arguments) { return (model.label, nil) }
        var label = name
        var project: String?
        let lowered = name.lowercased()

        if isInterpreter(lowered), arguments.count > 1 {
            var i = 1
            if lowered.hasPrefix("python"), let m = arguments.firstIndex(of: "-m"), m + 1 < arguments.count {
                label = arguments[m + 1]
                i = m + 2
            } else {
                while i < arguments.count, arguments[i].hasPrefix("-") { i += 1 }
                if i < arguments.count {
                    (label, project) = scriptLabel(arguments[i])
                    i += 1
                }
            }
            // Up to two subcommand words: "next dev", "npm run dev".
            var words: [String] = []
            while i < arguments.count, words.count < 2 {
                let arg = arguments[i]
                if arg.hasPrefix("-") || arg.contains("/") || arg.contains("=") || arg.count > 24 { break }
                if arg == "." || arg == ".." { i += 1; continue }
                words.append(arg)
                i += 1
            }
            if !words.isEmpty { label += " " + words.joined(separator: " ") }
        }

        let context = project ?? meaningfulFolder(cwd)
        return (label, context == label ? nil : context)
    }

    static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || name.hasPrefix("python3.")
    }

    private static func scriptLabel(_ script: String) -> (String, String?) {
        let file = ((script as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let first = script.range(of: "/node_modules/"),
              let last = script.range(of: "/node_modules/", options: .backwards)
        else { return (file, nil) }

        let parts = script[last.upperBound...].split(separator: "/").map(String.init)
        var package = parts.first ?? file
        if package == ".bin", parts.count > 1 { package = parts[1] }
        if package.hasPrefix("@"), parts.count > 1 { package += "/" + parts[1] }
        let short = (package as NSString).lastPathComponent
        let generic: Set<String> = ["index", "cli", "main", "bin", "run", "start", package, short]
        let label = generic.contains(file) ? short : "\(short) \(file)"
        return (label, meaningfulFolder(String(script[..<first.lowerBound])))
    }

    /// A folder name worth showing: inside your home folder, not hidden, not Library.
    static func meaningfulFolder(_ path: String?) -> String? {
        guard let path, path.hasPrefix(Paths.home + "/"), !path.contains("/."), !path.contains("/Library/") else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// One plain-English sentence for things people commonly wonder about. Returns nil
    /// when there's nothing useful to say beyond the label and where it came from.
    static func explain(label: String, name: String?, app: String?) -> String? {
        let l = label.lowercased(), n = (name ?? label).lowercased()
        if LocalModels.isLocalModel(label: label) { return "A local AI model. It keeps its weights in memory for as long as it's loaded, often many gigabytes, even while idle." }
        if l.contains("mcp") { return "An MCP server: a tool plugin that an AI client (\(app ?? "an agent")) starts and keeps running in the background." }
        if l.hasPrefix("typescript tsserver") || l == "tsserver" { return "TypeScript's language server. Your editor runs it for autocomplete and errors; large projects make it busy." }
        if l.hasPrefix("eslint") { return "The ESLint server that lints files as you edit." }
        if l.hasPrefix("next") { return "A Next.js dev server or build. Heavy CPU usually means it's recompiling after a file change." }
        if l.hasPrefix("vite") || l.hasPrefix("webpack") || l.hasPrefix("turbo") { return "A dev server or bundler rebuilding your project." }
        if l.hasPrefix("jest") || l.hasPrefix("vitest") { return "A test runner. Watch mode reruns tests on every save." }
        if l.hasPrefix("npm") || l.hasPrefix("pnpm") || l.hasPrefix("yarn") { return "A package manager command, usually an install or a script from package.json." }
        if n == "claude" { return "Claude Code, the CLI agent. It's busy while it works on a task." }
        if n.hasPrefix("mds") || n.hasPrefix("mdworker") { return "Spotlight indexing. It spikes after big file changes and settles down on its own." }
        if n == "kernel_task" { return "macOS itself. High usage often means it's throttling the CPU to control heat." }
        if n == "windowserver" { return "Draws everything on screen. Busy with many windows, displays or animations." }
        if n == "backupd" { return "Time Machine running a backup." }
        if n.contains("helper (renderer)") { return "One browser tab or web app. Heavy pages and video are the usual cause." }
        if n.contains("helper (gpu)") { return "The browser's graphics process, shared by all tabs." }
        if n.contains("code helper (plugin)") { return "VS Code's extension host: extensions like linters, language servers and Copilot-style tools." }
        if n.contains("webkit.webcontent") { return "A Safari tab or an app's embedded web view." }
        if n == "photoanalysisd" || n == "mediaanalysisd" { return "Photos analyzing your library for faces and search. It runs when the Mac is idle." }
        if n == "cloudd" || n == "bird" || n == "fileproviderd" { return "iCloud sync." }
        if n == "node" || isInterpreter(n) { return "A script run by \(name ?? label). The command and folder below show which one." }
        return nil
    }

    /// Masks values that look like credentials before anything is shown or stored.
    static func redact(_ arguments: [String]) -> [String] {
        let sensitive = #/(?i)(token|secret|password|passwd|pwd|api[-_]?key|private[-_]?key|auth|credential|cookie)/#
        let program = arguments.first.map { ($0 as NSString).lastPathComponent } ?? ""
        let attachedPassword = ["mysql", "mysqldump", "mysqladmin", "mariadb"].contains(program)
        var result: [String] = []
        var mask: Mask?
        for arg in arguments {
            switch mask {
            case .whole?:
                result.append("••••"); mask = nil; continue
            case .header?:
                mask = nil
                if let colon = arg.firstIndex(of: ":"), arg[..<colon].contains(sensitive) {
                    result.append(arg[...colon] + " ••••"); continue
                }
            case nil: break
            }
            if let eq = arg.firstIndex(of: "="), arg[..<eq].contains(sensitive) {
                result.append(arg[...eq] + "••••")
            } else if attachedPassword, arg.hasPrefix("-p"), arg.count > 2, !arg.hasPrefix("--") {
                result.append("-p••••")
            } else {
                if arg == "-H" || arg == "--header" { mask = .header }
                else if arg.hasPrefix("-"), arg.contains(sensitive) { mask = .whole }
                result.append(maskInline(arg))
            }
        }
        return result
    }

    private enum Mask { case whole, header }

    /// Secrets inside an argument: passwords in URLs, bearer tokens, and well-known key formats.
    static func maskInline(_ text: String) -> String {
        var text = text
        text.replace(#/(?<scheme>[A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:)[^/\s@]+@/#) { "\($0.scheme)••••@" }
        text.replace(#/(?i)(?<word>bearer|basic)\s+[A-Za-z0-9._~+\/=-]{8,}/#) { "\($0.word) ••••" }
        text.replace(#/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|glpat-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|npm_[A-Za-z0-9]{36}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})/#) { _ in "••••" }
        return text
    }
}
