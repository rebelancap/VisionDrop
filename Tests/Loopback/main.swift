import Foundation
import Network

// Loopback harness: drives the production SendJob against the production
// ReceiverModel over 127.0.0.1 and verifies the received bytes.

let tmp = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "/tmp/vd-loopback")
try? FileManager.default.removeItem(at: tmp)
let recvDir = tmp.appendingPathComponent("recv")
try! FileManager.default.createDirectory(at: recvDir, withIntermediateDirectories: true)

// 200 MB random source file (big enough for 4 streams and real chunking)
let src = tmp.appendingPathComponent("src.bin")
let urandom = FileHandle(forReadingAtPath: "/dev/urandom")!
FileManager.default.createFile(atPath: src.path, contents: nil)
let out = try! FileHandle(forWritingTo: src)
for _ in 0..<50 { try! out.write(contentsOf: urandom.read(upToCount: 4 * 1024 * 1024)!) }
try! out.close()
let srcSize = try! FileManager.default.attributesOfItem(atPath: src.path)[.size] as! Int64
print("source ready: \(srcSize) bytes")

func filesEqual(_ a: URL, _ b: URL) -> Bool {
    guard let fa = try? FileHandle(forReadingFrom: a),
          let fb = try? FileHandle(forReadingFrom: b) else { return false }
    defer { try? fa.close(); try? fb.close() }
    while true {
        let da = (try? fa.read(upToCount: 8 * 1024 * 1024)) ?? nil
        let db = (try? fb.read(upToCount: 8 * 1024 * 1024)) ?? nil
        if da != db { return false }
        if da == nil || da!.isEmpty { return true }
    }
}

func isFinal(_ p: TransferItem.Phase) -> Bool {
    if p == .done { return true }
    if case .failed = p { return true }
    if case .stopped = p { return true }
    return false
}

ReceiverModel.documentsOverride = recvDir
let receiver = ReceiverModel()

// Spin the main runloop (not Thread.sleep — @Published updates need it) until
// the listener reports ready.
let listenDeadline = Date().addingTimeInterval(10)
while !receiver.listening && Date() < listenDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
print("listener ready: \(receiver.listening)")
// BSD connects land within microseconds — give the fresh listener a moment.
RunLoop.main.run(until: Date().addingTimeInterval(0.5))

var results: [String] = []
var liveJobs: [SendJob] = []  // the app retains jobs via activeJob; the harness must too

func runTransfer(_ label: String, expectName: String, done: @escaping () -> Void) {
    let item = TransferItem(name: "src.bin", size: srcSize)
    let job = SendJob(url: src, size: srcSize, item: item, model: nil)
    liveJobs.append(job)
    let started = Date()
    job.start(endpoint: BSDEndpoint(addr: "127.0.0.1", scopeIf: nil, port: VD.dataPort))
    DispatchQueue.global().async {
        let deadline = Date().addingTimeInterval(60)
        var phase = TransferItem.Phase.connecting
        while Date() < deadline {
            DispatchQueue.main.sync { phase = item.phase }
            if isFinal(phase) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let secs = Date().timeIntervalSince(started)
        let dest = recvDir.appendingPathComponent(expectName)
        if phase == .done, filesEqual(src, dest) {
            let gbps = Double(srcSize) * 8 / 1e9 / secs
            results.append("PASS \(label): \(expectName) intact, \(String(format: "%.1f", secs))s (\(String(format: "%.1f", gbps)) Gbps loopback)")
        } else {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: recvDir.path)) ?? []
            results.append("FAIL \(label): phase=\(phase), dest exists=\(FileManager.default.fileExists(atPath: dest.path)), recvDir=\(contents)")
        }
        done()
    }
}

// Bandwidth-race probe: ping with a 4 MiB blast; the receiver must sink it
// and pong.
func blastCheck(done: @escaping () -> Void) {
    let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: VD.port)!, using: .tcp)
    let junk = Data(count: 4 * 1024 * 1024)
    let hdr = StreamHeader(transferId: UUID().uuidString, name: "", size: 0, offset: 0,
                           length: 0, streamIndex: 0, streamCount: 0, ping: true,
                           blast: Int64(junk.count))
    let q = DispatchQueue(label: "blast")
    var finished = false
    conn.stateUpdateHandler = { st in
        if case .ready = st {
            conn.send(content: hdr.encodedFrame() + junk, completion: .contentProcessed { _ in })
            conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { d, _, _, _ in
                finished = true
                results.append(d == VD.pongData ? "PASS blast: 4 MiB sunk, pong received" : "FAIL blast: bad reply")
                conn.cancel()
                done()
            }
        }
    }
    conn.start(queue: q)
    q.asyncAfter(deadline: .now() + 10) {
        if !finished {
            results.append("FAIL blast: timeout")
            conn.cancel()
            done()
        }
    }
}

runTransfer("transfer-1", expectName: "src.bin") {
    // second send of the same file must land under a collision-safe name
    runTransfer("transfer-2", expectName: "src 2.bin") {
        blastCheck {
            let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: recvDir.path)) ?? []
            if leftovers.contains(where: { $0.hasPrefix(".vdpart") }) {
                results.append("FAIL cleanup: leftover .vdpart temp files: \(leftovers)")
            } else {
                results.append("PASS cleanup: no temp files left")
            }
            results.forEach { print($0) }
            exit(results.allSatisfy { $0.hasPrefix("PASS") } ? 0 : 1)
        }
    }
}

RunLoop.main.run()
