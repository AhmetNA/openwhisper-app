import Foundation

/// Timing for hands-free conversations. Hold-to-talk and confirmations keep their own rules.
enum ListeningMode: String, CaseIterable, Identifiable {
    case short
    case relaxed

    var id: String { rawValue }
    var title: String { self == .short ? "Kısa dinleme" : "Rahat dinleme" }
    var detail: String {
        self == .short
            ? "Mevcut hızda dinler ve yanıtlar."
            : "Başlamak için 10 sn; düşünme aralarında 5–10 sn bekler."
    }

    func apply(to config: inout VoiceEndpointDetector.Config) {
        guard self == .relaxed else { return }
        config.noSpeechTimeout = 10
        config.silenceToStop = 10
        config.maxDuration = max(config.maxDuration, 120)
    }

    func apply(to config: inout SmartTurnEndpointDetector.Config) {
        guard self == .relaxed else { return }
        config.noSpeechTimeout = 10
        config.certainSilence = 5
        config.veryHighConfidenceSilence = 6
        config.highConfidenceSilence = 7
        config.lowConfidenceSilence = 8
        config.incompleteSilenceTimeout = 10
        config.maxDuration = max(config.maxDuration, 120)
    }
}
