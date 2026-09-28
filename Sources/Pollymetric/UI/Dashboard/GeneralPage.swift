import SwiftUI

/// App-wide settings: starting at login and the macOS permissions Pollymetric relies on.
struct GeneralPage: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "General", subtitle: "How Pollymetric starts, and the permissions it uses.",
                       updatedAt: nil, isFetching: false, error: nil, refresh: nil)

            Card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start Pollymetric when you log in").font(.headline)
                        Text("It opens quietly in the menu bar, so its history keeps recording.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Start Pollymetric when you log in",
                           isOn: Binding(get: { store.loginItem.isOn || store.loginItem.needsApproval },
                                         set: { store.loginItem.set($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if store.loginItem.needsApproval {
                    permissionNote("macOS needs your OK before it will start Pollymetric at login.",
                                   button: "Open Login Items") { store.loginItem.openSystemSettings() }
                }
                if let error = store.loginItem.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                }
            }

            Card {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Full Disk Access").font(.headline)
                        Text(store.hasFullDiskAccess
                             ? "On. Cache and launch-item scans run without asking about each folder."
                             : "Off. Scans wait until it's on, so macOS doesn't ask about each folder. Reopen Pollymetric after turning it on.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.hasFullDiskAccess {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(HealthBand.excellent.color)
                    } else {
                        Button("Open Settings") { Permissions.openFullDiskAccessSettings() }
                    }
                }
            }

            maintenance
        }
        .onAppear { store.loginItem.refresh() }
        .confirmationDialog("Uninstall Pollymetric?", isPresented: $confirmingUninstall) {
            Button("Uninstall and Delete History", role: .destructive) { store.uninstall(deletingData: true) }
            Button("Uninstall, Keep History") { store.uninstall(deletingData: false) }
        } message: {
            Text("Pollymetric stops starting at login and moves to the Trash. Deleting history also removes its process history, conversations, connections and settings from this Mac.")
        }
    }

    @State private var confirmingUninstall = false

    private var maintenance: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup").font(.headline)
                    Text("Start at login, Full Disk Access, tools and agents in one place.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show Setup…") { store.showSetup?() }
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                        .font(.headline)
                    Text(Paths.abbreviate(Bundle.main.bundlePath)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
            }
        }
    }

    private func permissionNote(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(text, systemImage: "hand.raised").font(.callout).foregroundStyle(.orange)
            Spacer()
            Button(button, action: action)
        }
    }
}
