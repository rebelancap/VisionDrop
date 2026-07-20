import Foundation
import Network

/// Listens on the VisionDrop port, advertises via Bonjour (with our IPv4s and
/// IPv6 link-locals in the TXT record so the peer can race the USB path), and
/// writes incoming streams into preallocated files. The listener is fully
/// recreated on network-path changes and failures so a plugged-in cable or a
/// suspended/resumed app never leaves it stuck.
final class ReceiverModel: ObservableObject {
    @Published var transfers: [TransferItem] = []
    @Published var listening = false
    @Published var lastError: String?

    /// Overridable so tests / the Mac app can receive into a chosen dir.
    static var documentsOverride: URL?
    /// Called on the main thread when a transfer completes successfully.
    var onCompleted: ((TransferItem) -> Void)?

    private let serviceName: String
    private let destination: URL?
    private var listener: NWListener?
    private var pathMonitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "visiondrop.listener")
    private var uiTimer: Timer?
    private var restartPending = false
    private var advertisedSignature = ""

    private let lock = NSLock()
    private var incoming: [String: IncomingFile] = [:]

    private var destDir: URL {
        destination ?? Self.documentsOverride
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init(serviceName: String = "VisionDrop", destination: URL? = nil) {
        self.serviceName = serviceName
        self.destination = destination
        queue.async { self.restartListener() }
        startBSDListener()
        watchPath()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.transfers.forEach { $0.tick() }
        }
    }

    // MARK: - BSD data plane (fast path)

    /// Dual-stack raw listener on the data port. Every connection gets its own
    /// blocking thread: read() into an aligned buffer, pwrite() at the stream
    /// offset — the same hot path curl rides, which the framework's receive
    /// callbacks can't match.
    private func startBSDListener(retriesLeft: Int = 5) {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var zero: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout<Int32>.size))
        var sin6 = sockaddr_in6()
        sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6.sin6_family = sa_family_t(AF_INET6)
        sin6.sin6_port = VD.dataPort.bigEndian
        sin6.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: sin6) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            if retriesLeft > 0 {
                queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.startBSDListener(retriesLeft: retriesLeft - 1)
                }
            }
            return
        }
        let t = Thread { [weak self] in
            while true {
                var addr = sockaddr_storage()
                var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let cfd = withUnsafeMutablePointer(to: &addr) { p -> Int32 in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &len) }
                }
                if cfd < 0 {
                    if errno == EINTR { continue }
                    break
                }
                var opt: Int32 = 1
                setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &opt, socklen_t(MemoryLayout<Int32>.size))
                var bufSize: Int32 = 4 * 1024 * 1024
                setsockopt(cfd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
                guard let self else { close(cfd); break }
                let ct = Thread { [weak self] in self?.handleBSDConn(cfd) }
                ct.name = "visiondrop.bsd.conn"
                ct.start()
            }
        }
        t.name = "visiondrop.bsd.accept"
        t.start()
    }

    private func handleBSDConn(_ fd: Int32) {
        guard let head = BSDSocket.recvExact(fd, count: 10, timeoutMs: 10000),
              Array(head.prefix(6)) == VD.magic else {
            close(fd)
            return
        }
        var len: UInt32 = UInt32(head[6]) << 24
        len |= UInt32(head[7]) << 16
        len |= UInt32(head[8]) << 8
        len |= UInt32(head[9])
        guard len > 0, len < 65536,
              let hdrData = BSDSocket.recvExact(fd, count: Int(len), timeoutMs: 5000),
              let header = StreamHeader.decode(hdrData) else {
            close(fd)
            return
        }
        if header.ping == true {
            let bufSize = 4 * 1024 * 1024
            let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1 << 12)
            defer { buf.deallocate() }
            var remaining = header.blast ?? 0
            while remaining > 0 {
                let n = read(fd, buf, min(bufSize, Int(remaining)))
                if n <= 0 { close(fd); return }
                remaining -= Int64(n)
            }
            _ = BSDSocket.sendAll(fd, VD.pongData)
            close(fd)
            return
        }
        receiveBSDStream(fd, header)
    }

    private func receiveBSDStream(_ fd: Int32, _ h: StreamHeader) {
        lock.lock()
        var inc = incoming[h.transferId]
        if inc == nil {
            do {
                let file = try IncomingFile(header: h, dir: destDir)
                incoming[h.transferId] = file
                inc = file
                DispatchQueue.main.async { self.transfers.insert(file.item, at: 0) }
            } catch {
                lock.unlock()
                close(fd)
                return
            }
        }
        guard let inc, !inc.cancelled else {
            lock.unlock()
            close(fd)
            return
        }
        inc.fds.append(fd)
        lock.unlock()

        let file = open(inc.tempURL.path, O_WRONLY)
        guard file >= 0 else {
            close(fd)
            streamFailed(inc, "Could not open file for writing", interrupted: false)
            return
        }
        // Direct writes: skip the page cache so sustained transfers stream at
        // NAND speed instead of burst-into-RAM / stall-on-writeback sawtooth.
        _ = fcntl(file, F_NOCACHE, 1)

        // Double-buffered pipeline: this thread reads the socket while a
        // writer thread pwrites to disk — network and NAND run concurrently
        // instead of alternating (a structural ~2x ceiling on a serial loop).
        // Raw memory only — Swift Arrays trap under exclusivity enforcement
        // when producer and writer threads touch elements concurrently.
        let bufSize = 4 * 1024 * 1024
        let ringCount = 3
        let bufs = (0..<ringCount).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1 << 12)
        }
        let lens = UnsafeMutablePointer<Int>.allocate(capacity: ringCount)
        let offs = UnsafeMutablePointer<Int64>.allocate(capacity: ringCount)
        let wFailed = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        lens.initialize(repeating: 0, count: ringCount)
        offs.initialize(repeating: 0, count: ringCount)
        wFailed.initialize(to: false)
        // Created at 0 and credited up: libdispatch traps on dispose if a
        // semaphore's value ever ends below its *initial* value, and the
        // shutdown sentinel legitimately consumes one `empty` credit.
        let empty = DispatchSemaphore(value: 0)
        for _ in 0..<ringCount { empty.signal() }
        let full = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)

        let writer = Thread {
            var idx = 0
            while true {
                full.wait()
                let n = lens[idx]
                if n <= 0 { break } // sentinel: end of stream or read error
                if !wFailed.pointee {
                    if pwrite(file, bufs[idx], n, offs[idx]) == n {
                        inc.item.add(n)
                    } else {
                        wFailed.pointee = true
                    }
                }
                empty.signal()
                idx = (idx + 1) % ringCount
            }
            writerDone.signal()
        }
        writer.name = "visiondrop.bsd.writer"
        writer.start()

        var got: Int64 = 0
        var readFailed = false
        var idx = 0
        while got < h.length {
            empty.wait()
            if wFailed.pointee { break }
            let want = Int(min(Int64(bufSize), h.length - got))
            let n = read(fd, bufs[idx], want)
            if n <= 0 {
                readFailed = true
                break
            }
            lens[idx] = n
            offs[idx] = h.offset + got
            full.signal()
            got += Int64(n)
            idx = (idx + 1) % ringCount
        }
        // Sentinel stops the writer (reuse current slot; we hold its `empty`
        // credit whenever the loop exited after a successful wait).
        let completed = got >= h.length
        if completed { empty.wait() }
        lens[idx] = 0
        full.signal()
        writerDone.wait()
        let writeFailed = wFailed.pointee
        bufs.forEach { $0.deallocate() }
        lens.deallocate()
        offs.deallocate()
        wFailed.deallocate()
        close(file)

        if writeFailed {
            close(fd)
            streamFailed(inc, "Write failed — is storage full?", interrupted: false)
            return
        }
        if readFailed || got < h.length {
            close(fd)
            streamFailed(inc, "Connection lost — transfer stopped", interrupted: true)
            return
        }
        // Finalize before the ack leaves: sender "done" implies file in place.
        streamDone(inc)
        _ = BSDSocket.sendAll(fd, VD.ackData)
        close(fd)
    }

    /// Restart the listener if it isn't healthy — called on app foreground.
    func ensureListening() {
        queue.async {
            if self.listener?.state != .ready { self.restartListener() }
        }
    }

    /// Unconditional restart — the manual "reset connection" action.
    func resetNetwork() {
        queue.async { self.restartListener() }
    }

    // Runs on `queue`.
    private func restartListener() {
        listener?.cancel()
        listener = nil
        do {
            guard let port = NWEndpoint.Port(rawValue: VD.port) else { return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: port)
            var txt: [String: String] = [VD.txtAddrs: NetUtils.ipv4Addresses().joined(separator: ",")]
            let ll6 = NetUtils.ipv6LinkLocalAddresses()
            if !ll6.isEmpty { txt[VD.txtLL6] = ll6.joined(separator: ",") }
            let g6 = NetUtils.ipv6RoutableAddresses()
            if !g6.isEmpty { txt[VD.txtG6] = g6.joined(separator: ",") }
            txt[VD.txtDPort] = String(VD.dataPort)
            advertisedSignature = Self.addressSignature()
            l.service = NWListener.Service(name: serviceName, type: VD.service, domain: nil,
                                           txtRecord: NWTXTRecord(txt).data)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.stateUpdateHandler = { [weak self, weak l] st in
                guard let self, let l, self.listener === l else { return }
                switch st {
                case .ready:
                    DispatchQueue.main.async { self.listening = true; self.lastError = nil }
                case .failed(let e):
                    DispatchQueue.main.async { self.listening = false; self.lastError = e.localizedDescription }
                    self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.listener === l else { return }
                        self.restartListener()
                    }
                default:
                    break
                }
            }
            listener = l
            l.start(queue: queue)
        } catch {
            DispatchQueue.main.async { self.listening = false; self.lastError = error.localizedDescription }
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.restartListener() }
        }
    }

    private static func addressSignature() -> String {
        (NetUtils.interfaceNames().sorted() + NetUtils.ipv4Addresses().sorted()
            + NetUtils.ipv6LinkLocalAddresses().sorted()
            + NetUtils.ipv6RoutableAddresses().sorted()).joined(separator: ",")
    }

    private func watchPath() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            // Restart (debounced) only when our advertised addresses actually
            // changed — e.g. the USB4 cable was plugged in. Path chatter alone
            // (WiFi scans, the monitor's initial callback) must NOT bounce the
            // listener, or it can be down right when a connection arrives.
            guard let self, !self.restartPending else { return }
            guard Self.addressSignature() != self.advertisedSignature else { return }
            self.restartPending = true
            self.queue.asyncAfter(deadline: .now() + 1.5) {
                self.restartPending = false
                if Self.addressSignature() != self.advertisedSignature {
                    self.restartListener()
                }
            }
        }
        m.start(queue: queue)
        pathMonitor = m
    }

    // MARK: - Cancel / dismiss

    func cancel(_ item: TransferItem) {
        lock.lock()
        let inc = incoming.values.first { $0.item === item }
        inc?.cancelled = true
        let conns = inc?.conns ?? []
        let fds = inc?.fds ?? []
        lock.unlock()
        conns.forEach { $0.cancel() }
        fds.forEach { shutdown($0, SHUT_RDWR) }
        if let inc { streamFailed(inc, "Cancelled", interrupted: true) }
    }

    func dismiss(_ item: TransferItem) {
        guard !item.isActive else { return }
        transfers.removeAll { $0 === item }
    }

    // MARK: - Connections

    private func accept(_ conn: NWConnection) {
        let q = DispatchQueue(label: "visiondrop.conn")
        conn.stateUpdateHandler = { st in
            if case .failed = st { conn.cancel() }
        }
        conn.start(queue: q)
        conn.receive(minimumIncompleteLength: 10, maximumLength: 10) { [weak self] data, _, _, err in
            guard let self, err == nil, let data, data.count == 10,
                  Array(data.prefix(6)) == VD.magic else {
                conn.cancel()
                return
            }
            let len = (UInt32(data[6]) << 24) | (UInt32(data[7]) << 16) | (UInt32(data[8]) << 8) | UInt32(data[9])
            guard len > 0, len < 65536 else { conn.cancel(); return }
            conn.receive(minimumIncompleteLength: Int(len), maximumLength: Int(len)) { hdrData, _, _, err2 in
                guard err2 == nil, let hdrData, let header = StreamHeader.decode(hdrData) else {
                    conn.cancel()
                    return
                }
                if header.ping == true {
                    self.discard(conn, remaining: header.blast ?? 0)
                    return
                }
                self.beginStream(conn, header)
            }
        }
    }

    /// Sink `remaining` blast bytes, then pong. Serves the sender's bandwidth race.
    private func discard(_ conn: NWConnection, remaining: Int64) {
        guard remaining > 0 else {
            conn.send(content: VD.pongData, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        conn.receive(minimumIncompleteLength: 1,
                     maximumLength: Int(min(Int64(VD.chunkSize), remaining))) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            var left = remaining
            if let data { left -= Int64(data.count) }
            if err != nil || (left > 0 && isComplete) {
                conn.cancel()
                return
            }
            self.discard(conn, remaining: left)
        }
    }

    private func beginStream(_ conn: NWConnection, _ h: StreamHeader) {
        lock.lock()
        var inc = incoming[h.transferId]
        if inc == nil {
            do {
                let file = try IncomingFile(header: h, dir: destDir)
                incoming[h.transferId] = file
                inc = file
                DispatchQueue.main.async { self.transfers.insert(file.item, at: 0) }
            } catch {
                lock.unlock()
                conn.cancel()
                return
            }
        }
        guard let inc else { lock.unlock(); return }
        if inc.cancelled {
            lock.unlock()
            conn.cancel()
            return
        }
        inc.conns.append(conn)
        lock.unlock()

        if let path = conn.currentPath {
            let t: TransferItem.Transport? = path.usesInterfaceType(.wiredEthernet) ? .usb
                : (path.usesInterfaceType(.wifi) ? .wifi : nil)
            if let t { DispatchQueue.main.async { inc.item.transport = t } }
        }

        do {
            let fh = try FileHandle(forWritingTo: inc.tempURL)
            try fh.seek(toOffset: UInt64(h.offset))
            receiveLoop(conn, fh, remaining: h.length, inc: inc)
        } catch {
            conn.cancel()
            streamFailed(inc, "Could not open file for writing", interrupted: false)
        }
    }

    private func receiveLoop(_ conn: NWConnection, _ fh: FileHandle, remaining: Int64, inc: IncomingFile) {
        guard remaining > 0 else {
            try? fh.close()
            // Finalize before the last ack leaves: the sender's "done" must
            // imply the file is fully renamed into place.
            streamDone(inc)
            conn.send(content: VD.ackData, completion: .contentProcessed { _ in conn.cancel() })
            return
        }
        conn.receive(minimumIncompleteLength: 1,
                     maximumLength: Int(min(Int64(VD.chunkSize), remaining))) { [weak self] data, _, isComplete, err in
            guard let self else { return }
            var left = remaining
            if let data, !data.isEmpty {
                do {
                    try autoreleasepool { try fh.write(contentsOf: data) }
                    inc.item.add(data.count)
                    left -= Int64(data.count)
                } catch {
                    try? fh.close()
                    conn.cancel()
                    self.streamFailed(inc, "Write failed — is storage full?", interrupted: false)
                    return
                }
            }
            if let err {
                try? fh.close()
                conn.cancel()
                self.streamFailed(inc, isInterruptError(err) ? "Connection lost — transfer stopped" : err.localizedDescription,
                                  interrupted: isInterruptError(err))
                return
            }
            if left > 0 && isComplete {
                try? fh.close()
                conn.cancel()
                self.streamFailed(inc, "Connection lost — transfer stopped", interrupted: true)
                return
            }
            self.receiveLoop(conn, fh, remaining: left, inc: inc)
        }
    }

    private func streamDone(_ inc: IncomingFile) {
        lock.lock()
        inc.streamsDone += 1
        let complete = inc.streamsDone == inc.streamCount && !inc.failed
        if complete { incoming[inc.id] = nil }
        lock.unlock()
        guard complete else { return }
        do {
            try inc.finalize()
            DispatchQueue.main.async {
                inc.item.finish(.done)
                self.onCompleted?(inc.item)
            }
        } catch {
            DispatchQueue.main.async { inc.item.finish(.failed("Could not move the finished file into place")) }
        }
    }

    private func streamFailed(_ inc: IncomingFile, _ msg: String, interrupted: Bool) {
        lock.lock()
        let already = inc.failed
        inc.failed = true
        incoming[inc.id] = nil
        let conns = inc.conns
        inc.conns = []
        let fds = inc.fds
        inc.fds = []
        lock.unlock()
        guard !already else { return }
        conns.forEach { $0.cancel() }
        fds.forEach { shutdown($0, SHUT_RDWR) }
        inc.discard()
        DispatchQueue.main.async {
            inc.item.finish(interrupted ? .stopped(msg) : .failed(msg))
        }
    }
}

