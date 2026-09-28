import Foundation

struct LynisFinding: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String { testID + "|" + text + "|" + (details ?? "") }
    var testID: String
    var text: String
    var details: String?
    var solution: String?

    var controlURL: URL? { URL(string: "https://cisofy.com/lynis/controls/\(testID)/") }
}

struct LynisReport: Codable, Sendable, Equatable {
    var date: Date
    var hardeningIndex: Int?
    var version: String?
    var testsPerformed: Int?
    var warnings: [LynisFinding]
    var suggestions: [LynisFinding]

    /// Parses Lynis' `key=value` report. Findings look like `warning[]=ID|text|details|solution|`.
    static func parse(_ text: String, date: Date) -> LynisReport {
        var report = LynisReport(date: date, warnings: [], suggestions: [])
        for line in text.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals], value = String(line[line.index(after: equals)...])
            switch key {
            case "hardening_index": report.hardeningIndex = Int(value)
            case "lynis_version": report.version = value
            case "lynis_tests_done": report.testsPerformed = Int(value)
            case "warning[]": if let f = finding(value) { report.warnings.append(f) }
            case "suggestion[]": if let f = finding(value) { report.suggestions.append(f) }
            default: break
            }
        }
        return report
    }

    private static func finding(_ value: String) -> LynisFinding? {
        let parts = value.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        func field(_ i: Int) -> String? {
            guard parts.indices.contains(i) else { return nil }
            let v = parts[i].trimmingCharacters(in: .whitespaces)
            return v.isEmpty || v == "-" ? nil : v
        }
        return LynisFinding(testID: parts[0], text: parts[1], details: field(2), solution: field(3))
    }
}

/// Wraps an optional report so the query can cache "no audit yet" as a real answer.
struct LynisStatus: Codable, Sendable, Equatable {
    var report: LynisReport?
}

enum Lynis {
    /// Private to you (0700): it holds command lines, transcripts and briefs. An override
    /// folder is only restricted when Pollymetric creates it; an existing one is yours.
    static let dataDirectory: URL = {
        let fm = FileManager.default
        if let override = DataDirectory.override() {
            try? fm.createDirectory(at: override, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return override
        }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Pollymetric", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }()

    /// Everything Pollymetric writes into the data folder, for uninstalling from a folder
    /// it doesn't own.
    static let ownFiles = ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm", "briefs", "cache",
                           "lynis-report.dat", "lynis.log", "mcp.sock", "mcp.sock.lock", "preferences.plist"]

    static var ownReport: URL { dataDirectory.appendingPathComponent("lynis-report.dat") }
    static let systemReport = URL(fileURLWithPath: "/var/log/lynis-report.dat")

    /// The audit, run as root. Root never writes where you can: Lynis works in a fresh
    /// root-only temp folder, the report comes back on stdout, and the folder is removed.
    /// (Writing into the data folder and chown-ing the result would let anything running
    /// as you plant a link there and have root truncate and hand over a system file.)
    static func adminScript(executable: String) -> String {
        let quote = Assistant.shellQuote
        let command = "d=$(/usr/bin/mktemp -d /tmp/pollymetric-lynis.XXXXXX) || exit 1; "
            + "\(quote(executable)) audit system --quick --no-colors"
            + " --report-file \"$d/report.dat\" --log-file \"$d/lynis.log\" >/dev/null 2>&1; "
            + "/bin/cat \"$d/report.dat\"; s=$?; /bin/rm -rf \"$d\"; exit $s"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges without altering line endings"
    }

    /// Saves a report from the audit's output, replacing (never writing through) whatever
    /// is at the report's path.
    static func saveReport(_ text: String) -> Bool {
        guard text.contains("lynis_version=") else { return false }
        return (try? Data(text.utf8).write(to: ownReport, options: .atomic)) != nil
    }

    /// Reads the newest report you can read: Pollymetric' own, or one from a manual run.
    static func load() -> LynisStatus {
        let candidates = (DataDirectory.override() == nil ? [ownReport, systemReport] : [ownReport]).compactMap { url -> (URL, Date)? in
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return (url, modified)
        }
        guard let (url, date) = candidates.max(by: { $0.1 < $1.1 }),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return LynisStatus(report: nil) }
        return LynisStatus(report: LynisReport.parse(text, date: date))
    }

    static var reportModified: Date? {
        try? ownReport.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
