import SwiftUI

/// Settings › İzinler: every permission Jarvis uses, live, with ask / open-settings buttons.
struct PermissionsView: View {
    @State private var manager = PermissionsManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("İzinleri aşağıdan kontrol edebilirsiniz. Daha önce reddedilen izinleri Sistem Ayarları’ndan açın; değişiklikler otomatik güncellenir.")
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
        .task {
            while !Task.isCancelled {
                if manager.requesting == nil { await manager.refresh() }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
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
                if let message = manager.messages[kind] {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            statusBadge(status)
            VStack(alignment: .trailing, spacing: 6) {
                Button(manager.actionTitle(for: kind)) {
                    Task { await manager.request(kind) }
                }
                .disabled(manager.requesting != nil || status == nil || status == .restricted || status == .unavailable)
                if status == .notDetermined || status == .writeOnly || isUnknown(status) {
                    Button("Sistem Ayarları") { manager.openSettings(kind) }
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func isUnknown(_ status: PermissionsManager.Status?) -> Bool {
        if case .unknown = status { return true }
        return false
    }

    private func statusBadge(_ status: PermissionsManager.Status?) -> some View {
        let (text, color): (String, Color) = switch status {
        case .granted: ("Verildi", .green)
        case .denied: ("Reddedildi", .red)
        case .notDetermined: ("Sorulmadı", .orange)
        case .needsSettings: ("İzin gerekli", .orange)
        case .unavailable: ("Yüklü değil", .secondary)
        case .restricted: ("Kısıtlı", .red)
        case .writeOnly: ("Yalnızca yazma", .orange)
        case .unknown(let why): (why, .secondary)
        case nil: ("…", .secondary)
        }
        return Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }
}
