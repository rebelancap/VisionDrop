import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var sender: SenderModel
    @EnvironmentObject var receiver: ReceiverModel
    @EnvironmentObject var history: HistoryStore
    @State private var dropTargeted = false

    private var activeItems: [TransferItem] {
        (sender.transfers + receiver.transfers).sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        VStack(spacing: 14) {
            header
            dropZone
            if !activeItems.isEmpty {
                activeList
            }
            HistorySection(store: history)
        }
        .padding(20)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("VisionDrop").font(.title2.bold())
                Text("USB4 file transfer").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                sender.resetNetwork()
                receiver.resetNetwork()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(sender.deviceName != nil ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    Text(sender.deviceName ?? "Searching…")
                        .font(.callout)
                        .foregroundStyle(sender.deviceName != nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    if sender.lastTransport == .usb {
                        Image(systemName: "cable.connector").font(.caption).foregroundStyle(.green)
                    } else if sender.lastTransport == .wifi {
                        Image(systemName: "wifi").font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .help("Click to reset the connection")
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 34))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
            Text(dropTargeted ? "Release to send" : "Drop files to send")
                .font(.headline)
            Text("or click to choose…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 130)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(dropTargeted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: choose)
        .dropDestination(for: URL.self) { urls, _ in
            sender.send(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
    }

    @ViewBuilder private var activeList: some View {
        let rows = VStack(spacing: 0) {
            ForEach(activeItems) { item in
                TransferRow(item: item,
                            onCancel: { cancel(item) },
                            onDismiss: { dismissItem(item) })
                Divider()
            }
        }
        if activeItems.count > 3 {
            ScrollView { rows }.frame(maxHeight: 230)
        } else {
            rows
        }
    }

    private func cancel(_ item: TransferItem) {
        if sender.transfers.contains(where: { $0 === item }) {
            sender.cancel(item)
        } else {
            receiver.cancel(item)
        }
    }

    private func dismissItem(_ item: TransferItem) {
        if sender.transfers.contains(where: { $0 === item }) {
            sender.dismiss(item)
        } else {
            receiver.dismiss(item)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            sender.send(panel.urls)
        }
    }
}
