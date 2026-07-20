import SwiftUI

struct TransferRow: View {
    @ObservedObject var item: TransferItem
    var onCancel: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .font(.title3)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    transportBadge
                    Spacer()
                    Text(trailingText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    trailingButton
                }
                if item.isActive {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    HStack {
                        Text("\(Fmt.bytes(item.bytes)) of \(Fmt.bytes(item.size))")
                        Spacer()
                        Text("\(Fmt.speed(item.speed)) \(Fmt.eta(remaining: item.size - item.bytes, speed: item.speed))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    if item.transport == .wifi {
                        Label("Over WiFi — connect the USB4 cable for ~10× speed", systemImage: "wifi.exclamationmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                if case .failed(let msg) = item.phase {
                    Text(msg).font(.caption).foregroundStyle(.red)
                }
                if case .stopped(let msg) = item.phase {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var fraction: Double {
        item.size > 0 ? min(1, Double(item.bytes) / Double(item.size)) : 0
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.phase {
        case .connecting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .transferring:
            Image(systemName: item.direction == .receive ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .foregroundStyle(.blue)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped:
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var transportBadge: some View {
        switch item.transport {
        case .usb:
            Image(systemName: "cable.connector")
                .font(.caption)
                .foregroundStyle(.green)
                .help("Over USB")
        case .wifi:
            Image(systemName: "wifi")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Over WiFi")
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder private var trailingButton: some View {
        if item.isActive, let onCancel {
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel transfer")
        } else if !item.isActive, item.phase != .done, let onDismiss {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    private var trailingText: String {
        switch item.phase {
        case .done:
            let dur = Fmt.duration((item.finishedAt ?? Date()).timeIntervalSince(item.startedAt))
            return "\(Fmt.bytes(item.size)) · \(dur) · \(Fmt.speed(item.averageSpeed))"
        case .connecting:
            return "connecting…"
        default:
            return ""
        }
    }
}
