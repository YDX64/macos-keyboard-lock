import Foundation
import Darwin

// MARK: - Client that talks to the lock service (app side)

struct StatusReply {
    var count: Int        // number of interfaces currently seized
    var error: UInt32
    var remaining: Int
    var wanted: Int       // number of keyboards that should be locked (even if unplugged)
}

enum LockOutcome {
    case locked(StatusReply)
    case noDevice
    case denied(UInt32)
    case failed(String)
}

enum HelperControl {

    // MARK: Low-level request

    static func request(socket path: String, _ line: String, timeout: Int = 3) -> String? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        setTimeouts(fd, seconds: timeout)
        var addr = makeSockAddr(path)
        guard connectAddr(fd, &addr) == 0 else { return nil }

        // The real service runs as root and lives under /var/run (only root can write there).
        // On the default path, never talk to a non-root server. Only on a custom path given
        // for testing is a server owned by our own user also accepted.
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0 else { return nil }
        let isDefaultPath = path == KK.defaultSocket
        guard peerUID == 0 || (!isDefaultPath && peerUID == getuid()) else { return nil }

        writeLine(fd, line)
        return readLine(fd, totalSeconds: Double(timeout))
    }

    static func parse(_ reply: String?) -> StatusReply? {
        guard let reply else { return nil }
        let p = reply.split(separator: " ").map(String.init)
        guard p.count == 5, p[0] == "OK",
              let c = Int(p[1]), let e = UInt32(p[2]), let r = Int(p[3]), let w = Int(p[4]) else { return nil }
        return StatusReply(count: c, error: e, remaining: r, wanted: w)
    }

    static func status(socket path: String) -> StatusReply? {
        parse(request(socket: path, "STATUS", timeout: 2))
    }

    /// The service's protocol version; nil if there is no reply.
    static func version(socket path: String) -> Int? {
        guard let reply = request(socket: path, "VERSION", timeout: 2) else { return nil }
        let p = reply.split(separator: " ").map(String.init)
        guard p.count == 2, p[0] == "OK" else { return nil }
        return Int(p[1])
    }

    // MARK: High-level operations

    static func lock(socket path: String, seconds: Int, keys: [String]) -> LockOutcome {
        let reply = request(socket: path, "LOCK \(seconds) \(keys.joined(separator: ","))", timeout: 5)
        guard let st = parse(reply) else { return .failed(tr("err.noReply")) }
        if st.count > 0 { return .locked(st) }
        return st.error == 0 ? .noDevice : .denied(st.error)
    }

    static func unlock(socket path: String) -> StatusReply? {
        parse(request(socket: path, "UNLOCK", timeout: 3))
    }

    /// Releases the lock when the app quits (the service keeps running).
    static func release(socket path: String) {
        _ = request(socket: path, "QUIT", timeout: 1)
    }
}
