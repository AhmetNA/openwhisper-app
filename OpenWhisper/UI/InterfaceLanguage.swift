import AppKit

/// The app's own interface language ("tr" or "en"). macOS picks the app's strings from
/// `AppleLanguages` at launch, so a change takes effect after a relaunch.
enum InterfaceLanguage {
    static let key = "interfaceLanguage"
    /// Voice provider in use before English switched it to Phonon; restored on Turkish.
    private static let previousVoiceKey = "voiceProviderBeforeEnglish"

    static var current: String { UserDefaults.standard.string(forKey: key) ?? "tr" }

    /// The language the running app's strings were loaded in.
    static let launched = current

    /// Pins the app's language: the Mac's own list may start with English.
    static func apply() {
        UserDefaults.standard.set([current], forKey: "AppleLanguages")
    }

    @MainActor
    static func set(_ language: String, appState: AppState) {
        guard language != current else { return }
        UserDefaults.standard.set(language, forKey: key)
        apply()
        let phonon = LocalPhononProvider.descriptor.id
        if language == "en" {
            if appState.voiceProviderID != phonon {
                UserDefaults.standard.set(appState.voiceProviderID, forKey: previousVoiceKey)
            }
            appState.voiceProviderID = phonon
        } else if appState.voiceProviderID == phonon {
            appState.voiceProviderID = UserDefaults.standard.string(forKey: previousVoiceKey) ?? SpeechProviders.defaultID
        }
    }

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Translates a fixed Turkish UI text kept in a `String`; literals in `Text("…")` translate on their own.
func loc(_ text: String) -> String {
    Bundle.main.localizedString(forKey: text, value: text, table: nil)
}
