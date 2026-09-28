import HarnessKit
import SwiftUI

/// Local agent harnesses: who's signed in, how much of each plan is used, and which
/// account "Ask" uses. Adding a harness is a descriptor in harnesses.json, not code.
struct AgentsPage: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Agents",
                subtitle: "The AI agents that can explain and fix problems for you, and how much of each plan is left.",
                updatedAt: store.harnesses.updatedAt, isFetching: store.harnesses.isFetching || store.isLoadingUsage,
                error: store.harnesses.error,
                refresh: { store.harnesses.refresh(); store.loadUsage(force: true) }
            )

            if let error = HarnessRegistry.load().userFileError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }

            let all = store.harnesses.value ?? []
            if all.isEmpty {
                EmptyState(symbol: "sparkle", title: store.harnesses.isFetching ? "Looking for agents…" : "No agents found",
                           message: "Install an AI agent like Claude Code or Codex, and Pollymetric can explain and fix problems for you.")
            }
            ForEach(all.filter(\.isInstalled)) { harness in
                HarnessCard(store: store, harness: harness)
            }

            let missing = all.filter { !$0.isInstalled }
            if !missing.isEmpty {
                HStack(spacing: 10) {
                    Text("Not installed").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(missing) { harness in
                        HStack(spacing: 5) {
                            ProviderLogo(harness: harness, size: 14).opacity(0.5)
                            Text(harness.descriptor.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add your own agent").font(.headline)
                        Text("Any command-line agent can be added with a short JSON descriptor: how to find it, check its sign-in and launch it read-only.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open harnesses.json") {
                        try? HarnessRegistry.createUserFileIfMissing()
                        NSWorkspace.shared.open(HarnessRegistry.userFile)
                    }
                }
            }
        }
        .task { store.loadUsage(force: false) }
    }
}

private struct HarnessCard: View {
    @Bindable var store: AppStore
    var harness: HarnessInstallation
    @State private var showSignedOut = false

    private var signedIn: [HarnessAccount] { harness.accounts.filter { $0.status != .signedOut } }
    private var signedOut: [HarnessAccount] { harness.accounts.filter { $0.status == .signedOut } }

