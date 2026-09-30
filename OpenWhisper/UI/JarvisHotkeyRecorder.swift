import AppKit
import SwiftUI

/// Settings › Jarvis row for choosing the key that starts a "Hey Jarvis" session.
struct JarvisHotkeyRecorder: View {
    @Environment(AppState.self) var appState

    @State private var monitor: Any?
    @State private var message: String?
    /// Lone modifier key pressed during capture; it becomes the hotkey if released untouched.
    @State private var pendingModifier: UInt16?

    private var capturing: Bool { monitor != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Jarvis tuşu", systemImage: "keyboard")
                Spacer()
                if capturing {
                    Text("Bir tuşa basın… (Esc: iptal)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("İptal") { stopCapture() }
                        .controlSize(.small)
                } else {
                    Text(appState.jarvisHotkey?.label ?? "Atanmadı")
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                    Button(appState.jarvisHotkey == nil ? "Tuş ata" : "Değiştir") { startCapture() }
                        .controlSize(.small)
                    if appState.jarvisHotkey != nil {
                        Button("Kaldır") {
                            appState.jarvisHotkey = nil
                            message = nil
                        }
                        .controlSize(.small)
                    }
                }
            }
            if capturing && message == nil {
                Text("Tuşa bastığınız halde bir şey olmuyorsa macOS o tuşu kendine ayırmıştır (F5 dikte/klavye ışığı gibi): fn'i basılı tutarak tekrar basın.")
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
            Text("Bu tuşa basınca “Hey Jarvis” demişsiniz gibi dinlemeye başlar ve susunca kendiliğinden kapanır; kayıt sırasında tekrar basarsanız hemen bitirir. Fn'den ayrıdır. F tuşu (parlaklık/ses tuşlarında fn ile birlikte), sağ Option gibi tek bir tuş ya da ⌥J gibi bir kombinasyon olabilir.")
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
            stopCapture()
            appState.jarvisHotkey = key
            message = nil
        case .rejected(let why):
            message = why
        }
    }
}
