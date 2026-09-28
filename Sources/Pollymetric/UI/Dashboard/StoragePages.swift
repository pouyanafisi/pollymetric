import SwiftUI

struct CachesPage: View {
    @Bindable var store: AppStore
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Caches",
                subtitle: "Space you can safely get back. Apps quietly recreate what they need.",
                updatedAt: store.clean.updatedAt, isFetching: store.clean.isFetching, error: store.clean.error,
                refresh: { store.clean.refresh() }
            )

            if let job = store.job, job.kind == .clean {
                JobPanel(job: job) { store.job = nil }
            }

            if let preview = store.clean.value {
                Hero(
                    value: Bytes.format(preview.totalBytes),
                    caption: "can be freed across \(preview.itemCount) items"
                ) {
                    Button("Clean…") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(preview.totalBytes == 0 || store.job?.isRunning == true || store.clean.isFetching)
                }
                .confirmationDialog("Clean \(Bytes.format(preview.totalBytes)) of caches?", isPresented: $confirming) {
                    Button("Clean", role: .destructive) { store.runClean() }
                } message: {
                    Text("Runs `mo clean` for everything listed below. System caches that need your password are skipped. To keep something, right-click it and choose Protect.")
                }

                ForEach(preview.sections) { section in
                    Card {
                        DisclosureGroup {
                            VStack(spacing: 0) {
                                ForEach(section.items.prefix(40)) { item in
                                    PathRow(path: item.path, bytes: item.bytes) {
                                        Button("Protect from Cleaning") { store.protect(item.path) }
                                    }
                                }
                                if section.items.count > 40 {
                                    Text("and \(section.items.count - 40) smaller items")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 6)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                Text(section.name).font(.headline)
                                Text("\(section.items.count)").font(.caption).foregroundStyle(.tertiary)
                                Spacer()
                                Text(Bytes.format(section.bytes)).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else if store.clean.isFetching {
                EmptyState(symbol: "sparkles", title: "Scanning caches…", message: "This runs quietly in the background.")
            } else {
                EmptyState(symbol: "sparkles", title: "No scan yet", message: "Click the refresh button to measure your caches.")
            }
        }
    }
}

struct BuildFoldersPage: View {
    @Bindable var store: AppStore
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Build Folders",
                subtitle: "Space held by old projects' dependencies and build output. It comes back the next time you work on the project.",
                updatedAt: store.purge.updatedAt, isFetching: store.purge.isFetching, error: store.purge.error,
                refresh: { store.purge.refresh() }
            )

            if let job = store.job, job.kind == .purge {
                JobPanel(job: job) { store.job = nil }
            }

            if let preview = store.purge.value {
                Hero(
                    value: Bytes.format(preview.totalBytes),
                    caption: "in \(preview.items.count) build folders"
                ) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Button("Remove All…") { confirming = true }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(preview.items.isEmpty || store.job?.isRunning == true || store.purge.isFetching)
                        Button("Choose project by project") { store.open(.projects) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .confirmationDialog("Remove \(Bytes.format(preview.totalBytes)) of build folders?", isPresented: $confirming) {
                    Button("Remove", role: .destructive) { store.runPurge() }
                } message: {
                    Text("Runs `mo purge --yes`. Projects keep their source; reinstall dependencies when you next work on them.")
                }

                if preview.items.isEmpty {
                    EmptyState(symbol: "shippingbox", title: "Nothing to remove", message: "None of your projects are holding space you can free right now.")
                } else {
                    Card {
                        VStack(spacing: 0) {
                            ForEach(preview.items) { item in
                                PathRow(path: item.project, bytes: item.bytes, badge: item.artifact) { EmptyView() }
                            }
                        }
                    }
                }
            } else if store.purge.isFetching {
                EmptyState(symbol: "shippingbox", title: "Scanning projects…", message: "Looking through your projects…")
            } else {
                EmptyState(symbol: "shippingbox", title: "No scan yet", message: "Click the refresh button to find build folders.")
            }
        }
    }
}

struct PathRow<Extra: View>: View {
    var path: String
    var bytes: Int64
    var badge: String? = nil
    @ViewBuilder var extraMenu: Extra
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(Paths.abbreviate(path))
                .lineLimit(1)
                .truncationMode(.head)
                .help(path)
            if let badge {
                Text(badge)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 12)
            if hovering {
                Button { Paths.reveal(path) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Reveal in Finder")
            }
            Text(Bytes.format(bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { Paths.reveal(path) }
            Button("Copy Path") { Paths.copy(path) }
            extraMenu
        }
    }
}
