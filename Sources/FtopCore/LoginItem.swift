import Foundation

/// Whether the app opens at login, as the system reports it. It is not a setting: it is
/// never written to the settings file, only read from the system each time it is shown.
public enum LoginItemState: Sendable, Equatable {
    /// The app is not in /Applications or ~/Applications, so the switch is not offered.
    case notInstalled
    case off
    case on
    /// Registered, and waiting for the user to allow it in Login Items.
    case needsApproval
    /// The system gave an answer ftop does not know.
    case unknown

    /// True when the app at `app` is inside one of `folders`. Links are followed, so a
    /// copy run from a disk image, Downloads, or a translocated path is not installed.
    public static func isInstalled(_ app: URL, in folders: [URL]) -> Bool {
        let path = app.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasSuffix(".app") else { return false }
        return folders.contains { path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }
    }

    /// Where an app has to be for the switch to be offered.
    public static var installFolders: [URL] {
        [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")]
    }
}
