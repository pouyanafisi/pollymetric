import AppKit

enum DashboardSection: String, CaseIterable, Identifiable, Hashable {
    case overview, processes, cleanup, projects, launchItems, security, history, conversations, general, agents, connections
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .processes: "Processes"
        case .cleanup: "Caches"
        case .projects: "Build Folders"
        case .launchItems: "Launch Items"
        case .security: "Security Audit"
        case .history: "History"
        case .conversations: "Conversations"
        case .general: "General"
        case .agents: "Agents"
        case .connections: "Connections"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "waveform.path.ecg"
        case .processes: "cpu"
        case .cleanup: "sparkles"
        case .projects: "shippingbox"
        case .launchItems: "power"
        case .security: "checkmark.shield"
        case .history: "clock.arrow.circlepath"
        case .conversations: "text.bubble"
        case .general: "gearshape"
        case .agents: "sparkle"
        case .connections: "cable.connector"
        }
    }
}

/// The installed tools, each opened in its native interface for deeper work.
enum Tool: String, CaseIterable, Identifiable {
    case diskMap, projects, mole, processes, launchItems, audit
    var id: String { rawValue }

    var title: String {
        switch self {
        case .diskMap: "Disk Space"
        case .projects: "Projects"
        case .mole: "Clean Up"
        case .processes: "Activity"
        case .launchItems: "Startup"
        case .audit: "Security"
        }
    }

    var symbol: String {
        switch self {
        case .diskMap: "chart.pie"
        case .projects: "shippingbox"
        case .mole: "wand.and.stars"
        case .processes: "cpu"
        case .launchItems: "power"
        case .audit: "checkmark.shield"
        }
    }

    var help: String {
        switch self {
        case .diskMap: "See what's taking up space, and delete what you don't need"
        case .projects: "Free up space from old projects, one project at a time"
        case .mole: "Clean up, uninstall apps and tune up this Mac"
        case .processes: "See everything that's running right now"
        case .launchItems: "See everything that starts by itself"
        case .audit: "Check how well this Mac is protected (asks for your password)"
        }
    }

    var command: String? {
        switch self {
        case .diskMap: "dua i ~"
        case .projects: "kondo " + Self.projectFolders.joined(separator: " ")
        case .mole: "mo"
        case .processes: "btop"
        case .launchItems: nil
        case .audit: nil
        }
    }

    /// The usual places people keep code, or the home folder when none of them exist.
    private static var projectFolders: [String] {
        let found = ["Developer", "Projects", "Code", "Sites", "src", "dev", "repos", "GitHub"]
            .filter { FileManager.default.fileExists(atPath: NSHomeDirectory() + "/" + $0) }
            .map { "~/" + $0 }
        return found.isEmpty ? ["~"] : found
    }
}
