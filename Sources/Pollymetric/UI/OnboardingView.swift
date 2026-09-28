import HarnessKit
import SwiftUI

/// The command-line tools Pollymetric builds on, and how Homebrew installs each.
struct SupportTool: Identifiable {
    var id: String { name }
    var name: String
    var purpose: String
    var formula: String?
    var cask: String?
    var isInstalled: () -> Bool

    static let all: [SupportTool] = [
        .init(name: "Mole", purpose: "cache cleanup and build folders", formula: "mole", isInstalled: { Shell.which("mo") != nil }),
        .init(name: "KnockKnock", purpose: "launch items", cask: "knockknock",
              isInstalled: { FileManager.default.fileExists(atPath: KnockKnock.app) }),
        .init(name: "Lynis", purpose: "security audit", formula: "lynis", isInstalled: { Shell.which("lynis") != nil }),
        .init(name: "btop", purpose: "live processes", formula: "btop", isInstalled: { Shell.which("btop") != nil }),
        .init(name: "dua", purpose: "disk map", formula: "dua-cli", isInstalled: { Shell.which("dua") != nil }),
        .init(name: "kondo", purpose: "per-project cleanup", formula: "kondo", isInstalled: { Shell.which("kondo") != nil }),
    ]

    static var homebrew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// First-run setup: one page, four steps, each with its live state and one action.
/// Nothing is required; every step says what it unlocks.
struct OnboardingView: View {
    @Bindable var store: AppStore
    var done: () -> Void

    @State private var installed: Set<String> = []
    @State private var installing = false
    @State private var installMessage: String?
    private let fdaTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var missingTools: [SupportTool] { SupportTool.all.filter { !installed.contains($0.name) } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: Self.icon).resizable().frame(width: 96, height: 96)
                Text("Welcome to Pollymetric").font(.system(size: 26, weight: .semibold))
                Text("It lives in your menu bar and shows what's running on this Mac, including what your AI agents leave behind. A few things help it work best. All of them are optional.")
                    .font(.system(size: 14)).lineSpacing(3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
            }
            .padding(.top, 40).padding(.bottom, 26)

            VStack(spacing: 0) {
                step(done: store.loginItem.isOn, title: "Start at login",
                     detail: "So its history keeps recording, and it's there when something spikes.") {
                    if store.loginItem.isOn { doneLabel } else {
                        Button("Turn On") { store.loginItem.set(true) }
                    }
                }
                Divider().padding(.leading, 52)
                step(done: store.hasFullDiskAccess, title: "Full Disk Access",
                     detail: store.hasFullDiskAccess
                        ? "Pollymetric can check your whole Mac without interrupting you."
                        : "So Pollymetric can find space to free and check startup items without asking about each folder. Switch Pollymetric on in the list; this updates by itself.") {
                    if store.hasFullDiskAccess { doneLabel } else {
                        Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                    }
                }
                Divider().padding(.leading, 52)
                step(done: missingTools.isEmpty, title: "Cleanup and security",
                     detail: toolsDetail) {
                    toolsAction
                }
                Divider().padding(.leading, 52)
                step(done: !installedAgents.isEmpty, title: "AI agents", optional: true,
                     detail: store.harnesses.value == nil
                        ? "Looking for agents like Claude Code and Codex…"
                        : installedAgents.isEmpty
                        ? "Explain and Find a Fix use a local agent like Claude Code or Codex. None found yet. You can add one later."
                        : "Found \(installedAgents.map(\.descriptor.name).joined(separator: ", ")). Explain and Find a Fix will use them.") {
                    if store.harnesses.value == nil {
                        ProgressView().controlSize(.small)
                    } else if installedAgents.isEmpty {
                        Button("Learn More") { NSWorkspace.shared.open(URL(string: "https://docs.anthropic.com/claude-code")!) }
                    } else { doneLabel }
                }
            }
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
            .padding(.horizontal, 32)

