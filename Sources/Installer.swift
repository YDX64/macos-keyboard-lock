import Foundation

/// One-time setup: copies the app to /Applications as a root-owned bundle and registers the
/// lock service as a launchd LaunchDaemon. After that, locking never asks for a password.
///
/// Why a root-owned copy? The service runs the program inside that copy as root. If the copy
/// lived in a place the user can write to, any process running as that user could replace the
/// binary and gain root.
enum Installer {
    enum Result {
        case success
        case cancelled
        case failed(String)
    }

    static var installedPlistExists: Bool {
        FileManager.default.fileExists(atPath: KK.daemonPlist)
    }

    // MARK: Quoting helpers

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Scripts

    static func plistXML(executable: String, uid: uid_t) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(xmlEscape(KK.daemonLabel))</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xmlEscape(executable))</string>
                <string>--daemon</string>
                <string>\(uid)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ThrottleInterval</key>
            <integer>5</integer>
            <key>StandardOutPath</key>
            <string>/dev/null</string>
            <key>StandardErrorPath</key>
            <string>/dev/null</string>
        </dict>
        </plist>

        """
    }

    /// The script that runs as root. The parameters let tests run it in a scratch folder with
    /// a fake `launchctl`.
    ///
    /// `expectedCDHash` is the code directory hash of the *running* app. The script refuses to
    /// install a copy whose hash differs, so a bundle swapped after launch is never trusted.
    static func installScript(src: String, dst: String, plistPath: String, uid: uid_t,
                              expectedCDHash: String,
                              owner: String = "root:wheel", launchctl: String = "/bin/launchctl") -> String {
        let exe = dst + "/Contents/MacOS/" + KK.executableName
        let plist = plistXML(executable: exe, uid: uid)
        return """
        set -eu
        SRC=\(shellQuote(src))
        DST=\(shellQuote(dst))
        PLIST=\(shellQuote(plistPath))
        LABEL=\(shellQuote(KK.daemonLabel))
        LC=\(shellQuote(launchctl))
        OWNER=\(shellQuote(owner))
        EXPECTED=\(shellQuote(expectedCDHash))

        # 1) Prepare and verify the target before touching the old service.
        #    If any step fails, the half-finished copy is removed.
        trap '/bin/rm -rf "$DST.new"' EXIT
        if [ "$SRC" != "$DST" ]; then
          TARGET="$DST.new"
          /bin/rm -rf "$TARGET"
          /usr/bin/ditto "$SRC" "$TARGET"
        else
          TARGET="$DST"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" >/dev/null 2>&1 || true
        /usr/sbin/chown -R "$OWNER" "$TARGET"
        /bin/chmod -R go-w "$TARGET"
        /usr/bin/codesign --verify --strict "$TARGET"

        # 2) The copy must be exactly the program the user launched (same code directory hash).
        ACTUAL=$(/usr/bin/codesign -d --verbose=4 "$TARGET" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p')
        if [ -z "$EXPECTED" ] || [ "$ACTUAL" != "$EXPECTED" ]; then
          echo "The copy does not match the app that was launched; refusing to install." >&2
          exit 1
        fi

        # 3) Stop the old service and put the copy in place.
        "$LC" bootout "system/$LABEL" >/dev/null 2>&1 || true
        if [ "$TARGET" != "$DST" ]; then
          /bin/rm -rf "$DST"
          /bin/mv "$TARGET" "$DST"
        fi

        # 4) Write the service definition (root-owned) and start it.
        /usr/bin/printf '%s' \(shellQuote(plist)) > "$PLIST.tmp"
        /usr/sbin/chown "$OWNER" "$PLIST.tmp"
        /bin/chmod 644 "$PLIST.tmp"
        /bin/mv -f "$PLIST.tmp" "$PLIST"
        /usr/bin/plutil -lint "$PLIST" >/dev/null
        "$LC" bootstrap system "$PLIST"
        """
    }

    static func uninstallScript(plistPath: String, socketPath: String,
                                launchctl: String = "/bin/launchctl") -> String {
        """
        set -u
        LC=\(shellQuote(launchctl))
        "$LC" bootout "system/\(KK.daemonLabel)" >/dev/null 2>&1 || true
        /bin/rm -f \(shellQuote(plistPath)) \(shellQuote(socketPath))
        """
    }

    // MARK: Privileged execution (macOS's own password dialog)

    private static let lock = NSLock()
    private static var current: Process?

    /// Closes a password dialog (osascript) that is still open; called when the app quits.
    static func cancelPending() {
        lock.lock()
        let p = current
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    static func runPrivileged(_ script: String, prompt: String) -> Result {
        let source = "do shell script \"\(appleScriptEscape(script))\" with administrator privileges "
            + "with prompt \"\(appleScriptEscape(prompt))\""

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        do { try proc.run() } catch { return .failed(tr("err.promptFailed", error.localizedDescription)) }
        lock.lock(); current = proc; lock.unlock()
        proc.waitUntilExit()
        lock.lock(); current = nil; lock.unlock()

        let errText = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if proc.terminationStatus == 0 { return .success }
        if errText.contains("-128") || errText.lowercased().contains("cancel") { return .cancelled }
        return .failed(errText.isEmpty ? tr("err.unknown", proc.terminationStatus) : errText)
    }
}
