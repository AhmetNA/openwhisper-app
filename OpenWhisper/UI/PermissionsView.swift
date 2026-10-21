import SwiftUI

/// Settings › İzinler: every permission Jarvis uses, live, with ask / open-settings buttons.
struct PermissionsView: View {
    @State private var manager = PermissionsManager()
    @State private var busy: PermissionsManager.Kind?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\"İzin iste\" macOS'un izin penceresini açar; daha önce reddettiyseniz Sistem Ayarları'nı açar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(PermissionsManager.Kind.allCases) { kind in
                    row(kind)
                    if kind != PermissionsManager.Kind.allCases.last { Divider() }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Button {
                    Task { await manager.refresh() }
                } label: {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
                Spacer()
            }
        }
        .task { await manager.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await manager.refresh() }
        }
    }

    private func row(_ kind: PermissionsManager.Kind) -> some View {
        let status = manager.statuses[kind]
        return HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(kind.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusBadge(status)
            if status == .granted {
                Button("Ayarlar") { manager.openSettings(kind) }
                    .help("Sistem Ayarları'nda bu izni aç")
            } else {
                Button(busy == kind ? "…" : "İzin iste") {
                    busy = kind
                    Task {
                        await manager.request(kind)
                        busy = nil
                    }
                }
                .disabled(busy != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func statusBadge(_ status: PermissionsManager.Status?) -> some View {
        let (text, color): (String, Color) = switch status {
        case .granted: ("Verildi", .green)
        case .denied: ("Reddedildi", .red)
        case .notDetermined: ("Sorulmadı", .orange)
        case .unknown(let why): (why, .secondary)
        case nil: ("…", .secondary)
        }
        return Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
