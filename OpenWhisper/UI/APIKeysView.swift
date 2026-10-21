import SwiftUI

/// Settings › API Anahtarları: one row per cloud service in `APIKeys.all`. A saved key is never
/// shown again, only whether there is one.
struct APIKeysView: View {
    /// Called after a key was saved or deleted, so the caller can refresh what depends on it.
    var onChange: (APIKeyProvider) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Anahtarlar bu Mac'in Anahtar Zinciri'nde saklanır.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(APIKeys.all) { provider in
                APIKeyRow(provider: provider, onChange: onChange)
                if provider.id != APIKeys.all.last?.id { Divider() }
            }
        }
    }
}

private struct APIKeyRow: View {
    let provider: APIKeyProvider
    let onChange: (APIKeyProvider) -> Void

    @AppStorage(CloudLLM.addressKey) private var savedAddress = ""
    @State private var address = ""
    @State private var input = ""
    @State private var stored = false
    @State private var message: Message?
    @State private var testing = false

    private enum Message: Equatable {
        case success(String), warning(String), error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(provider.title, systemImage: "key")
                    .font(.headline)
                Text(provider.purpose)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(stored ? "Kayıtlı" : "Yok", systemImage: stored ? "checkmark.seal.fill" : "minus.circle")
                    .font(.caption)
                    .foregroundStyle(stored ? .green : .secondary)
            }
            if provider.needsAddress {
                TextField("Adres, ör. https://api.ornek.com/v1", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(save)
            }
            HStack {
                SecureField(stored ? "Yeni anahtarla değiştir" : provider.placeholder, text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Kaydet", action: save)
                    .disabled(!canSave)
                Button("Test et", action: runTest)
                    .disabled(!stored || testing)
                Button("Sil", role: .destructive, action: delete)
                    .disabled(!stored)
            }
            .controlSize(.small)
            if testing {
                ProgressView().controlSize(.small)
            } else if let message {
                switch message {
                case .success(let text):
                    Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption2)
                case .warning(let text):
                    Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption2)
                case .error(let text):
                    Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption2)
                }
            }
        }
        .onAppear {
            address = savedAddress
            stored = provider.hasKey
        }
    }

    private var canSave: Bool {
        let keyTyped = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let addressChanged = provider.needsAddress && address != savedAddress
        return keyTyped || addressChanged
    }

    /// Checks the format first; a valid one is saved and then tested against the service.
    private func save() {
        guard canSave else { return }
        var warning: String?
        if provider.needsAddress {
            switch CloudLLM.normalize(address) {
            case .failure(let error): message = .error(error.message); return
            case .success(let url):
                address = url.absoluteString
                if address != savedAddress {
                    savedAddress = address
                    CloudLLM.cachedModels = []
                }
            }
        }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            switch provider.check(key: key) {
            case .invalid(let text): message = .error(text); return
            case .warning(let text): warning = text
            case .ok: break
            }
            guard provider.save(key) else { message = .error("Anahtar Zinciri'ne kaydedilemedi."); return }
            // The field never shows a saved key again.
            input = ""
        }
        stored = provider.hasKey
        onChange(provider)
        runTest(warning: warning)
    }

    private func delete() {
        message = provider.delete() ? nil : .error("Anahtar Zinciri'nden silinemedi.")
        stored = provider.hasKey
        onChange(provider)
    }

    private func runTest() { runTest(warning: nil) }

    private func runTest(warning: String?) {
        guard stored else { return }
        testing = true
        Task {
            let failure = await provider.test()
            testing = false
            if let failure {
                message = .error(failure)
            } else if let warning {
                message = .warning("Çalışıyor, ama: \(warning)")
            } else {
                message = .success(provider.needsAddress ? "Çalışıyor, \(CloudLLM.cachedModels.count) sohbet modeli bulundu." : "Çalışıyor.")
            }
        }
    }
}
