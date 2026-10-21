import SwiftUI

/// Settings › Modeller › Jarvis sohbeti: cloud or local, and which cloud model. Picking a model
/// sends it one tiny message, so a model that can't chat or starts too late is flagged at once.
struct CloudChatSettingsView: View {
    let ollamaModel: String
    let openKeys: () -> Void

    @AppStorage(ChatBackend.defaultsKey) private var backend: ChatBackend = .cloud
    @AppStorage(CloudLLM.modelKey) private var model = ""
    @State private var models = CloudLLM.cachedModels
    @State private var loading = false
    @State private var listError: String?
    @State private var check: Check = .idle

    private enum Check: Equatable {
        case idle, running
        case done(CloudModelCheck.Outcome)
    }

    private var ready: Bool { CloudLLM.address != nil && APIKeys.cloudLLM.hasKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Sohbet", systemImage: "bubble.left.and.text.bubble.right")
                Spacer()
                Picker("", selection: $backend) {
                    ForEach(ChatBackend.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            if backend == .cloud {
                if !ready {
                    warning("Bulut LLM adresi ve anahtarı yok; yerel model cevaplıyor.") {
                        Button("Ekle", action: openKeys).controlSize(.small)
                    }
                } else {
                    HStack {
                        Text("Bulut modeli")
                        Spacer()
                        if loading { ProgressView().controlSize(.small) }
                        Picker("", selection: $model) {
                            if model.isEmpty { Text("Model seçin").tag("") }
                            ForEach(pickerModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        Button {
                            Task { await refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Model listesini servisten yenile")
                        .disabled(loading)
                    }
                    if let listError { warning(listError) { EmptyView() } }
                    checkLine
                }
                Text("Bulut 1,5 sn'de cevaba başlamazsa yerel model (\(ollamaModel)) cevaplar.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            if backend == .cloud, ready, models.isEmpty { await refresh() }
        }
        .onChange(of: model) { _, new in
            guard !new.isEmpty else { return }
            Task { await runCheck(new) }
        }
    }

    /// The saved model stays selectable even when the last list no longer has it.
    private var pickerModels: [String] {
        model.isEmpty || models.contains(model) ? models : [model] + models
    }

    @ViewBuilder
    private var checkLine: some View {
        switch check {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Model deneniyor…").font(.caption2).foregroundStyle(.secondary)
            }
        case .done(.ok(let ms, _)):
            Label("Çalışıyor, ilk kelime \(ms) ms", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .done(.slow(let ms, _)):
            warning("Yavaş: ilk kelime \(ms) ms. Çoğu cevabı yerel model verecek.") { EmptyView() }
        case .done(.empty):
            warning("Model boş cevap verdi; sohbet için uygun olmayabilir.") { EmptyView() }
        case .done(.rejected(let reason)):
            warning("Bu model sohbet isteğini kabul etmedi (\(reason)).") { EmptyView() }
        }
    }

    private func warning<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            trailing()
        }
    }

    private func refresh() async {
        loading = true
        listError = await APIKeys.cloudLLM.test()
        models = CloudLLM.cachedModels
        loading = false
    }

    private func runCheck(_ id: String) async {
        guard let (client, _) = CloudLLM.client() else { return }
        check = .running
        var probe = client
        probe.thinkingOff = true
        let outcome = await CloudModelCheck.run(probe, model: id)
        guard model == id else { return }
        switch outcome {
        case .ok(_, let thinkingOff), .slow(_, let thinkingOff):
            UserDefaults.standard.set(thinkingOff, forKey: CloudLLM.thinkingOffKey)
        case .empty, .rejected:
            break
        }
        check = .done(outcome)
    }
}
