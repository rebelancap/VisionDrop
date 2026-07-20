import Foundation
import Network

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
    private var pending: [SendJob] = []
    private var activeJob: SendJob?

    init() {
        startBrowsing()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.transfers.forEach { $0.tick() }
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
    }

    /// Test/CLI hook: set the peer directly, bypassing Bonjour discovery
    /// (unsigned CLIs can't browse mDNS under Local Network privacy).
    func injectPeer(name: String, endpoint: NWEndpoint, v4: [String], ll6: [String]) {
        deviceName = name
        serviceEndpoint = endpoint
        candidateV4 = v4
        candidateLL6 = ll6
    }

    // MARK: - Sending

    func send(_ urls: [URL], securityScoped: Bool = false) {
        for url in urls {
            // Security scope must be active BEFORE any file access — even
            // stat — or sandboxed pickers (visionOS fileImporter) deny it.
            let scopeActive = securityScoped && url.startAccessingSecurityScopedResource()
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                if scopeActive { url.stopAccessingSecurityScopedResource() }
                continue
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            let item = TransferItem(name: url.lastPathComponent, size: size ?? 0, direction: .send)
            transfers.insert(item, at: 0)
            guard serviceEndpoint != nil else {
                if scopeActive { url.stopAccessingSecurityScopedResource() }
                item.finish(.failed("No device found — is VisionDrop open on the other side?"))
                continue
            }
            guard let size, size > 0 else {
                if scopeActive { url.stopAccessingSecurityScopedResource() }
                item.finish(.failed("Could not read file size"))
                continue
            }
            pending.append(SendJob(url: url, size: size, item: item, model: self, scopeActive: scopeActive))
        }
        startNextIfIdle()
    }

    func cancel(_ item: TransferItem) {
        if let job = activeJob, job.item === item {
            job.cancel()
            return
        }
        if let idx = pending.firstIndex(where: { $0.item === item }) {
            let job = pending.remove(at: idx)
            job.releaseResources()
            item.finish(.stopped("Cancelled"))
        }
    }

    func dismiss(_ item: TransferItem) {
        guard !item.isActive else { return }
        transfers.removeAll { $0 === item }
    }

    private func startNextIfIdle() {
        guard activeJob == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        activeJob = job
        pickEndpoint { endpoint, transport in
            guard let endpoint else {
                job.releaseResources()
                job.item.finish(.stopped("No usable path to the device — check the cable and try again"))
                self.activeJob = nil
                self.startNextIfIdle()
                return
            }
            job.item.transport = transport
            self.lastTransport = transport
            job.start(endpoint: endpoint)
        }
    }

    func jobFinished(_ job: SendJob) {
        DispatchQueue.main.async {
            if self.activeJob === job { self.activeJob = nil }
            self.startNextIfIdle()
        }
    }

    // MARK: - Path selection

    /// Two phases, all raw sockets. Phase 1: connect-race every candidate —
    /// flat v4/g6 addresses in parallel, link-locals sequentially across scope
    /// interfaces (simultaneous same-address scopes poison resolution). Phase
    /// 2: blast 16 MiB down every ready path; first pong wins on measured
    /// bandwidth — the strap's fast USB4 NIC and slow USB-CDC NIC both
    /// handshake sub-ms, and only bandwidth tells them apart. A winner under
    /// 400 Mbps re-races once after 2.5 s (the fast NIC may be waking from
    /// headset standby).
    private func pickEndpoint(attempt: Int = 1, _ completion: @escaping (BSDEndpoint?, TransferItem.Transport) -> Void) {
        let dport = candidateDPort
        let flat = (candidateV4 + candidateG6).map { BSDEndpoint(addr: $0, scopeIf: nil, port: dport) }
        let ll6 = candidateLL6
        let scopeIfs = NetUtils.ll6CapableInterfaceNames()
        vdDebug?("race[\(attempt)]: dport \(dport), flat \(flat.map(\.description)), ll6 \(ll6) via \(scopeIfs)")
        let syncQ = DispatchQueue(label: "visiondrop.race")
        let workQ = DispatchQueue.global(qos: .userInitiated)
        var readyFds: [(ep: BSDEndpoint, fd: Int32)] = []
        var blastStarted = false
        var done = false
        var probesOutstanding = flat.count + ll6.count

        // All shared state below is touched only on syncQ.
        func finish(_ ep: BSDEndpoint?, mbps: Double?) {
            guard !done else { return }
            done = true
            let leftovers = readyFds
            readyFds = []
            leftovers.forEach { shutdown($0.fd, SHUT_RDWR) }
            workQ.asyncAfter(deadline: .now() + 15) { leftovers.forEach { close($0.fd) } }
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
            vdDebug?("race: winner \(ep?.description ?? "none")\(mbps.map { " at \(Int($0)) Mbps" } ?? "")")
            let transport: TransferItem.Transport = mbps.map { $0 > 400 ? .usb : .wifi } ?? .unknown
            DispatchQueue.main.async { completion(ep, transport) }
        }

        func startBlast() {
            guard !blastStarted, !done else { return }
            blastStarted = true
            guard !readyFds.isEmpty else {
                vdDebug?("race: nothing ready")
                return finish(nil, mbps: nil)
            }
            vdDebug?("race: blasting \(readyFds.count) candidate(s)")
            let junkSize = 16 * 1024 * 1024
            let junk = Data(count: junkSize)
            let t0 = DispatchTime.now()
            for cand in readyFds {
                workQ.async {
                    let hdr = StreamHeader(transferId: UUID().uuidString, name: "", size: 0, offset: 0,
                                           length: 0, streamIndex: 0, streamCount: 0,
                                           ping: true, blast: Int64(junkSize))
                    guard BSDSocket.sendAll(cand.fd, hdr.encodedFrame() + junk),
                          let pong = BSDSocket.recvExact(cand.fd, count: 2, timeoutMs: 8000),
                          pong == VD.pongData else { return }
                    let secs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9
                    let mbps = Double(junkSize) * 8 / secs / 1e6
                    syncQ.async {
                        vdDebug?("race: pong from \(cand.ep) — \(Int(mbps)) Mbps")
                        finish(cand.ep, mbps: mbps)
                    }
                }
            }
            syncQ.asyncAfter(deadline: .now() + 10) {
                finish(readyFds.first?.ep, mbps: nil)
            }
        }

        func noteReady(_ ep: BSDEndpoint, _ fd: Int32) {
            if done || blastStarted {
                close(fd)
                return
            }
            vdDebug?("race: ready #\(readyFds.count + 1) \(ep)")
            readyFds.append((ep, fd))
            if readyFds.count == 1 {
                syncQ.asyncAfter(deadline: .now() + 0.75) { startBlast() }
            }
        }

        func probeConcluded() {
            probesOutstanding -= 1
            if probesOutstanding == 0 { startBlast() }
        }

        for ep in flat {
            workQ.async {
                let fd = BSDSocket.connect(ep, timeoutMs: 1500)
                syncQ.async {
                    if let fd {
                        noteReady(ep, fd)
                    } else {
                        vdDebug?("race: \(ep) unreachable")
                    }
                    probeConcluded()
                }
            }
        }
        for addr in ll6 {
            workQ.async {
                for ifn in scopeIfs {
                    var stop = false
                    syncQ.sync { stop = done || blastStarted }
                    if stop { break }
                    let ep = BSDEndpoint(addr: addr, scopeIf: ifn, port: dport)
                    if let fd = BSDSocket.connect(ep, timeoutMs: 350) {
                        syncQ.async { noteReady(ep, fd) }
                        break
                    }
                    syncQ.async { vdDebug?("race: \(ep) unreachable") }
                }
                syncQ.async { probeConcluded() }
            }
        }
        syncQ.asyncAfter(deadline: .now() + 2.5) { startBlast() }
    }
}

