import Foundation
import Security

/// Reads the code directory hash (cdhash) of the *running* app.
///
/// The installer copies the app to /Applications as root. Before it trusts that copy it checks
/// that the copy's cdhash equals the cdhash of the app the user actually launched. That closes
/// the window in which an unprivileged process could swap the source bundle between launch and
/// installation. (It cannot protect against the user launching a malicious app in the first
/// place; build from source you trust. See SECURITY.md.)
enum CodeIdentity {
    static func ownCDHash() -> String? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
