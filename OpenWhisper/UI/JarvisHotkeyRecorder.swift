import AppKit
import SwiftUI

/// Settings › Jarvis row for choosing a shortcut: the key that starts a "Hey Jarvis" session,
/// or the one that opens the typed request panel.
struct JarvisHotkeyRecorder: View {
    enum Slot { case jarvisKey, typedRequest }

    @Environment(AppState.self) var appState
    var slot: Slot = .jarvisKey

    @State private var monitor: Any?
    @State private var message: String?
    /// Lone modifier key pressed during capture; it becomes the hotkey if released untouched.
    @State private var pendingModifier: UInt16?

    private var capturing: Bool { monitor != nil }

    private var hotkey: JarvisHotkey? {
        get { slot == .jarvisKey ? appState.jarvisHotkey : appState.typedRequestHotkey }
        nonmutating set {
            if slot == .jarvisKey { appState.jarvisHotkey = newValue } else { appState.typedRequestHotkey = newValue }
        }
    }

    /// The other slot's shortcut; one key can't do both.
    private var otherHotkey: (key: JarvisHotkey?, name: String) {
        slot == .jarvisKey ? (appState.typedRequestHotkey, "Jarvis'e yazma kısayolu")
            : (appState.jarvisHotkey, "Jarvis tuşu")
    }

    private var title: String { slot == .jarvisKey ? "Jarvis tuşu" : "Jarvis'e yaz" }

    private var help: String {
        switch slot {
        case .jarvisKey:
            "Basınca Jarvis dinlemeye başlar, susunca durur; tekrar basarsanız hemen biter. Tek bir tuş (F tuşu, sağ Option) ya da ⌥J gibi bir kombinasyon olabilir."
        case .typedRequest:
            "Basınca bir yazı alanı açılır; yazdığınız istek Enter ile Jarvis'e gider, Esc kapatır."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: slot == .jarvisKey ? "keyboard" : "text.bubble")
                Spacer()
                if capturing {
                    Text("Bir tuşa basın… (Esc: iptal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("İptal") { stopCapture() }
                        .controlSize(.small)
                } else {
                    Text(hotkey?.label ?? "Atanmadı")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                    Button(hotkey == nil ? "Tuş ata" : "Değiştir") { startCapture() }
                        .controlSize(.small)
                    if hotkey != nil {
                        Button("Kaldır") {
                            hotkey = nil
                            message = nil
                        }
                        .controlSize(.small)
                    }
                }
            }
            if capturing && message == nil {
                Text("Tuş tepki vermiyorsa macOS onu kullanıyordur (ör. F5); fn ile birlikte basın.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(help)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { stopCapture() }
        .onChange(of: appState.jarvisCaptureSystemKey) { _, press in
            guard capturing, let press else { return }
            message = JarvisHotkey.systemKeyMessage(nxKeyType: press.nxKeyType)
        }
    }

    private func startCapture() {
        guard monitor == nil else { return }
        message = nil
        pendingModifier = nil
        appState.jarvisHotkeyCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pendingModifier = nil
        appState.jarvisHotkeyCapturing = false
    }

    private func handle(_ event: NSEvent) {
        let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        switch event.type {
        case .keyDown:
            owLog("[JarvisKeyRecorder] keyDown \(event.keyCode) flags \(flags.rawValue)")
            pendingModifier = nil
            if event.keyCode == 53, flags.intersection(JarvisHotkey.relevantModifiers).isEmpty {
                stopCapture()
                return
            }
            finish(JarvisHotkey.capture(keyCode: event.keyCode, flags: flags,
                                        characters: event.charactersIgnoringModifiers))
        case .flagsChanged:
            // Fn alone is the dictation key; held, it only modifies the next key (fn+F5).
            if event.keyCode == JarvisHotkey.fnKeyCode { return }
            guard let flag = JarvisHotkey.flag(forModifierKey: event.keyCode) else { return }
            if flags.contains(flag) {
                // First modifier down alone: candidate. A second one makes it a chord.
                let others = flags.intersection(JarvisHotkey.relevantModifiers).subtracting(flag)
                pendingModifier = others.isEmpty ? event.keyCode : nil
            } else if pendingModifier == event.keyCode {
                finish(JarvisHotkey.captureModifier(keyCode: event.keyCode))
            }
        default:
            break
        }
    }

    private func finish(_ result: JarvisHotkey.CaptureResult) {
        switch result {
        case .accepted(let key):
            if let other = otherHotkey.key, other.sameKey(as: key) {
                message = "\(key.label) zaten \(otherHotkey.name) — başka bir tuş seçin."
                return
            }
            stopCapture()
            hotkey = key
            message = nil
        case .rejected(let why):
            message = why
        }
    }
}
