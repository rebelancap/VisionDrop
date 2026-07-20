import Foundation

/// Wire protocol v1: each TCP connection carries one stream of one transfer.
/// Frame layout: 6-byte magic, big-endian UInt32 JSON length, JSON `StreamHeader`,
/// then exactly `length` raw payload bytes. Receiver replies "OK" after the last
/// byte lands on disk; ping connections get "PO" immediately.
enum VD {
    static let port: UInt16 = 17777      // NWListener: Bonjour advertising + legacy peers
    static let dataPort: UInt16 = 17778  // raw BSD listener: the fast data plane
    static let service = "_visiondrop._tcp"
    static let magic: [UInt8] = Array("VDRP1".utf8) + [0]
    static let chunkSize = 8 * 1024 * 1024
    static let maxStreams = 4
    static let ackData = Data("OK".utf8)
    static let pongData = Data("PO".utf8)
    static let txtAddrs = "addrs" // IPv4 addresses, comma-separated
    static let txtLL6 = "ll6"     // IPv6 link-locals (no zone) — USB path without DHCP
    static let txtG6 = "g6"       // routable IPv6 (ULA/global) — scope-free fast path
    static let txtDPort = "dport" // BSD data-plane port; absent on old receivers
}

import Network

/// Diagnostic tap for path-selection internals. Nil (silent) in the apps; the
/// CLI tools set it to print.
var vdDebug: ((String) -> Void)?

/// Peer-closed / connection-torn-down errors: shown as a neutral "stopped"
/// state (the other side cancelled or went away), not a red failure.
func isInterruptError(_ error: NWError) -> Bool {
    if case .posix(let code) = error {
        return [.ECONNRESET, .ECONNABORTED, .EPIPE, .ECANCELED,
                .ENOTCONN, .ETIMEDOUT, .ENETDOWN, .ENETRESET].contains(code)
    }
    return false
}

struct StreamHeader: Codable {
    var transferId: String
    var name: String
    var size: Int64
    var offset: Int64
    var length: Int64
    var streamIndex: Int
    var streamCount: Int
    var ping: Bool?
    /// On a ping: receiver must read and discard this many payload bytes before
    /// replying "PO". Used to bandwidth-race candidate paths — the dev strap
    /// exposes both a fast USB4 NIC and a slow USB-CDC one, and handshake
    /// latency can't tell them apart.
    var blast: Int64? = nil

    func encodedFrame() -> Data {
        var d = Data(VD.magic)
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        var len = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &len) { d.append(contentsOf: $0) }
        d.append(json)
        return d
    }

    static func decode(_ json: Data) -> StreamHeader? {
        try? JSONDecoder().decode(StreamHeader.self, from: json)
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func speed(_ bytesPerSec: Double) -> String {
        guard bytesPerSec > 0 else { return "" }
        let gbps = bytesPerSec * 8 / 1e9
        if gbps >= 1 { return String(format: "%.2f GB/s · %.1f Gbps", bytesPerSec / 1e9, gbps) }
        return String(format: "%.0f MB/s", bytesPerSec / 1e6)
    }

    static func eta(remaining: Int64, speed: Double) -> String {
        guard speed > 1, remaining > 0 else { return "" }
        let s = Double(remaining) / speed
        if s < 1 { return "· <1s left" }
        if s < 90 { return String(format: "· %.0fs left", s) }
        return String(format: "· %.1fm left", s / 60)
    }

    static func duration(_ t: TimeInterval) -> String {
        t < 90 ? String(format: "%.1fs", t) : String(format: "%.1fm", t / 60)
    }
}
