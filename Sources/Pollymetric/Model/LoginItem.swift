import Foundation
import Observation
import ServiceManagement

/// "Start Pollymetric when you log in", backed by SMAppService.
///
/// The status is stored rather than read on demand so SwiftUI sees it change, and it
/// covers the case the old toggle hid: macOS sometimes registers the item but waits for
/// you to allow it in System Settings → General → Login Items.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var error: String?

    var isOn: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    /// Re-read after you might have changed it in System Settings.
    func refresh() { status = SMAppService.mainApp.status }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
