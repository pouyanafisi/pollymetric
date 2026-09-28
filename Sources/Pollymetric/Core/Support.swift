import AppKit
import Foundation

/// Byte sizes use 1024-based units with mole's labels ("37.52GB" → 37.5 GB), so
/// numbers in Pollymetric match what `mo` prints in the terminal.
enum Bytes {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    static func parse<S: StringProtocol>(_ text: S) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let match = trimmed.firstMatch(of: #/^([0-9]+(?:\.[0-9]+)?)\s*([KMGTP]?)i?B$/#) else { return nil }
        guard let number = Double(match.1) else { return nil }
        let exponent = ["": 0, "K": 1, "M": 2, "G": 3, "T": 4, "P": 5][String(match.2)] ?? 0
        return Int64(number * pow(1024, Double(exponent)))
    }

    static func format(_ bytes: Int64) -> String {
        var value = Double(max(bytes, 0))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        if unit == 0 { return "\(Int(value)) B" }
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f %@", value, units[unit])
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? home + path.dropFirst() : path
    }

    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: expand(path))
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

enum Relative {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func string(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "never" }
        // abs(): future dates (a limit that resets later) must read "in 6 days", not "just now".
        if abs(now.timeIntervalSince(date)) < 45 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func uptime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let days = s / 86_400, hours = (s % 86_400) / 3_600, minutes = (s % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// Watches a directory for changes with a kqueue source. It costs nothing while idle,
/// which is why Pollymetric uses it instead of rescanning on a timer.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    init?(path: String, onChange: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .attrib], queue: .main
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit { source?.cancel() }
}

/// Opens a command in a new iTerm2 tab, or in Terminal.app if iTerm2 is missing.
enum Terminal {
    /// Typed into the terminal as keystrokes, so a control character is a keystroke too:
    /// a folder named with Ctrl-U and a return would clear the line and run its own command.
    static func isSafe(_ command: String) -> Bool {
        !command.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func run(_ command: String) {
        guard isSafe(command) else {
            NSLog("Pollymetric: refused a terminal command containing control characters")
            return
        }
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let hasITerm = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
        let script = hasITerm ? """
            tell application id "com.googlecode.iterm2"
                activate
                if (count of windows) is 0 then
                    create window with default profile
                else
                    tell current window to create tab with default profile
                end if
                tell current session of current window to write text "\(escaped)"
            end tell
            """ : """
            tell application "Terminal"
                activate
                do script "\(escaped)"
            end tell
            """
        Task.detached(priority: .userInitiated) {
            _ = try? await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 30)
        }
    }
}
