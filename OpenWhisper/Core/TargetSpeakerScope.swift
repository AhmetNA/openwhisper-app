import Foundation

/// Where "Yalnızca Benim Sesim" applies: the "Jarvis" wake word, the dictated words, or both.
enum TargetSpeakerScope: String, CaseIterable, Identifiable, Sendable {
    case wakeWordOnly
    case always
    case transcriptionOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wakeWordOnly: "Sadece Jarvis"
        case .always: "Her zaman"
        case .transcriptionOnly: "Sadece yazıya dökme"
        }
    }

    var detail: String {
        switch self {
        case .wakeWordOnly: "“Jarvis” yalnızca sizin sesinizle uyanır; yazıya dökme herkesi yazar."
        case .always: "“Jarvis” yalnızca sizin sesinizle uyanır ve yalnızca sizin sözleriniz yazılır."
        case .transcriptionOnly: "Yalnızca sizin sözleriniz yazılır; “Jarvis” herkesin sesiyle uyanır."
        }
    }

    var coversWakeWord: Bool { self != .transcriptionOnly }
    var coversTranscription: Bool { self != .wakeWordOnly }

    static let defaultsKey = "targetSpeakerScope"
    /// The feature filtered dictation only before this setting existed.
    static let defaultValue: TargetSpeakerScope = .transcriptionOnly
}
