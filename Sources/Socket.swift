import Foundation
import Darwin

// MARK: - Unix socket helpers (app <-> privileged helper process)

func makeSockAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8.prefix(100))
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
    }
    return addr
}

func connectAddr(_ fd: Int32, _ addr: inout sockaddr_un) -> Int32 {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

func bindAddr(_ fd: Int32, _ addr: inout sockaddr_un) -> Int32 {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

func setTimeouts(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

/// Writes a single line of text.
func writeLine(_ fd: Int32, _ text: String) {
    let bytes = Array((text + "\n").utf8)
    var sent = 0
    while sent < bytes.count {
        let n = bytes[sent...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        sent += n
    }
}

/// Reads a line terminated by '\n' within a TOTAL time limit (at most 512 bytes).
/// A slow-dripping client cannot extend this time. If no line terminator arrives,
/// returns nil, so a half-received command is never executed.
func readLine(_ fd: Int32, totalSeconds: Double = 1.5) -> String? {
    let end = ProcessInfo.processInfo.systemUptime + totalSeconds
    var data = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 128)
    while data.count < 512 {
        let remainingMs = Int32(max(0, (end - ProcessInfo.processInfo.systemUptime) * 1000))
        if remainingMs == 0 { return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&pfd, 1, remainingMs) <= 0 { return nil }
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 { return nil }
        if let nl = buf[0..<n].firstIndex(of: 0x0A) {
            data.append(contentsOf: buf[0..<nl])
            return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
        }
        data.append(contentsOf: buf[0..<n])
    }
    return nil
}
