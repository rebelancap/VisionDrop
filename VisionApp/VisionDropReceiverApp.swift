import SwiftUI
import UIKit
import os.log

/// Builds and wires the receiver, sender, and history for the Vision Pro app.
/// The headset both receives (into Documents, visible in Files) and sends
/// (via the file picker).
final class VisionStack: ObservableObject {
    let sender = SenderModel()
    let receiver: ReceiverModel
    let history = HistoryStore()

    init() {
        let logger = Logger(subsystem: "com.rebelancap.visiondrop", category: "race")
        vdDebug = { logger.info("\($0, privacy: .public)") }
        let name = UIDevice.current.name
        receiver = ReceiverModel(serviceName: name)
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
struct VisionDropReceiverApp: App {
    @StateObject private var stack = VisionStack()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ReceiverView()
                .environmentObject(stack.sender)
                .environmentObject(stack.receiver)
                .environmentObject(stack.history)
        }
        .defaultSize(width: 560, height: 680)
        .onChange(of: scenePhase) { _, phase in
            // Recover networking when the app comes back after being closed or
            // suspended — no force quit needed.
            if phase == .active {
                stack.receiver.ensureListening()
                stack.sender.resetIfStale()
            }
        }
    }
}
