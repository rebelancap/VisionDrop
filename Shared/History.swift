import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: String
    let name: String
    let size: Int64
    let date: Date
    let seconds: Double
    let bytesPerSec: Double
    let direction: String // "send" | "receive"
    let transport: String // "usb" | "wifi" | "unknown"
}

/// Successful transfers, persisted to Application Support as JSON.
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VisionDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL),
           let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = list
        }
    }

    func record(_ item: TransferItem) {
        let entry = HistoryEntry(
            id: item.id,
            name: item.name,
            size: item.size,
            date: Date(),
            seconds: (item.finishedAt ?? Date()).timeIntervalSince(item.startedAt),
            bytesPerSec: item.averageSpeed,
            direction: item.direction == .send ? "send" : "receive",
            transport: transportString(item.transport)
        )
        entries.insert(entry, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        save()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func transportString(_ t: TransferItem.Transport) -> String {
        switch t {
        case .usb: return "usb"
        case .wifi: return "wifi"
        case .unknown: return "unknown"
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) {
            try? d.write(to: fileURL, options: .atomic)
        }
    }
}
