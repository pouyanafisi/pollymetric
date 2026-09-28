import SwiftUI

/// Everything listening for connections on this Mac: which process, which port, who
/// started it, and whether other machines on the network can reach it.
struct LocalServersReport: Codable, Sendable, Equatable {
    var servers: [LocalServer] = []
}

struct LocalServer: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(pid):\(port)" }
    var pid: Int32
    var port: Int
    var address: String
}

enum LocalServers {
    static func scan() async throws -> LocalServersReport { LocalServersReport() }
}

struct LocalServersPage: View {
    @Bindable var store: AppStore
    var body: some View {
        PageHeader(title: "Local Servers", subtitle: "Everything listening on this Mac, and who started it.",
                   updatedAt: store.servers.updatedAt, isFetching: store.servers.isFetching, error: store.servers.error,
                   refresh: { store.servers.refresh() })
    }
}
