import SwiftUI
import os.log

/// Builds and wires the sender, receiver, and history for the Mac app.
/// The Mac both sends (drag & drop) and receives (into ~/Downloads).
final class AppStack: ObservableObject {
    let sender = SenderModel()
    let receiver: ReceiverModel
    let history = HistoryStore()

    init() {
        let logger = Logger(subsystem: "com.rebelancap.visiondrop", category: "race")
        vdDebug = { logger.info("\($0, privacy: .public)") }
        let name = Host.current().localizedName ?? "Mac"
        receiver = ReceiverModel(
            serviceName: name,
            destination: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        )
        sender.ownServiceName = name
        sender.onCompleted = { [weak self] item in
            self?.history.record(item)
            self?.sender.dismiss(item)
        }
        receiver.onCompleted = { [weak self] item in
            self?.history.record(item)
            self?.receiver.dismiss(item)
        }
    }
}

@main
struct VisionDropApp: App {
    @StateObject private var stack = AppStack()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(stack.sender)
                .environmentObject(stack.receiver)
                .environmentObject(stack.history)
                .frame(minWidth: 480, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}