/// A file being assembled from one or more streams. Mutable state is guarded
/// by the owning model's lock.
final class IncomingFile {
    let id: String
    let item: TransferItem
    let tempURL: URL
    let streamCount: Int
    var streamsDone = 0
    var failed = false
    var cancelled = false
    var conns: [NWConnection] = []
    var fds: [Int32] = []

    private let dir: URL
    private let name: String

    init(header: StreamHeader, dir: URL) throws {
        id = header.transferId
        name = header.name
        self.dir = dir
        streamCount = header.streamCount
        item = TransferItem(id: header.transferId, name: header.name, size: header.size, direction: .receive)
        tempURL = dir.appendingPathComponent(".vdpart-\(header.transferId)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: tempURL)
        // Sparse truncate only — measured faster on visionOS than F_PREALLOCATE,
        // which regressed sustained writes ~25% (v3.2 field data).
        try fh.truncate(atOffset: UInt64(header.size))
        try fh.close()
    }

    func finalize() throws {
        try FileManager.default.moveItem(at: tempURL, to: Self.uniqueURL(for: name, in: dir))
    }

    func discard() {
        try? FileManager.default.removeItem(at: tempURL)
    }

    static func uniqueURL(for name: String, in dir: URL) -> URL {
        var url = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            url = dir.appendingPathComponent(candidate)
            i += 1
        }
        return url
    }
}
