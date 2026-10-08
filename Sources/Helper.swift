import Foundation
import IOKit
import IOKit.hid
import Darwin

/// Persistent lock service that runs as root (launchd LaunchDaemon, `--daemon` mode).
///
/// Its only job: open the HID interfaces of the selected external keyboards with
/// "seize" (exclusive access). Key events then never reach the system, but the
/// device stays connected and powered over USB; the keyboard's lights stay on.
///
/// The service is installed once, with an administrator password. After that, locking
/// and unlocking need no password. While idle it touches no keyboard; after a restart
/// the lock always starts out released.
///
/// Protocol (Unix socket, line-based):
///   LOCK <seconds> <vid:pid,vid:pid>  -> OK <seized interfaces> <error> <seconds left> <wanted keyboards>
///   UNLOCK                            -> same format
///   STATUS | PING                     -> same format
///   QUIT                              -> same format (only releases the lock; the service keeps running)
///   VERSION                           -> OK <protocol version>
///
/// Safety nets:
///  - The built-in keyboard is never seized under any circumstances.
///  - If no heartbeat (STATUS) arrives from the app for 20 seconds, the lock is released (the service keeps running).
///  - For a timed lock, the lock is released automatically when the time is up.
///  - When the process dies, the operating system releases the seize on its own.
final class LockHelper {
    private let socketPath: String
    private let ownerUID: uid_t
    private let watcher = DeviceWatcher()

    private var wanted = Set<String>()
    private var seized: [IOHIDDevice] = []
    private var lastError: UInt32 = 0
    /// Per-interface "page.usage=error" entries from the last LOCK (0 = success). For diagnostics.
    private var report: [String] = []
    private var deadline: TimeInterval?
    private var lastContact: TimeInterval = ProcessInfo.processInfo.systemUptime

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var signalSources: [DispatchSourceSignal] = []
    private var housekeeping: Timer?

    private let heartbeatLimit: TimeInterval = 20
    private static let maxSecondsWithoutBuiltIn = 3600

    init(socketPath: String, ownerUID: uid_t) {
        self.socketPath = socketPath
        self.ownerUID = ownerUID
    }

    // MARK: Running

