import SwiftUI
import UniformTypeIdentifiers

struct ReceiverView: View {
    @EnvironmentObject var receiver: ReceiverModel
    @EnvironmentObject var sender: SenderModel
    @EnvironmentObject var history: HistoryStore
    @State private var showImporter = false

    private var activeItems: [TransferItem] {
        (sender.transfers + receiver.transfers).sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            actionRow
            if !activeItems.isEmpty {
                activeList
            }
            HistorySection(store: history)
            footer
        }
        .padding(24)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                sender.send(urls, securityScoped: true)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("VisionDrop")
                .font(.largeTitle.bold())
            Button {
                receiver.resetNetwork()
                sender.resetNetwork()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(receiver.listening ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(receiver.listening ? "Ready to receive" : "Starting…")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help("Tap to reset the connection")
            if let err = receiver.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 14) {
            Button {
                showImporter = true
            } label: {
                Label("Send Files to Mac…", systemImage: "square.and.arrow.up")
            }
            .disabled(sender.deviceName == nil)
            Text(sender.deviceName.map { "Mac: \($0)" } ?? "Searching for Mac…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
            ScrollView { rows }.frame(maxHeight: 260)
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

    private var footer: some View {
        Text("Received files appear in Files → On My Vision Pro → VisionDrop")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}
