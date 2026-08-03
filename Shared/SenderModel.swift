import Foundation
import Network

/// One file queued for sending. `wireName` may carry a relative path when the
/// file is part of a dropped folder ("Folder/sub/file.bin").
struct SendFile {
    let url: URL
    let wireName: String
    let size: Int64
}

/// One drop: a single file, or every file under a dropped folder — raced to an
/// endpoint once, then streamed file-by-file into one visible transfer.
final class SendBatch {
    let item: TransferItem
    var files: [SendFile]
    let batchId: String?      // nil for single files
    let batchTotal: Int64
    let batchFiles: Int
    var endpoint: BSDEndpoint?
    var cancelled = false

    private var scopeActive: Bool
    private let scopeURL: URL

    init(item: TransferItem, files: [SendFile], batchId: String?, scopeActive: Bool, scopeURL: URL) {
        self.item = item
        self.files = files
        self.batchId = batchId
        self.scopeActive = scopeActive
        self.scopeURL = scopeURL
        batchTotal = files.reduce(0) { $0 + $1.size }
        batchFiles = files.count
    }

    func release() {
        if scopeActive {
            scopeURL.stopAccessingSecurityScopedResource()
            scopeActive = false
        }
    }
}

/// Discovers the peer via Bonjour, then transfers over raw BSD sockets.
/// Network.framework is used only for discovery — its path evaluation refuses
/// bridge interfaces in app contexts and its throughput tops out early, so all
/// probing and data flow through kernel sockets (see BSDSocket).
final class SenderModel: ObservableObject {
    @Published var deviceName: String?
    @Published var transfers: [TransferItem] = []
    @Published var lastTransport: TransferItem.Transport = .unknown

    /// Our own advertised service name, so we don't "discover" ourselves.
    var ownServiceName = ""
    /// Called on the main thread when a transfer completes successfully.
    var onCompleted: ((TransferItem) -> Void)?

    private var browser: NWBrowser?
    private var serviceEndpoint: NWEndpoint?
    private var candidateV4: [String] = []
    private var candidateLL6: [String] = []
    private var candidateG6: [String] = []
    private var candidateDPort: UInt16 = VD.port
    private let netQueue = DispatchQueue(label: "visiondrop.sender")
    private var uiTimer: Timer?
    private var warmTimer: Timer?
    private var lastWarm = Date.distantPast
    private var pending: [SendBatch] = []
    private var activeBatch: SendBatch?
    private var activeJob: SendJob?
    private var peerInjected = false

