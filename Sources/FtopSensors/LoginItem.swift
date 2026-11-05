import Foundation
import FtopCore
import ServiceManagement

/// Opening at login, through the system's own registration of the app itself: no helper
/// and no launch agent file. Nothing here runs unless the user turns it on or off.
@MainActor
public enum LoginItem {
    /// Read from the system each time.
    public static var state: LoginItemState {
        guard LoginItemState.isInstalled(Bundle.main.bundleURL, in: LoginItemState.installFolders) else { return .notInstalled }
        return state(of: SMAppService.mainApp.status)
    }

    private static func state(of status: SMAppService.Status) -> LoginItemState {
        switch status {
        // The app itself can be "not found" until it is first registered.
        case .notRegistered, .notFound: .off
        case .enabled: .on
        case .requiresApproval: .needsApproval
        @unknown default: .unknown
        }
    }

    /// Registers or unregisters the app, then reads the state again: what the system
    /// reports afterwards is the result, not that the call returned. The error, if any,
    /// is for the log.
    public static func set(_ on: Bool) -> (state: LoginItemState, error: String?) {
        guard state != .notInstalled else { return (.notInstalled, nil) }
        var failure: String?
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = String(describing: error)
        }
        return (state, failure)
    }

    /// System Settings, at Login Items, where the user allows it or turns it off.
    public static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
