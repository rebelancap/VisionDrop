import Foundation
import Network
#if os(macOS)
import SystemConfiguration
#endif

/// Which kind of local interface a socket landed on. The receiver classifies
/// each blast connection and reports the class in its pong (PU/PW), so the
/// sender's badge reflects the actual path — bandwidth alone can't distinguish
/// fast home WiFi from the strap.
enum IfClass { case wired, wifi, unknown }

final class InterfaceClassifier {
    static let shared = InterfaceClassifier()

    private let lock = NSLock()
    private var nwTypes: [String: NWInterface.InterfaceType] = [:]
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock()
            for i in path.availableInterfaces { self.nwTypes[i.name] = i.type }
            self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "visiondrop.ifclass"))
    }

    /// Class of the local interface a connected/accepted socket is using.
    func classify(fd: Int32) -> IfClass {
        guard let (ip, scopedIf) = Self.localEndpoint(fd),
              let name = scopedIf ?? Self.interfaceName(owning: ip) else { return .unknown }
        return classify(interfaceName: name)
    }

    func classify(interfaceName name: String) -> IfClass {
        lock.lock()
        let nw = nwTypes[name]
        lock.unlock()
        switch nw {
        case .wiredEthernet: return .wired
        case .wifi: return .wifi
        default: break
        }
        // NW never lists bridges (the Mac's USB path when bridging) — but a
        // bridge here is Thunderbolt/USB members by construction.
        if name.hasPrefix("bridge") { return .wired }
        #if os(macOS)
        if let t = Self.scType(of: name) {
            return t == (kSCNetworkInterfaceTypeIEEE80211 as String) ? .wifi : .wired
        }
        #endif
        return .unknown
    }

    #if os(macOS)
    private static func scType(of bsdName: String) -> String? {
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        for i in all where (SCNetworkInterfaceGetBSDName(i) as String?) == bsdName {
            return SCNetworkInterfaceGetInterfaceType(i) as String?
        }
        return nil
    }
    #endif

    /// Local (our-side) IP of a socket, plus the owning interface when the
    /// kernel scoped it (link-local v6). v4-mapped v6 from the dual-stack
    /// listener is unwrapped to plain v4.
    private static func localEndpoint(_ fd: Int32) -> (ip: String, ifName: String?)? {
        var ss = sockaddr_storage()
        var slen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &slen) }
        }
        guard rc == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if ss.ss_family == sa_family_t(AF_INET) {
            var sin = withUnsafePointer(to: ss) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(buf.count)) != nil else { return nil }
            return (String(cString: buf), nil)
        }
        guard ss.ss_family == sa_family_t(AF_INET6) else { return nil }
        var sin6 = withUnsafePointer(to: ss) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
        }
        let a8 = sin6.sin6_addr.__u6_addr.__u6_addr8
        let v4Mapped = a8.0 == 0 && a8.1 == 0 && a8.2 == 0 && a8.3 == 0 && a8.4 == 0
            && a8.5 == 0 && a8.6 == 0 && a8.7 == 0 && a8.8 == 0 && a8.9 == 0
            && a8.10 == 0xff && a8.11 == 0xff
        if v4Mapped {
            var v4 = in_addr(s_addr: sin6.sin6_addr.__u6_addr.__u6_addr32.3)
            guard inet_ntop(AF_INET, &v4, &buf, socklen_t(buf.count)) != nil else { return nil }
            return (String(cString: buf), nil)
        }
        var ifName: String?
        if sin6.sin6_scope_id != 0 {
            var nbuf = [CChar](repeating: 0, count: 64)
            if if_indextoname(sin6.sin6_scope_id, &nbuf) != nil { ifName = String(cString: nbuf) }
        }
        guard inet_ntop(AF_INET6, &sin6.sin6_addr, &buf, socklen_t(buf.count)) != nil else { return nil }
        return (String(cString: buf), ifName)
    }

    /// Interface holding `ip` locally, any family, zone stripped.
    private static func interfaceName(owning ip: String) -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return nil }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr = ifaddrPtr
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next
            guard let sa = ifa.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET) || sa.pointee.sa_family == sa_family_t(AF_INET6)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var addr = String(cString: host)
            if let pct = addr.firstIndex(of: "%") { addr = String(addr[..<pct]) }
            if addr == ip { return String(cString: ifa.ifa_name) }
        }
        return nil
    }
}