    var body: some View {
        Card {
            HStack(spacing: 12) {
                ProviderLogo(harness: harness, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(harness.descriptor.name).font(.title3.weight(.semibold))
                    Text([harness.descriptor.vendor, harness.executable.map(Paths.abbreviate)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if harness.descriptor.accounts != nil {
                    Text("\(signedIn.filter { $0.status == .signedIn }.count) of \(harness.accounts.count) signed in")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            ForEach(signedIn) { account in
                Divider()
                AccountRow(store: store, harness: harness, account: account)
            }

            if !signedOut.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showSignedOut) {
                    ForEach(signedOut) { account in
                        HStack {
                            Text(account.label).font(.callout)
                            if store.signInProgress["\(harness.id)|\(account.id)"] != nil {
                                Text("Finish signing in in your browser…").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(account.home.map(Paths.abbreviate) ?? "").font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                            if harness.descriptor.login != nil {
                                Button("Sign In…") { store.signIn(harness, account) }.controlSize(.small)
                                    .disabled(store.signInProgress["\(harness.id)|\(account.id)"] != nil)
                                Menu {
                                    if let command = HarnessCommand.login(harness.descriptor, account: account) {
                                        Button("Open in iTerm") { Terminal.run(command) }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } label: {
                    Text("\(signedOut.count) signed out · \(signedOut.map(\.label).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct AccountRow: View {
    @Bindable var store: AppStore
    var harness: HarnessInstallation
    var account: HarnessAccount
    @State private var confirmingSignOut = false
    @State private var hovering = false

    private var usage: AccountUsage? { store.planUsage["\(harness.id)|\(account.id)"] }
    private var isChosen: Bool {
        store.assistant.map { $0.harness.id == harness.id && $0.account?.id == account.id } ?? false
    }
    private var title: String { account.identity ?? usage?.identity ?? (account.isDefault ? "Default account" : account.label) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(account.status == .signedIn ? HealthBand.excellent.color : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(Color.label)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                askToggle
                menu
            }
            if let usage {
                if usage.status == .ok, !usage.windows.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 8) {
                        ForEach(usage.windows.prefix(4)) { UsageMeter(window: $0) }
                    }
                    .padding(.leading, 17)
                } else if let message = usage.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(.leading, 17)
                }
            }
        }
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        if let progress = store.signInProgress["\(harness.id)|\(account.id)"] {
            return progress.desired == .signedIn ? "Finish signing in in your browser…" : "Signing out…"
        }
        var parts = [account.isDefault ? "default" : account.label]
        if let plan = usage?.plan ?? account.plan { parts.append(plan) }
        if account.status == .unknown { parts.append("sign-in state unknown") }
        return parts.joined(separator: " · ")
    }

    /// One control instead of a button per row: filled when this account answers
    /// Explain / Find a Fix, a quiet outline on hover otherwise.
    private var askToggle: some View {
        Button {
            store.preferredHarness = "\(harness.id)|\(account.id)"
        } label: {
            Label(isChosen ? "Used for Ask" : "Use for Ask", systemImage: isChosen ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(isChosen ? Color.accentColor.opacity(0.14) : Color.primary.opacity(hovering ? 0.06 : 0)))
                .foregroundStyle(isChosen ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .opacity(isChosen || hovering ? 1 : 0.55)
        .help("Explain and Find a Fix will use this account")
    }

    private var menu: some View {
        Menu {
            if let command = HarnessCommand.launch(harness.descriptor, account: account, values: .init(prompt: "", briefFile: "", briefDir: NSHomeDirectory(), cwd: NSHomeDirectory()))
                .components(separatedBy: " && ").last {
                Button("Open in iTerm") { Terminal.run(command.replacingOccurrences(of: " ''", with: "")) }
            }
            if let home = account.home {
                Button("Reveal Config Folder") { Paths.reveal(home) }
            }
            if let command = HarnessCommand.login(harness.descriptor, account: account) {
                Button("Sign in in iTerm") { Terminal.run(command) }
            }
            if let command = HarnessCommand.logout(harness.descriptor, account: account) {
                Button("Sign out in iTerm…") { Terminal.run(command) }
            }
            Divider()
            if harness.descriptor.logout != nil {
                Button("Sign Out…", role: .destructive) { confirmingSignOut = true }
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .confirmationDialog("Sign \(title) out of \(harness.descriptor.name)?", isPresented: $confirmingSignOut) {
            Button("Sign Out", role: .destructive) { store.signOut(harness, account) }
        } message: {
            Text("Anything using this account, including other agent sessions, will need to sign in again.")
        }
    }
}

/// One plan limit: label, a slim bar that only takes on color near the limit, and
/// when it resets.
private struct UsageMeter: View {
    var window: HarnessKit.UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(window.usedPercent)%").font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(level == .normal ? AnyShapeStyle(Color.label) : AnyShapeStyle(level.tint))
            }
            MeterBar(fraction: Double(window.usedPercent) / 100, color: level.tint)
            if let resets = window.resetsAt {
                Text("resets \(Relative.string(resets).replacingOccurrences(of: "in ", with: "in "))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var level: Level {
        window.usedPercent >= 90 ? .critical : (window.usedPercent >= 75 ? .elevated : .normal)
    }
}

/// "with Claude Code · work ▾" under the Ask buttons: switch agent or account in place.
struct HarnessPicker: View {
    @Bindable var store: AppStore
    var current: (harness: HarnessInstallation, account: HarnessAccount?)

    var body: some View {
        Menu {
            ForEach((store.harnesses.value ?? []).filter(\.isInstalled)) { harness in
                Section(harness.descriptor.name) {
                    ForEach(harness.accounts.filter { $0.status != .signedOut }) { account in
                        Button {
                            store.preferredHarness = "\(harness.id)|\(account.id)"
                        } label: {
                            Text(label(account))
                        }
                    }
                }
            }
            Divider()
            Button("Manage Agents…") { store.dashboardSection = .agents }
        } label: {
            HStack(spacing: 5) {
                ProviderLogo(harness: current.harness, size: 12)
                Text("with \(current.harness.descriptor.name)" + (current.account.map { $0.isDefault ? "" : " · \($0.label)" } ?? ""))
                    .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
    }

    private func label(_ account: HarnessAccount) -> String {
        let name = account.isDefault ? "Default" : account.label
        return account.identity.map { "\(name) — \($0)" } ?? name
    }
}

/// A provider's logo: the built-in SVG for known harnesses, the descriptor's `icon`
/// file for your own, or a neutral glyph.
struct ProviderLogo: View {
    var harness: HarnessInstallation
    var size: CGFloat

    var body: some View {
        // Sized on the NSImage itself: inside a Menu label AppKit draws the image at its
        // own size and ignores SwiftUI's frame, which blew Claude's 248-unit mark up.
        if let image = ProviderLogos.image(for: harness.descriptor, size: size) {
            Image(nsImage: image)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkle").font(.system(size: size * 0.7)).foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

enum ProviderLogos {
    private static var cache: [String: NSImage] = [:]

    /// A stand-in installation for a harness known only by name (a saved conversation),
    /// so its logo can still be drawn.
    static func installation(named name: String) -> HarnessInstallation? {
        HarnessRegistry.load().descriptors.first { $0.name == name }
            .map { HarnessInstallation(descriptor: $0, executable: nil, accounts: []) }
    }

    /// The logo fitted into a `size`-point square, aspect ratio kept (Grok's mark is wide).
    static func image(for descriptor: HarnessDescriptor, size: CGFloat) -> NSImage? {
        guard let source = image(for: descriptor) else { return nil }
        let scale = min(size / max(source.size.width, 1), size / max(source.size.height, 1))
        let fitted = NSSize(width: source.size.width * scale, height: source.size.height * scale)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: NSRect(x: (rect.width - fitted.width) / 2, y: (rect.height - fitted.height) / 2,
                                   width: fitted.width, height: fitted.height))
            return true
        }
    }

    static func image(for descriptor: HarnessDescriptor) -> NSImage? {
        if let cached = cache[descriptor.id] { return cached }
        var data: Data?
        if let icon = descriptor.icon {
            let path = icon.hasPrefix("~") ? NSHomeDirectory() + icon.dropFirst() : icon
            data = try? Data(contentsOf: URL(fileURLWithPath: path))
        } else if let svg = ProviderLogoData.svg[descriptor.id] {
            data = Data(svg.utf8)
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        cache[descriptor.id] = image
        return image
    }
}
