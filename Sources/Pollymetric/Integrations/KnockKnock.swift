import Foundation

struct LaunchItem: Codable, Sendable, Equatable, Identifiable {
    enum Trust: String, Codable, Sendable {
        case trusted, notNotarized, unsigned, unverified
    }

    var id: String { category + "|" + path }
    var category: String
    var name: String
    var path: String
    var plist: String?
    var signer: String?
    var trust: Trust

    /// Paths on the sealed system volume or under /usr belong to macOS itself.
    var isSystem: Bool {
        ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
    }

    /// Shell dotfiles are never signed, so being unsigned there means nothing.
    var isShellConfig: Bool { category == "Shell Configuration Files" }

    /// Worth a look: something set to launch itself that nobody signed.
    var isFlagged: Bool { trust == .unsigned && !isShellConfig && !isSystem }
}

struct LaunchItemsReport: Codable, Sendable, Equatable {
    var items: [LaunchItem]

    var categories: [(name: String, items: [LaunchItem])] {
        Dictionary(grouping: items, by: \.category)
            .map { ($0.key, $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { $0.name < $1.name }
    }

    /// The same binary is often registered twice (e.g. a launch agent and a background
    /// task), so flagged items are counted by path.
    var flaggedPaths: [String] {
        var seen = Set<String>()
        return items.filter(\.isFlagged).compactMap { seen.insert($0.path).inserted ? $0.path : nil }
    }

    static func parse(_ data: Data) throws -> LaunchItemsReport {
        // Keep only the JSON object, in case the tool logs a line around it.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let json = try JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any]
        else { throw ShellError.failed("KnockKnock", 0, "unreadable scan output") }

        var items: [LaunchItem] = []
        for (category, value) in json {
            for entry in value as? [[String: Any]] ?? [] {
                guard let path = entry["path"] as? String else { continue }
                let signature = entry["signature(s)"] as? [String: Any] ?? [:]
                let status = (signature["signatureStatus"] as? NSNumber)?.intValue
                let notarized = signature["notarized"] as? Bool
                let authorities = signature["signatureAuthorities"] as? [String] ?? []
                let signer = authorities.first

                let trust: LaunchItem.Trust
                switch status {
                case 0:
                    // Mac App Store apps are Apple-signed and don't carry a notarization flag.
                    let isDeveloperID = signer?.hasPrefix("Developer ID") ?? false
                    trust = (isDeveloperID && notarized != true) ? .notNotarized : .trusted
                case -67062: trust = .unsigned // errSecCSUnsigned
                default: trust = .unverified
                }

                let plist = entry["plist"] as? String
                items.append(LaunchItem(
                    category: category,
                    name: entry["name"] as? String ?? (path as NSString).lastPathComponent,
                    path: path,
                    plist: plist == "n/a" ? nil : plist,
                    signer: signer,
                    trust: trust
                ))
            }
        }
        return LaunchItemsReport(items: items)
    }
}

enum KnockKnock {
    static let app = "/Applications/KnockKnock.app"
    static let binary = app + "/Contents/MacOS/KnockKnock"

    /// A full scan hashes every persistent item and takes a few minutes, so it runs
    /// at background priority and only when the cached result is a day old or a
    /// launch-agent folder changes.
    static func scan() async throws -> LaunchItemsReport {
        let result = try await Shell.run(binary, ["-whosthere", "-skipVT"], background: true, timeout: 1_200)
        return try LaunchItemsReport.parse(Data(result.stdout.utf8))
    }

    /// Folders where software registers itself to launch. Changes here trigger a rescan.
    static let watchedFolders = [
        Paths.home + "/Library/LaunchAgents",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
    ]
}
