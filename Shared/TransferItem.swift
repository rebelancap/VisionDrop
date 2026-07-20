import Foundation

/// One file transfer, observable by the UI. Byte counts are accumulated from
/// multiple stream queues via `add(_:)`; the owning model calls `tick()` on the
/// main thread a few times a second to publish progress and a smoothed speed.
final class TransferItem: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting
        case transferring
        case done
        case stopped(String) // cancelled or connection lost — neutral, dismissible
        case failed(String)  // a real local error — shown red, dismissible
    }

    enum Transport { case usb, wifi, unknown }
    enum Direction { case send, receive }

    let id: String
    let name: String
    let size: Int64
    let direction: Direction
    let startedAt = Date()
    private(set) var finishedAt: Date?

    @Published var bytes: Int64 = 0
    @Published var phase: Phase = .connecting
    @Published var speed: Double = 0 // bytes/sec
    @Published var transport: Transport = .unknown

    private let lock = NSLock()
    private var accumulated: Int64 = 0
    private var lastBytes: Int64 = 0
    private var lastTick = Date()
    private var firstByteAt: Date?

    init(id: String = UUID().uuidString, name: String, size: Int64, direction: Direction = .send) {
        self.id = id
        self.name = name
        self.size = size
        self.direction = direction
    }

    var isActive: Bool { phase == .connecting || phase == .transferring }

    func add(_ n: Int) {
        lock.lock()
        if firstByteAt == nil { firstByteAt = Date() }
        accumulated += Int64(n)
        lock.unlock()
    }

    var countedBytes: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return accumulated
    }

    func tick() {
        guard isActive else { return }
        let b = countedBytes
        if phase == .connecting && b > 0 { phase = .transferring }
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        if dt > 0.05 {
            let inst = Double(b - lastBytes) / dt
            speed = speed == 0 ? inst : (0.6 * inst + 0.4 * speed)
            lastBytes = b
            lastTick = now
        }
        bytes = b
    }

    func finish(_ phase: Phase) {
        finishedAt = Date()
        bytes = countedBytes
        self.phase = phase
        speed = 0
    }

    /// Per-byte wire speed: the clock starts at the first payload byte, so the
    /// fixed path-race/blast setup doesn't dilute the figure.
    var averageSpeed: Double {
        lock.lock()
        let start = firstByteAt ?? startedAt
        lock.unlock()
        let t = (finishedAt ?? Date()).timeIntervalSince(start)
        return t > 0 ? Double(bytes) / t : 0
    }
}