    init() {
        startBrowsing()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.transfers.forEach { $0.tick() }
        }
        warmTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.warmPaths()
        }
    }

    // MARK: - Discovery

    /// Tear down and restart discovery — the "it's stuck searching" remedy.
    func resetNetwork() {
        browser?.cancel()
        browser = nil
        DispatchQueue.main.async {
            self.deviceName = nil
            self.serviceEndpoint = nil
            self.candidateV4 = []
            self.candidateLL6 = []
            self.candidateG6 = []
        }
        startBrowsing()
    }

    func resetIfStale() {
        if deviceName == nil { resetNetwork() }
    }

    private func startBrowsing() {
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: VD.service, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async { self?.apply(results) }
        }
        b.stateUpdateHandler = { [weak self, weak b] state in
            if case .failed = state {
                DispatchQueue.main.async {
                    guard let self, self.browser === b else { return }
                    self.resetNetwork()
                }
            }
        }
        browser = b
        b.start(queue: netQueue)
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        guard !peerInjected else { return }
        let other = results.first { r in
            if case .service(let name, _, _, _) = r.endpoint { return name != ownServiceName }
            return true
        }
        guard let r = other else {
            deviceName = nil
            serviceEndpoint = nil
            candidateV4 = []
            candidateLL6 = []
            candidateG6 = []
            return
        }
        serviceEndpoint = r.endpoint
        if case .service(let name, _, _, _) = r.endpoint {
            deviceName = name
        } else {
            deviceName = "Device"
        }
        let before = candidateV4 + candidateLL6 + candidateG6
        if case .bonjour(let txt) = r.metadata {
            candidateV4 = (txt.dictionary[VD.txtAddrs] ?? "").split(separator: ",").map(String.init)
            candidateLL6 = (txt.dictionary[VD.txtLL6] ?? "").split(separator: ",").map(String.init)
            candidateG6 = (txt.dictionary[VD.txtG6] ?? "").split(separator: ",").map(String.init)
            candidateDPort = UInt16(txt.dictionary[VD.txtDPort] ?? "") ?? VD.port
        } else {
            candidateV4 = []
            candidateLL6 = []
            candidateG6 = []
        }
        warmPaths(force: candidateV4 + candidateLL6 + candidateG6 != before)
    }

    /// Test/CLI hook: set the peer directly, bypassing Bonjour discovery —
    /// and pinning it: browse results must never override an injected peer,
    /// or a test could race (and transfer to!) a real device on the network.
    func injectPeer(name: String, endpoint: NWEndpoint, v4: [String], ll6: [String],
                    dport: UInt16 = VD.dataPort) {
        peerInjected = true
        deviceName = name
        serviceEndpoint = endpoint
        candidateV4 = v4
        candidateLL6 = ll6
        candidateDPort = dport
    }

    /// Complete a real handshake + zero-length ping on each candidate so the
    /// paths are warm before a drop: an idle strap NIC eats the first SYNs of
    /// a cold flow while it wakes — a ~2 s handshake that loses every race.
    private func warmPaths(force: Bool = false) {
        guard deviceName != nil, activeBatch == nil else { return }
        guard force || Date().timeIntervalSince(lastWarm) > 10 else { return }
        lastWarm = Date()
        let dport = candidateDPort
        var eps = (candidateV4 + candidateG6).map { BSDEndpoint(addr: $0, scopeIf: nil, port: dport) }
        if let scope = NetUtils.ll6CapableInterfaceNames().first {
            eps += candidateLL6.map { BSDEndpoint(addr: $0, scopeIf: scope, port: dport) }
        }
        for ep in eps {
            DispatchQueue.global(qos: .utility).async {
                guard let fd = BSDSocket.connect(ep, timeoutMs: 3500) else { return }
                let hdr = StreamHeader(transferId: UUID().uuidString, name: "", size: 0, offset: 0,
                                       length: 0, streamIndex: 0, streamCount: 0, ping: true, blast: 0)
                if BSDSocket.sendAll(fd, hdr.encodedFrame()) {
                    _ = BSDSocket.recvExact(fd, count: 2, timeoutMs: 2000)
                }
                close(fd)
            }
        }
    }

    // MARK: - Sending

    func send(_ urls: [URL], securityScoped: Bool = false) {
        for url in urls {
            // Security scope must be active BEFORE any file access — even
            // stat — or sandboxed pickers (visionOS fileImporter) deny it.
            let scopeActive = securityScoped && url.startAccessingSecurityScopedResource()
            let release = { if scopeActive { url.stopAccessingSecurityScopedResource() } }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                release()
                continue
            }
            if isDir.boolValue {
                let (files, total) = Self.enumerateFolder(url)
                let item = TransferItem(name: url.lastPathComponent, size: total,
                                        direction: .send, fileCount: files.count)
                transfers.insert(item, at: 0)
                guard !files.isEmpty else {
                    release()
                    item.finish(.failed("Folder contains no files"))
                    continue
                }
                guard serviceEndpoint != nil else {
                    release()
                    item.finish(.failed("No device found — is VisionDrop open on the other side?"))
                    continue
                }
                pending.append(SendBatch(item: item, files: files, batchId: UUID().uuidString,
                                         scopeActive: scopeActive, scopeURL: url))
            } else {
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value
                let item = TransferItem(name: url.lastPathComponent, size: size ?? 0, direction: .send)
                transfers.insert(item, at: 0)
                guard serviceEndpoint != nil else {
                    release()
                    item.finish(.failed("No device found — is VisionDrop open on the other side?"))
                    continue
                }
                guard let size else {
                    release()
                    item.finish(.failed("Could not read file size"))
                    continue
                }
                let file = SendFile(url: url, wireName: url.lastPathComponent, size: size)
                pending.append(SendBatch(item: item, files: [file], batchId: nil,
                                         scopeActive: scopeActive, scopeURL: url))
            }
        }
        startNextIfIdle()
    }

    /// Regular files under `root`, wire-named relative to the folder's parent
    /// ("Folder/sub/file.bin"). Skips .DS_Store and symlinks.
    private static func enumerateFolder(_ root: URL) -> ([SendFile], Int64) {
        guard let en = FileManager.default.enumerator(atPath: root.path) else { return ([], 0) }
        var files: [SendFile] = []
        var total: Int64 = 0
        let rootName = root.lastPathComponent
        while let rel = en.nextObject() as? String {
            guard let attrs = en.fileAttributes,
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (rel as NSString).lastPathComponent != ".DS_Store" else { continue }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            files.append(SendFile(url: root.appendingPathComponent(rel),
                                  wireName: rootName + "/" + rel, size: size))
            total += size
        }
        files.sort { $0.wireName.localizedStandardCompare($1.wireName) == .orderedAscending }
        return (files, total)
    }

    func cancel(_ item: TransferItem) {
        if let batch = activeBatch, batch.item === item {
            batch.cancelled = true
            batch.files = []
            if let job = activeJob {
                job.cancel()
            } else {
                batch.release()
                activeBatch = nil
                item.finish(.stopped("Cancelled"))
                startNextIfIdle()
            }
            return
        }
        if let idx = pending.firstIndex(where: { $0.item === item }) {
            let batch = pending.remove(at: idx)
            batch.release()
            item.finish(.stopped("Cancelled"))
        }
    }

    func dismiss(_ item: TransferItem) {
        guard !item.isActive else { return }
        transfers.removeAll { $0 === item }
    }

    private func startNextIfIdle() {
        guard activeJob == nil, activeBatch == nil, !pending.isEmpty else { return }
        let batch = pending.removeFirst()
        activeBatch = batch
        pickEndpoint { endpoint, transport, failureHint in
            guard self.activeBatch === batch, !batch.cancelled else { return }
            guard let endpoint else {
                batch.release()
                batch.item.finish(.stopped(failureHint
                    ?? "No usable path to the device — check the cable and try again"))
                self.activeBatch = nil
                self.startNextIfIdle()
                return
            }
            batch.item.transport = transport
            self.lastTransport = transport
            batch.endpoint = endpoint
            self.startNextFile()
        }
    }

    private func startNextFile() {
        guard let batch = activeBatch, let endpoint = batch.endpoint else { return }
        guard !batch.files.isEmpty else {
            batch.release()
            batch.item.finish(.done)
            onCompleted?(batch.item)
            activeBatch = nil
            startNextIfIdle()
            return
        }
        let f = batch.files.removeFirst()
        let job = SendJob(file: f, item: batch.item, model: self, batchId: batch.batchId,
                          batchTotal: batch.batchTotal, batchFiles: batch.batchFiles)
        activeJob = job
        job.start(endpoint: endpoint)
    }

    func jobFinished(_ job: SendJob) {
        DispatchQueue.main.async {
            guard self.activeJob === job else { return }
            self.activeJob = nil
            if job.succeeded, let batch = self.activeBatch, !batch.cancelled {
                self.startNextFile()
            } else {
                self.activeBatch?.release()
                self.activeBatch = nil
                self.startNextIfIdle()
            }
        }
    }

    // MARK: - Path selection

    /// Two phases, all raw sockets. Phase 1: connect-race every candidate —
    /// flat v4/g6 addresses in parallel, link-locals sequentially across scope
    /// interfaces (simultaneous same-address scopes poison resolution). Phase
    /// 2: blast 16 MiB down every ready path; the receiver's pong reports the
    /// interface class the blast landed on (PU wired / PW wifi / PO legacy).
    /// A wired-class pong over 400 Mbps wins instantly; anything else is held
    /// as best-so-far until the remaining probes conclude — a cold strap NIC
    /// drops the first SYNs while it wakes and takes ~2 s to complete a
    /// handshake, so fast WiFi must not outrun it. Candidates that connect
    /// after the first blast join the race late. A winner under 400 Mbps
    /// re-races once after 2.5 s. On total failure, `failureHint` carries a
    /// more specific message when the failure pattern implies one.
    private func pickEndpoint(attempt: Int = 1,
                              _ completion: @escaping (BSDEndpoint?, TransferItem.Transport, _ failureHint: String?) -> Void) {
        let dport = candidateDPort
        let flat = (candidateV4 + candidateG6).map { BSDEndpoint(addr: $0, scopeIf: nil, port: dport) }
        let ll6 = candidateLL6
        let scopeIfs = NetUtils.ll6CapableInterfaceNames()
        vdDebug?("race[\(attempt)]: dport \(dport), flat \(flat.map(\.description)), ll6 \(ll6) via \(scopeIfs)")
        let syncQ = DispatchQueue(label: "visiondrop.race")
        let workQ = DispatchQueue.global(qos: .userInitiated)
        let junkSize = 16 * 1024 * 1024
        let junk = Data(count: junkSize)
        var readyPreBlast: [(ep: BSDEndpoint, fd: Int32)] = []
        var blastFds: [Int32] = []
        var blastStarted = false
        var done = false
        var probesOutstanding = flat.count + ll6.count
        var blastsInFlight = 0
        var best: (ep: BSDEndpoint, mbps: Double, cls: IfClass)?
        var firstReadyEp: BSDEndpoint?
        var hostUnreachable = 0

        // All shared state above is touched only on syncQ.
        func finish(_ ep: BSDEndpoint?, mbps: Double?, cls: IfClass) {
            guard !done else { return }
            done = true
            let leftovers = readyPreBlast.map(\.fd) + blastFds
            readyPreBlast = []
            blastFds = []
            leftovers.forEach { shutdown($0, SHUT_RDWR) }
            workQ.asyncAfter(deadline: .now() + 15) { leftovers.forEach { close($0) } }
            if ep == nil, attempt == 1 {
                // Every candidate dead usually means our TXT snapshot is stale
                // (peer rebooted / addresses rotated). Refresh discovery and
                // re-race instead of failing the transfer.
                vdDebug?("race: nothing reachable — refreshing discovery, retrying in 2 s")
                DispatchQueue.main.async {
                    self.resetNetwork()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self.pickEndpoint(attempt: 2, completion)
                    }
                }
                return
            }
            if attempt == 1, ep != nil, let mbps, mbps < 400 {
                vdDebug?("race: winner only \(Int(mbps)) Mbps — re-racing in 2.5 s (fast path may be waking)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    self.pickEndpoint(attempt: 2, completion)
                }
                return
            }
            let transport: TransferItem.Transport
            switch cls {
            case .wired: transport = .usb
            case .wifi: transport = .wifi
            case .unknown: transport = mbps.map { $0 > 400 ? .usb : .wifi } ?? .unknown
            }
            vdDebug?("race: winner \(ep?.description ?? "none")\(mbps.map { " at \(Int($0)) Mbps" } ?? "") [\(transport)]")
            // Every candidate refused with "host unreachable" while the peer
            // is visible in Bonjour: macOS has stalled this app's Local
            // Network permission (seen after replacing the app binary) — a
            // relaunch fixes it, so say so instead of blaming the cable.
            let hint: String? = ep == nil && hostUnreachable > 0
                ? "No usable path — quit and relaunch VisionDrop (macOS can stall its Local Network permission after an app update)"
                : nil
            DispatchQueue.main.async { completion(ep, transport, hint) }
        }

        func settleOnBest() {
            if let b = best { finish(b.ep, mbps: b.mbps, cls: b.cls) }
            else { finish(firstReadyEp, mbps: nil, cls: .unknown) }
        }

        func maybeSettle() {
            guard !done, blastStarted, probesOutstanding == 0, blastsInFlight == 0 else { return }
            settleOnBest()
        }

        func scheduleSettle() {
            // Don't let a straggler blast stall the pick (16 MiB down a
            // 35 Mbps lane takes ~4 s): settle on the best seen shortly after
            // the first pong — but never while probes might still surface the
            // waking strap NIC.
            syncQ.asyncAfter(deadline: .now() + 1.5) {
                guard !done else { return }
                if probesOutstanding == 0 { settleOnBest() } else { scheduleSettle() }
            }
        }

        func pongReceived(_ ep: BSDEndpoint, mbps: Double, cls: IfClass) {
            vdDebug?("race: pong from \(ep) — \(Int(mbps)) Mbps [\(cls)]")
            let firstPong = best == nil
            if best == nil || mbps > best!.mbps { best = (ep, mbps, cls) }
            if cls != .wifi, mbps >= 400 {
                // Wired-fast (or legacy-fast): nothing will beat the strap.
                finish(ep, mbps: mbps, cls: cls)
                return
            }
            if firstPong { scheduleSettle() }
        }

        func blast(_ cand: (ep: BSDEndpoint, fd: Int32)) {
            blastsInFlight += 1
            blastFds.append(cand.fd)
            let t0 = DispatchTime.now()
            workQ.async {
                let hdr = StreamHeader(transferId: UUID().uuidString, name: "", size: 0, offset: 0,
                                       length: 0, streamIndex: 0, streamCount: 0,
                                       ping: true, blast: Int64(junkSize))
                var outcome: (Double, IfClass)?
                if BSDSocket.sendAll(cand.fd, hdr.encodedFrame() + junk),
                   let pong = BSDSocket.recvExact(cand.fd, count: 2, timeoutMs: 8000) {
                    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
                    let mbps = Double(junkSize) * 8 / secs / 1e6
                    if pong == VD.pongUSB { outcome = (mbps, .wired) }
                    else if pong == VD.pongWiFi { outcome = (mbps, .wifi) }
                    else if pong == VD.pongData { outcome = (mbps, .unknown) }
                }
                syncQ.async {
                    blastsInFlight -= 1
                    if let (mbps, cls) = outcome {
                        pongReceived(cand.ep, mbps: mbps, cls: cls)
                    } else {
                        vdDebug?("race: blast on \(cand.ep) got no pong")
                        maybeSettle()
                    }
                }
            }
        }

        func startBlast() {
            guard !blastStarted, !done else { return }
            blastStarted = true
            let cands = readyPreBlast
            readyPreBlast = []
            vdDebug?("race: blasting \(cands.count) candidate(s)")
            cands.forEach { blast($0) }
            maybeSettle() // nothing ready and no probes left → concede now
            guard !done else { return }
            syncQ.asyncAfter(deadline: .now() + 10) {
                guard !done else { return }
                settleOnBest()
            }
        }

        func noteReady(_ ep: BSDEndpoint, _ fd: Int32) {
            if done {
                close(fd)
                return
            }
            if firstReadyEp == nil { firstReadyEp = ep }
            vdDebug?("race: ready \(ep)\(blastStarted ? " (late)" : "")")
            if blastStarted {
                blast((ep, fd)) // a cold strap NIC joining after its ~2 s wake
            } else {
                readyPreBlast.append((ep, fd))
                if readyPreBlast.count == 1 {
                    syncQ.asyncAfter(deadline: .now() + 0.75) { startBlast() }
                }
            }
        }

        func probeConcluded() {
            probesOutstanding -= 1
            if probesOutstanding == 0, !blastStarted {
                startBlast()
            } else {
                maybeSettle()
            }
        }

        for ep in flat {
            workQ.async {
                // 3.5 s: a cold strap NIC loses its first two SYNs and only
                // completes the handshake on the ~2 s retransmit.
                var err: Int32 = 0
                let fd = BSDSocket.connect(ep, timeoutMs: 3500, failErrno: &err)
                syncQ.async {
                    if let fd {
                        noteReady(ep, fd)
                    } else {
                        if err == EHOSTUNREACH { hostUnreachable += 1 }
                        vdDebug?("race: \(ep) unreachable (errno \(err))")
                    }
                    probeConcluded()
                }
            }
        }
        for addr in ll6 {
            workQ.async {
                for (i, ifn) in scopeIfs.enumerated() {
                    var stop = false
                    syncQ.sync { stop = done }
                    if stop { break }
                    let ep = BSDEndpoint(addr: addr, scopeIf: ifn, port: dport)
                    // The first scope (bridges sort first — the real USB path
                    // on a bridging Mac) gets the cold-handshake allowance;
                    // wrong scopes fail fast or aren't worth waiting on.
                    var err: Int32 = 0
                    if let fd = BSDSocket.connect(ep, timeoutMs: i == 0 ? 2500 : 350, failErrno: &err) {
                        syncQ.async { noteReady(ep, fd) }
                        break
                    }
                    syncQ.async {
                        if err == EHOSTUNREACH { hostUnreachable += 1 }
                        vdDebug?("race: \(ep) unreachable (errno \(err))")
                    }
                }
                syncQ.async { probeConcluded() }
            }
        }
    }
}

