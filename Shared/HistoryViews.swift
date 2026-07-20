import SwiftUI

struct HistorySection: View {
    @ObservedObject var store: HistoryStore

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                if !store.entries.isEmpty {
                    Button("Clear All") { store.clear() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }
            if store.entries.isEmpty {
                Text("Completed transfers will appear here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                List {
                    ForEach(store.entries) { entry in
                        HistoryRow(entry: entry)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    store.remove(entry)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button("Delete", role: .destructive) { store.remove(entry) }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: entry.direction == "send" ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if entry.transport == "usb" {
                Image(systemName: "cable.connector").font(.caption).foregroundStyle(.secondary)
            } else if entry.transport == "wifi" {
                Image(systemName: "wifi").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var caption: String {
        "\(Fmt.bytes(entry.size)) · \(Fmt.duration(entry.seconds)) · \(Fmt.speed(entry.bytesPerSec)) · \(entry.date.formatted(date: .abbreviated, time: .shortened))"
    }
}
