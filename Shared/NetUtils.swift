import Foundation

enum NetUtils {
    /// Interfaces that can carry a transfer. `bridge*` matters: when the Mac
    /// runs the USB bridge, the member NICs (en1/en2) have no addresses of
    /// their own — bridge0 holds the link-local, and scoped connects only
    /// succeed through it.
    static func isUsable(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge")
    }

    /// IPv4 addresses of all up, non-loopback usable interfaces.
    static func ipv4Addresses() -> [String] {
        collect(family: sa_family_t(AF_INET))
    }

    /// IPv6 link-local addresses (zone stripped) of `en*` interfaces. These are
    /// self-assigned — no DHCP — so the USB link always has one even when the
    /// bridge/DHCP setup is broken. The sender re-scopes them to each of its
    /// own interfaces when probing.
    static func ipv6LinkLocalAddresses() -> [String] {
        collect(family: sa_family_t(AF_INET6), linkLocalOnly: true)
    }

    /// Routable (non-link-local) IPv6 — SLAAC ULAs/globals. These reach the
    /// fast NIC across the bridge as ordinary scope-free addresses: no DHCP
    /// needed, and immune to the scoped-connect ENETDOWN some app contexts
    /// impose on `%zone` link-local connects.
    static func ipv6RoutableAddresses() -> [String] {
        collect(family: sa_family_t(AF_INET6), linkLocalOnly: false)
    }

    /// Names of up, non-loopback usable interfaces on this machine — the scope
    /// candidates for probing peer link-local addresses.
    static func interfaceNames() -> [String] {
        var result: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return result }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr = ifaddrPtr
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)
            guard isUsable(name), flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            if !result.contains(name) { result.append(name) }
        }
        return result
    }

    /// Up interfaces that hold their own IPv6 link-local — the only valid
    /// scopes for connecting to a peer's link-local (a source address must
    /// exist). Bridges sort first: on a bridging Mac the bridge, not its
    /// member NICs, is the scope that reaches USB peers.
    static func ll6CapableInterfaceNames() -> [String] {
        var names: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return names }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr = ifaddrPtr
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET6) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard isUsable(name) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let isLL = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                sin6.pointee.sin6_addr.__u6_addr.__u6_addr8.0 == 0xfe &&
                (sin6.pointee.sin6_addr.__u6_addr.__u6_addr8.1 & 0xc0) == 0x80
            }
            if isLL, !names.contains(name) { names.append(name) }
        }
        return names.sorted { a, b in
            let ab = a.hasPrefix("bridge"), bb = b.hasPrefix("bridge")
            if ab != bb { return ab }
            return a < b
        }
    }

    private static func collect(family: sa_family_t, linkLocalOnly: Bool = false) -> [String] {
        var result: [String] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return result }
        defer { freeifaddrs(ifaddrPtr) }
        var ptr = ifaddrPtr
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == family else { continue }
            let name = String(cString: ifa.ifa_name)
            guard isUsable(name) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            if family == sa_family_t(AF_INET6) {
                let isLL = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                    sin6.pointee.sin6_addr.__u6_addr.__u6_addr8.0 == 0xfe &&
                    (sin6.pointee.sin6_addr.__u6_addr.__u6_addr8.1 & 0xc0) == 0x80
                }
                if linkLocalOnly != isLL { continue }
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                var ip = String(cString: host)
                if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) } // strip zone
                if !result.contains(ip) { result.append(ip) }
            }
        }
        return result
    }
}