/// One file over N parallel raw-socket streams, each a blocking pread/write
/// loop on a background thread — curl's hot path, times four.
final class SendJob {
    let item: TransferItem

    private let url: URL
    private let size: Int64
    private let wireName: String
    private weak var model: SenderModel?
    private let transferId = UUID().uuidString
    private let batchId: String?
    private let batchTotal: Int64?
    private let batchFiles: Int?
    private let lock = NSLock()
    private var socks: [Int32] = []
    private var files: [Int32] = []
    private var acked = 0
    private var streamTotal = 1
    private var finished = false
    private var succeededFlag = false

    var succeeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return succeededFlag
    }

    init(file: SendFile, item: TransferItem, model: SenderModel?,
         batchId: String? = nil, batchTotal: Int64? = nil, batchFiles: Int? = nil) {
        url = file.url
        size = file.size
        wireName = file.wireName
        self.item = item
        self.model = model
        self.batchId = batchId
        self.batchTotal = batchId != nil ? batchTotal : nil
        self.batchFiles = batchId != nil ? batchFiles : nil
    }

    func start(endpoint: BSDEndpoint) {
        // Tunable without rebuilding: `defaults write com.rebelancap.visiondrop
        // VDStreams -int N`, read per transfer.
        let requested = UserDefaults.standard.integer(forKey: "VDStreams")
        let maxStreams = requested > 0 ? min(requested, 16) : VD.maxStreams
        let streamCount = size >= 32 * 1024 * 1024 ? maxStreams : 1
        streamTotal = streamCount
        // 4 MiB-aligned split boundaries so the receiver's direct (F_NOCACHE)
        // writes stay aligned; the last stream absorbs the remainder.
        let align: Int64 = 4 * 1024 * 1024
        let base = streamCount > 1 ? max(align, (size / Int64(streamCount) / align) * align)
                                   : size
        for i in 0..<streamCount {
            let offset = Int64(i) * base
            let length = (i == streamCount - 1) ? size - offset : base
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.runStream(index: i, count: streamCount, offset: offset, length: length, endpoint: endpoint)
            }
        }
    }

    func cancel() {
        stop { self.item.finish(.stopped("Cancelled")) }
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    private func runStream(index: Int, count: Int, offset: Int64, length: Int64, endpoint: BSDEndpoint) {
        guard let sock = BSDSocket.connect(endpoint, timeoutMs: 5000) else {
            return interrupted("Could not connect to the device")
        }
        lock.lock()
        socks.append(sock)
        lock.unlock()
        let file = open(url.path, O_RDONLY)
        guard file >= 0 else { return fail("Cannot open file") }
        lock.lock()
        files.append(file)
        lock.unlock()

        let header = StreamHeader(transferId: transferId, name: wireName, size: size,
                                  offset: offset, length: length, streamIndex: index,
                                  streamCount: count, ping: nil, blast: nil,
                                  batchId: batchId, batchTotal: batchTotal, batchFiles: batchFiles)
        guard BSDSocket.sendAll(sock, header.encodedFrame()) else {
            return interrupted("Connection lost — transfer stopped")
        }

        let bufSize = 4 * 1024 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1 << 12)
        defer { buf.deallocate() }
        var pos = offset
        let end = offset + length
        while pos < end {
            if isFinished { return }
            let want = Int(min(Int64(bufSize), end - pos))
            let n = pread(file, buf, want, pos)
            guard n > 0 else { return fail("Reading the file failed mid-transfer") }
            guard BSDSocket.sendAll(sock, buf, n) else {
                return interrupted("Connection lost — transfer stopped")
            }
            item.add(n)
            pos += Int64(n)
        }
        guard let ack = BSDSocket.recvExact(sock, count: 2, timeoutMs: 60000), ack == VD.ackData else {
            return interrupted("Receiver did not confirm the transfer")
        }
        lock.lock()
        acked += 1
        let all = acked == streamTotal
        if all { succeededFlag = true }
        lock.unlock()
        if all {
            // The batch (via the model) decides when the shared item is done —
            // this file might not be the last one in a folder.
            stop {}
        }
    }

    private func interrupted(_ msg: String) {
        stop {
            if case .stopped = self.item.phase {} else { self.item.finish(.stopped(msg)) }
        }
    }

    private func fail(_ msg: String) {
        stop {
            if case .stopped = self.item.phase {} else { self.item.finish(.failed(msg)) }
        }
    }

    /// Single terminal path: first caller wins. Sockets are shut down (which
    /// unblocks any writer threads) and closed after they've had time to exit.
    private func stop(_ outcome: @escaping () -> Void) {
        lock.lock()
        let already = finished
        finished = true
        let ss = socks
        let ff = files
        socks = []
        files = []
        lock.unlock()
        guard !already else { return }
        ss.forEach { shutdown($0, SHUT_RDWR) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            ss.forEach { close($0) }
            ff.forEach { close($0) }
        }
        DispatchQueue.main.async {
            outcome()
            self.model?.jobFinished(self)
        }
    }
}
