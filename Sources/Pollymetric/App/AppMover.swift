import AppKit
import Darwin

/// Offers to move Pollymetric into Applications when it's launched from somewhere else
/// (the DMG, Downloads, the desktop), then relaunches from there.
///
/// Running from Applications matters: login items point at the app's location, updates
/// replace it in place, and a copy left on a DMG disappears when the DMG is ejected.
enum AppMover {
    private static let suppressKey = "suppressMoveToApplications"

    /// True for a real app bundle outside an Applications folder. Development binaries
    /// run from .build aren't bundles and are left alone.
    static var needsMove: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        let path = originalURL(of: bundle).path
        return !path.hasPrefix("/Applications/") && !path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    /// Asks once per launch (unless told not to), moves, relaunches. Returns true when
    /// this process is about to quit in favour of the moved copy.
    @MainActor
    static func offerMoveIfNeeded() -> Bool {
        guard needsMove, !UserDefaults.standard.bool(forKey: suppressKey) else { return false }
        let source = originalURL(of: Bundle.main.bundleURL)
        let fromDMG = source.path.hasPrefix("/Volumes/")

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Move Pollymetric to your Applications folder?"
        alert.informativeText = fromDMG
            ? "It's running from the installer disk image. In Applications it keeps running after you eject the disk, starts at login, and updates cleanly."
            : "It's running from \(Paths.abbreviate(source.deletingLastPathComponent().path)). In Applications it starts at login reliably and updates cleanly."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: suppressKey) }
        guard answer == .alertFirstButtonReturn else { return false }

        do {
            let destination = try move(source, fromDMG: fromDMG)
            relaunch(destination, ejecting: fromDMG ? volume(of: source) : nil)
            return true
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Pollymetric couldn't be moved"
            failure.informativeText = "\(error.localizedDescription)\n\nYou can drag it into Applications in Finder instead."
            failure.runModal()
            return false
        }
    }

    private static func move(_ source: URL, fromDMG: Bool) throws -> URL {
        let fm = FileManager.default
        // /Applications for admin users; ~/Applications when that isn't writable.
        var folder = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if !fm.isWritableFile(atPath: folder.path) {
            folder = URL(fileURLWithPath: NSHomeDirectory() + "/Applications", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let destination = folder.appendingPathComponent(source.lastPathComponent)

        if fm.fileExists(atPath: destination.path) {
            // Only ever replace Pollymetric itself, never another app that shares the name.
            guard let id = Bundle.main.bundleIdentifier, Bundle(url: destination)?.bundleIdentifier == id else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey:
                    "There's already a different app called \(destination.lastPathComponent) in \(folder.path)."])
            }
            // An older copy: quit it if it's running, then send it to the Trash.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where app.bundleURL?.standardizedFileURL == destination.standardizedFileURL {
                app.terminate()
            }
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
        // Leave nothing behind outside the DMG (a read-only disk can't be changed anyway).
        if !fromDMG { try? fm.trashItem(at: source, resultingItemURL: nil) }
        return destination
    }

    private static func relaunch(_ app: URL, ejecting volume: URL?) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                if let volume { try? NSWorkspace.shared.unmountAndEjectDevice(at: volume) }
                NSApp.terminate(nil)
            }
        }
    }

    private static func volume(of url: URL) -> URL? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    /// When macOS runs a downloaded app from a randomized read-only path ("App
    /// Translocation"), this finds where the user actually put it.
    static func originalURL(of url: URL) -> URL {
        guard url.path.contains("/AppTranslocation/"),
              let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
        else { return url }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(symbol, to: Original.self)
        return original(url as CFURL, nil)?.takeRetainedValue() as URL? ?? url
    }
}
