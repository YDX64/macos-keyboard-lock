import SwiftUI

// The same program runs in three modes:
//   (no arguments)         -> the app with its window
//   --daemon <uid> [sock]  -> the lock service that runs as root (started by launchd)
//   --print-install-script / --print-uninstall-script / --print-cdhash -> testing only
let arguments = CommandLine.arguments

if arguments.count >= 3, arguments[1] == "--daemon" {
    let owner = uid_t(arguments[2]) ?? getuid()
    let path = arguments.count >= 4 ? arguments[3] : KK.defaultSocket
    LockHelper(socketPath: path, ownerUID: owner).run()
} else if arguments.count >= 9, arguments[1] == "--print-install-script" {
    // --print-install-script <src> <dst> <plist> <uid> <owner> <launchctl> <cdhash>
    print(Installer.installScript(src: arguments[2], dst: arguments[3], plistPath: arguments[4],
                                  uid: uid_t(arguments[5]) ?? getuid(),
                                  expectedCDHash: arguments[8],
                                  owner: arguments[6], launchctl: arguments[7]))
} else if arguments.count >= 2, arguments[1] == "--print-cdhash" {
    // Testing only: the code directory hash of this running binary (the installer compares it).
    print(CodeIdentity.ownCDHash() ?? "")
} else if arguments.count >= 5, arguments[1] == "--print-uninstall-script" {
    // --print-uninstall-script <plist> <socket> <launchctl>
    print(Installer.uninstallScript(plistPath: arguments[2], socketPath: arguments[3], launchctl: arguments[4]))
} else {
    KeyboardLockApp.main()
}
