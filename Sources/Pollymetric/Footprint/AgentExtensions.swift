import SwiftUI

/// What your agents have been given: the MCP servers and skills each one loads, what
/// they run, and what they can reach.
struct AgentExtensionsReport: Codable, Sendable, Equatable {
    var items: [AgentExtension] = []
}

struct AgentExtension: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(agent):\(kind):\(name):\(source)" }
    var agent: String
    var kind: String
    var name: String
    var source: String
}

enum AgentExtensions {
    static func scan() async throws -> AgentExtensionsReport { AgentExtensionsReport() }
}

struct AgentExtensionsPage: View {
    @Bindable var store: AppStore
    var body: some View {
        PageHeader(title: "Plugins & Skills", subtitle: "What your agents can use, and what each one can reach.",
                   updatedAt: store.extensions.updatedAt, isFetching: store.extensions.isFetching, error: store.extensions.error,
                   refresh: { store.extensions.refresh() })
    }
}
