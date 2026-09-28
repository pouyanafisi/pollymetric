import SwiftUI

/// Extra working copies of your projects (git worktrees), often left behind by agents
/// after a task: how much space each holds, and whether anything still depends on it.
struct WorktreesReport: Codable, Sendable, Equatable {
    var worktrees: [Worktree] = []
}

struct Worktree: Codable, Sendable, Equatable, Identifiable {
    var id: String { path }
    var path: String
}

enum Worktrees {
    static func scan() async throws -> WorktreesReport { WorktreesReport() }
}

struct WorktreesPage: View {
    @Bindable var store: AppStore
    var body: some View {
        PageHeader(title: "Worktrees", subtitle: "Extra copies of your projects, and the space they hold.",
                   updatedAt: store.worktrees.updatedAt, isFetching: store.worktrees.isFetching, error: store.worktrees.error,
                   refresh: { store.worktrees.refresh() })
    }
}
