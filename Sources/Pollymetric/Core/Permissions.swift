import AppKit
import Foundation

/// Full Disk Access is the one setting that covers everything Pollymetric' scans touch.
///
/// Without it, macOS attributes each folder the child tools read (Downloads, iCloud
/// Drive, Desktop, removable volumes…) to Pollymetric and asks about each one separately.
/// With it, there are no prompts. There's no API to ask for it: you turn it on in
/// System Settings, and Pollymetric detects it by trying to open a file only FDA can read.
enum Permissions {
    static var hasFullDiskAccess: Bool {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: probe) else { return false }
        try? handle.close()
        return true
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