    func run() -> Never {
        installSignalHandlers()

        watcher.onAdd = { [unowned self] device in self.seizeIfWanted(device) }
        watcher.onRemove = { [unowned self] device in self.forget(device) }
        watcher.start()

        guard startSocket() else { exit(2) }

        housekeeping = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [unowned self] _ in
            self.tick()
        }
        RunLoop.main.run()
        exit(0)
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [unowned self] in self.exitCleanly() }
            src.resume()
            signalSources.append(src)
        }
    }

    /// When the service is stopped (launchctl bootout / system shutdown): release the lock, remove the socket.
    private func exitCleanly() -> Never {
        releaseAll()
        if listenFD >= 0 { close(listenFD) }
        unlink(socketPath)
        exit(0)
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func tick() {
        // Use the monotonic clock instead of wall-clock time: durations stay correct even if the clock is set back.
        if let d = deadline, now() >= d { releaseAll() }
        // If the heartbeat from the app stops (app crashed/quit), release the lock; the service stays up.
        if now() - lastContact > heartbeatLimit, !wanted.isEmpty || !seized.isEmpty { releaseAll() }
    }

    // MARK: Seize

    private func seizeIfWanted(_ device: IOHIDDevice) {
        guard !wanted.isEmpty,
              let id = keyboardID(device), wanted.contains(id),
              !isBuiltInKeyboard(device),
              isKeyInterface(device),
              !seized.contains(where: { CFEqual($0, device) }) else { return }

        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        let page = hidInt(device, kIOHIDPrimaryUsagePageKey) ?? 0
        let usage = hidInt(device, kIOHIDPrimaryUsageKey) ?? 0
        report.append("\(page).\(usage)=\(UInt32(bitPattern: r))")
        if r == kIOReturnSuccess {
            seized.append(device)
        } else {
            lastError = UInt32(bitPattern: r)
        }
    }

    private func forget(_ device: IOHIDDevice) {
        seized.removeAll { CFEqual($0, device) }
    }

    private func releaseAll() {
        for d in seized { IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeSeizeDevice)) }
        seized.removeAll()
        wanted.removeAll()
        deadline = nil
        lastError = 0
        report.removeAll()
    }

    private func remainingSeconds() -> Int {
        guard let d = deadline else { return 0 }
        return max(0, Int((d - now()).rounded(.up)))
    }

    private func statusReply() -> String {
        "OK \(seized.count) \(lastError) \(remainingSeconds()) \(wanted.count)"
    }

    // MARK: Socket

    private func startSocket() -> Bool {
        // A sockaddr_un path is short; never bind to a silently truncated path.
        guard socketPath.utf8.count <= 100 else { return false }

        // If a live helper already exists, do not start a second one (it must not delete the first one's socket).
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        if probe >= 0 {
            var probeAddr = makeSockAddr(socketPath)
            let alive = connectAddr(probe, &probeAddr) == 0
            close(probe)
            if alive { exit(0) }
        }

        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = makeSockAddr(socketPath)
        // chown/chmod follow symbolic links, and there is a race between them and bind.
        // Instead, create the socket as 0666 from the start; authorization comes only from
        // getpeereid (acceptOne: the peer must be the user themselves or root).
        let oldMask = umask(0)
        let bound = bindAddr(fd, &addr)
        umask(oldMask)
        guard bound == 0 else { close(fd); return false }
        guard listen(fd, 8) == 0 else { close(fd); return false }
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [unowned self] in self.acceptOne() }
        src.resume()
        acceptSource = src
        return true
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        setTimeouts(client, seconds: 2)

        // The peer must be the user themselves (or root).
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(client, &euid, &egid) == 0, euid == ownerUID || euid == 0 else {
            writeLine(client, "ERR denied")
            return
        }

        guard let line = readLine(client) else { return }
        lastContact = now()
        writeLine(client, handle(line))
    }

    private func handle(_ line: String) -> String {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let cmd = parts.first else { return "ERR empty" }

        switch cmd {
        case "PING", "STATUS":
            return statusReply()

        case "VERSION":
            return "OK \(KK.protocolVersion)"

        case "INFO":
            return "OK " + (report.isEmpty ? "-" : report.joined(separator: ","))

        case "UNLOCK", "QUIT":
            releaseAll()
            return statusReply()

        case "LOCK":
            guard parts.count == 3, var secs = Int(parts[1]), secs >= 0, secs <= 86_400 else {
                return "ERR syntax"
            }
            let allowed = CharacterSet(charactersIn: "0123456789:,")
            guard parts[2].unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                return "ERR syntax"
            }
            let keys = Set(parts[2].split(separator: ",").map(String.init))
            guard !keys.isEmpty else { return "ERR syntax" }

            // The service enforces the safety limit itself, not only the app: without a built-in
            // keyboard a lock may last at most one hour, whoever sends the command.
            let hasBuiltIn = watcher.devices().contains { isPrimaryKeyboard($0) && isBuiltInKeyboard($0) }
            if !hasBuiltIn && (secs == 0 || secs > Self.maxSecondsWithoutBuiltIn) {
                secs = Self.maxSecondsWithoutBuiltIn
            }

            releaseAll()
            wanted = keys
            deadline = secs > 0 ? now() + TimeInterval(secs) : nil
            for d in watcher.devices() { seizeIfWanted(d) }
            if seized.isEmpty {
                // None could be seized: report the error code and clear the lock state.
                let err = lastError
                let kept = report
                releaseAll()
                lastError = err
                report = kept
                return "OK 0 \(err) 0 0"
            }
            return statusReply()

        default:
            return "ERR unknown"
        }
    }
}
