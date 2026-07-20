import Foundation

/// A raw-socket endpoint: address (v4 or v6), optional interface scope for
/// link-locals, and port.
struct BSDEndpoint: CustomStringConvertible {
    let addr: String
    let scopeIf: String?
    let port: UInt16
    var description: String { scopeIf.map { "\(addr)%\($0):\(port)" } ?? "\(addr):\(port)" }
}

/// Raw BSD-socket data plane. Network.framework's path evaluation refuses to
/// route app traffic over bridge interfaces to link-local peers ("interface
/// not available"), and its receive path tops out well below the link rate —
/// kernel sockets have neither problem. This is the same hot path curl uses.
enum BSDSocket {
    /// Blocking TCP connect with a poll-based timeout. Returns a connected,
    /// blocking fd tuned for bulk transfer, or nil.
    static func connect(_ ep: BSDEndpoint, timeoutMs: Int32 = 1500) -> Int32? {
        var storage = sockaddr_storage()
        var salen: socklen_t = 0
        let isV6 = ep.addr.contains(":")
        if isV6 {
            var sin6 = sockaddr_in6()
            sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_port = ep.port.bigEndian
            let ok = withUnsafeMutablePointer(to: &sin6.sin6_addr) { inet_pton(AF_INET6, ep.addr, $0) }
            guard ok == 1 else { return nil }
            if let ifn = ep.scopeIf {
                sin6.sin6_scope_id = if_nametoindex(ifn)
                guard sin6.sin6_scope_id != 0 else { return nil }
            }
            withUnsafeBytes(of: sin6) { storage.copyIn($0) }
            salen = socklen_t(MemoryLayout<sockaddr_in6>.size)
        } else {
            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_port = ep.port.bigEndian
            let ok = withUnsafeMutablePointer(to: &sin.sin_addr) { inet_pton(AF_INET, ep.addr, $0) }
            guard ok == 1 else { return nil }
            withUnsafeBytes(of: sin) { storage.copyIn($0) }
            salen = socklen_t(MemoryLayout<sockaddr_in>.size)
        }
        let fd = socket(isV6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var bufSize: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var rc = withUnsafeMutablePointer(to: &storage) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, salen) }
        }
        if rc != 0 && errno != EINPROGRESS {
            close(fd)
            return nil
        }
        if rc != 0 {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeoutMs) > 0 else { close(fd); return nil }
            var soErr: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
            guard soErr == 0 else { close(fd); return nil }
        }
        rc = fcntl(fd, F_SETFL, flags) // back to blocking
        return fd
    }

    static func sendAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) -> Bool {
        var off = 0
        while off < count {
            let n = write(fd, ptr + off, count - off)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                return false
            }
            off += n
        }
        return true
    }

    static func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            return sendAll(fd, base, raw.count)
        }
    }

    static func recvExact(_ fd: Int32, count: Int, timeoutMs: Int32 = 30000) -> Data? {
        var tv = timeval(tv_sec: Int(timeoutMs / 1000), tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = Data(count: count)
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var got = 0
            while got < count {
                let n = read(fd, base + got, count - got)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    return false
                }
                got += n
            }
            return true
        }
        return ok ? out : nil
    }
}

private extension sockaddr_storage {
    mutating func copyIn(_ bytes: UnsafeRawBufferPointer) {
        withUnsafeMutableBytes(of: &self) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes.prefix(dst.count)))
        }
    }
}
