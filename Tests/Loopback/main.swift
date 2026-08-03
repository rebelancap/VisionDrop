import Foundation
import Network

// Loopback harness: drives the production SenderModel (race, batches, jobs)
// against the production ReceiverModel over 127.0.0.1 and verifies the
// received bytes — single files, collision naming, an empty file, and a
// folder tree sent twice.

let tmp = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "/tmp/vd-loopback")
try? FileManager.default.removeItem(at: tmp)
let recvDir = tmp.appendingPathComponent("recv")
try! FileManager.default.createDirectory(at: recvDir, withIntermediateDirectories: true)

vdDebug = { print("  [vd] \($0)") }

// 200 MB random source file (big enough for 4 streams and real chunking)
let src = tmp.appendingPathComponent("src.bin")
let urandom = FileHandle(forReadingAtPath: "/dev/urandom")!
FileManager.default.createFile(atPath: src.path, contents: nil)
let out = try! FileHandle(forWritingTo: src)
for _ in 0..<50 { try! out.write(contentsOf: urandom.read(upToCount: 4 * 1024 * 1024)!) }
try! out.close()
let srcSize = try! FileManager.default.attributesOfItem(atPath: src.path)[.size] as! Int64
print("source ready: \(srcSize) bytes")

// Zero-byte file
let emptyFile = tmp.appendingPathComponent("empty.bin")
FileManager.default.createFile(atPath: emptyFile.path, contents: nil)

// Folder tree: nested dirs, a multi-stream file, a tiny file, a zero-byte
// file, and a .DS_Store that must NOT be transferred.
let folder = tmp.appendingPathComponent("Game Pack")
let deep = folder.appendingPathComponent("sub/deep")
try! FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
func writeRandom(_ url: URL, mib: Int) {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let fh = try! FileHandle(forWritingTo: url)
    for _ in 0..<mib { try! fh.write(contentsOf: urandom.read(upToCount: 1024 * 1024)!) }
    try! fh.close()
}
writeRandom(folder.appendingPathComponent("a.bin"), mib: 10)
writeRandom(folder.appendingPathComponent("sub/b.bin"), mib: 40) // >32 MiB → 4 streams
try! Data("hello".utf8).write(to: deep.appendingPathComponent("c.txt"))
FileManager.default.createFile(atPath: folder.appendingPathComponent("empty.dat").path, contents: nil)
try! Data("junk".utf8).write(to: folder.appendingPathComponent(".DS_Store"))

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

/// nil if the received tree matches the sent folder (minus .DS_Store), else
/// a description of the first mismatch.
func treeMismatch(sent: URL, received: URL) -> String? {
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: sent.path) else { return "cannot enumerate source" }
    var expected: Set<String> = []
    while let rel = en.nextObject() as? String {
        guard en.fileAttributes?[.type] as? FileAttributeType == .typeRegular,
              (rel as NSString).lastPathComponent != ".DS_Store" else { continue }
        expected.insert(rel)
        if !filesEqual(sent.appendingPathComponent(rel), received.appendingPathComponent(rel)) {
            return "content mismatch at \(rel)"
        }
    }
    guard let ren = fm.enumerator(atPath: received.path) else { return "cannot enumerate received" }
    var got: Set<String> = []
    while let rel = ren.nextObject() as? String {
        guard ren.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
        got.insert(rel)
    }
    if got != expected { return "file set differs: extra \(got.subtracting(expected)), missing \(expected.subtracting(got))" }
    return nil
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

let sender = SenderModel()
sender.injectPeer(name: "Loopback",
                  endpoint: .service(name: "Loopback", type: VD.service, domain: "local.", interface: nil),
                  v4: ["127.0.0.1"], ll6: [])

var results: [String] = []
var checks: [(label: String, item: TransferItem, verify: () -> String?)] = []

func queue(_ label: String, urls: [URL], verify: @escaping () -> String?) {
    sender.send(urls)
    let item = sender.transfers.first!
    checks.append((label, item, verify))
}

func checkFile(_ dest: URL) -> String? {
    guard FileManager.default.fileExists(atPath: dest.path) else {
        return "missing: \(dest.lastPathComponent)"
    }
    return filesEqual(src, dest) ? nil : "bytes differ"
}

queue("transfer-1", urls: [src]) { checkFile(recvDir.appendingPathComponent("src.bin")) }
// Same file again must land under a collision-safe name.
queue("transfer-2", urls: [src]) { checkFile(recvDir.appendingPathComponent("src 2.bin")) }
queue("empty-file", urls: [emptyFile]) {
    let dest = recvDir.appendingPathComponent("empty.bin")
    guard FileManager.default.fileExists(atPath: dest.path) else { return "missing" }
    let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? -1
    return size == 0 ? nil : "expected 0 bytes, got \(String(describing: size))"
}
queue("folder-1", urls: [folder]) {
    treeMismatch(sent: folder, received: recvDir.appendingPathComponent("Game Pack"))
}
// Same folder again must land under a collision-renamed root.
queue("folder-2", urls: [folder]) {
    treeMismatch(sent: folder, received: recvDir.appendingPathComponent("Game Pack 2"))
}
if checks[3].item.fileCount != 4 {
    results.append("FAIL folder-item: fileCount \(String(describing: checks[3].item.fileCount)), expected 4 (.DS_Store must be skipped)")
}

// Bandwidth-race probe against the legacy NW port: ping with a 4 MiB blast;
// the receiver must sink it and pong.
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
                let valid = [VD.pongData, VD.pongUSB, VD.pongWiFi]
                results.append(d.map { valid.contains($0) } == true
                    ? "PASS blast: 4 MiB sunk, pong received"
                    : "FAIL blast: bad reply")
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

DispatchQueue.global().async {
    let deadline = Date().addingTimeInterval(300)
    while Date() < deadline {
        var allFinal = false
        DispatchQueue.main.sync { allFinal = checks.allSatisfy { isFinal($0.item.phase) } }
        if allFinal { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    DispatchQueue.main.sync {
        for c in checks {
            if c.item.phase == .done {
                if let err = c.verify() {
                    results.append("FAIL \(c.label): \(err)")
                } else {
                    let secs = (c.item.finishedAt ?? Date()).timeIntervalSince(c.item.startedAt)
                    results.append("PASS \(c.label): intact, \(String(format: "%.1f", secs))s")
                }
            } else {
                results.append("FAIL \(c.label): phase=\(c.item.phase)")
            }
        }
    }
    blastCheck {
        var leftovers: [String] = []
        if let en = FileManager.default.enumerator(atPath: recvDir.path) {
            while let rel = en.nextObject() as? String {
                if (rel as NSString).lastPathComponent.hasPrefix(".vdpart") { leftovers.append(rel) }
            }
        }
        if leftovers.isEmpty {
            results.append("PASS cleanup: no temp files left")
        } else {
            results.append("FAIL cleanup: leftover .vdpart temp files: \(leftovers)")
        }
        results.forEach { print($0) }
        exit(results.allSatisfy { $0.hasPrefix("PASS") } ? 0 : 1)
    }
}

RunLoop.main.run()