/// One outbound transfer over N parallel raw-socket streams, each a blocking
/// pread/write loop on a background thread — curl's hot path, times four.
final class SendJob {
    let item: TransferItem

    private let url: URL
    private let size: Int64
    private weak var model: SenderModel?
    private let transferId = UUID().uuidString
    private var scopeActive: Bool
    private let lock = NSLock()
    private var socks: [Int32] = []
    private var files: [Int32] = []
    private var acked = 0
    private var streamTotal = 1
    private var finished = false

    /// `scopeActive`: the caller already holds security-scoped access for
    /// `url`; this job takes ownership and releases it when it finishes.
    init(url: URL, size: Int64, item: TransferItem, model: SenderModel?, scopeActive: Bool = false) {
        self.url = url
        self.size = size
        self.item = item
        self.model = model
        self.scopeActive = scopeActive
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

    func releaseResources() {
        if scopeActive {
            url.stopAccessingSecurityScopedResource()
            scopeActive = false
        }
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

        let header = StreamHeader(transferId: transferId, name: url.lastPathComponent, size: size,
                                  offset: offset, length: length, streamIndex: index,
                                  streamCount: count, ping: nil)
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
        lock.unlock()
        if all {
            stop {
                self.item.finish(.done)
                self.model?.onCompleted?(self.item)
            }
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
        releaseResources()
        DispatchQueue.main.async {
            outcome()
            self.model?.jobFinished(self)
        }
    }
}
