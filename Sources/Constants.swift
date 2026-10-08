import Foundation

/// App-wide constants.
enum KK {
    /// The bundle identifier is the single source of truth in Info.plist; everything
    /// else (daemon label, socket, plist path) is derived from it.
    static let fallbackBundleID = "io.github.ydx64.keyboardlock"
    static let bundleID = Bundle.main.bundleIdentifier ?? fallbackBundleID
    static let daemonLabel = bundleID + ".helper"

    /// Socket of the persistent helper service. /var/run is writable by root only,
    /// so an unprivileged process cannot plant a fake server there.
    static let defaultSocket = "/var/run/" + bundleID + ".sock"
    static let daemonPlist = "/Library/LaunchDaemons/" + daemonLabel + ".plist"
    static let installedApp = "/Applications/KeyboardLock.app"
    static let executableName = "KeyboardLock"

    /// Protocol version shared by the app and the helper. Bump it whenever the helper
    /// changes; a mismatch makes the app offer an "Update" button.
    static let protocolVersion = 1

    /// A different socket path may be given through the environment (testing only).
    static var socketPath: String {
        ProcessInfo.processInfo.environment["KK_SOCKET"] ?? defaultSocket
    }
}