            Spacer(minLength: 20)

            HStack {
                Text("You can come back to this in Settings → General.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { done() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(.horizontal, 32).padding(.bottom, 26)
        }
        .frame(width: 580, height: 660)
        .onAppear {
            refreshTools(); store.loginItem.refresh(); store.recheckFullDiskAccess()
            store.harnesses.refreshIfStale()
        }
        .onReceive(fdaTimer) { _ in store.recheckFullDiskAccess(); store.loginItem.refresh() }
    }

    /// Drawn from the logo code, so it's right even in builds without a bundle icon.
    private static let icon: NSImage = {
        guard let rep = LogoMark.appIcon(pixels: 256) else { return NSApp.applicationIconImage }
        let image = NSImage(size: NSSize(width: 128, height: 128))
        image.addRepresentation(rep)
        return image
    }()

    private var installedAgents: [HarnessInstallation] { (store.harnesses.value ?? []).filter(\.isInstalled) }

    private var doneLabel: some View {
        Label("Done", systemImage: "checkmark.circle.fill")
            .labelStyle(.titleAndIcon).foregroundStyle(HealthBand.excellent.color).font(.callout.weight(.medium))
    }

    private var toolsDetail: String {
        if missingTools.isEmpty { return "Cleanup, startup-item checks and the security audit are ready." }
        if let installMessage { return installMessage }
        return SupportTool.homebrew == nil
            ? "Adds cleanup, startup-item checks and a security audit. Needs Homebrew, the free Mac app installer. Everything else works without it."
            : "Adds cleanup, startup-item checks and a security audit. Everything else works without them."
    }

    @ViewBuilder
    private var toolsAction: some View {
        if missingTools.isEmpty {
            doneLabel
        } else if installing {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…").font(.callout).foregroundStyle(.secondary) }
        } else if SupportTool.homebrew != nil {
            Button(missingTools.count == 1 ? "Install" : "Install \(missingTools.count)") { install() }
                .help("Installs \(missingTools.map(\.name).joined(separator: ", ")) with Homebrew.")
        } else {
            Button("Get Homebrew") { NSWorkspace.shared.open(URL(string: "https://brew.sh")!) }
        }
    }

    private func step<Action: View>(done: Bool, title: String, optional: Bool = false, detail: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? HealthBand.excellent.color : Color.primary.opacity(0.07)).frame(width: 24, height: 24)
                Image(systemName: done ? "checkmark" : "circle.dotted")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(done ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            }
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if optional { Text("Optional").font(.caption2.weight(.medium)).foregroundStyle(.secondary) }
                }
                Text(detail).font(.system(size: 13)).lineSpacing(2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            action().controlSize(.regular)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private func refreshTools() {
        installed = Set(SupportTool.all.filter { $0.isInstalled() }.map(\.name))
    }

    /// `brew install` for the missing formulae, then the missing casks. Output stays out
    /// of sight; the step reports what happened.
    private func install() {
        guard let brew = SupportTool.homebrew else { return }
        let formulae = missingTools.compactMap(\.formula)
        let casks = missingTools.compactMap(\.cask)
        installing = true
        installMessage = nil
        Task {
            var failed: [String] = []
            if !formulae.isEmpty {
                let result = try? await Shell.run(brew, ["install"] + formulae, disclaim: true, timeout: 1_800)
                if result?.status != 0 { failed.append(contentsOf: formulae) }
            }
            if !casks.isEmpty {
                let result = try? await Shell.run(brew, ["install", "--cask"] + casks, disclaim: true, timeout: 1_800)
                if result?.status != 0 { failed.append(contentsOf: casks) }
            }
            refreshTools()
            installing = false
            if !failed.isEmpty {
                installMessage = "Homebrew couldn't install \(failed.joined(separator: ", ")). Try `brew install \(failed.joined(separator: " "))` in a terminal to see why."
            }
        }
    }
}
