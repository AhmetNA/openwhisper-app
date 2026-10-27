import Foundation

/// "Son komutu geri al": the opposite of the Mac actions that have a clear one. Opening an app
/// has none (it may have been running already, and quitting it would lose its windows).
enum CommandUndo {
    static func inverse(of command: VoiceCommand) -> VoiceCommand? {
        guard case .system(let system) = command else { return nil }
        let opposite: SystemCommand?
        switch system {
        case .wifi(let on): opposite = .wifi(on: !on)
        case .bluetooth(let on): opposite = .bluetooth(on: !on)
        case .headset(let connect): opposite = .headset(connect: !connect)
        case .mute(let on): opposite = .mute(!on)
        case .brightness(let up, nil): opposite = .brightness(up: !up, level: nil)
        case .darkMode(let on): opposite = .darkMode(on: !on)
        case .quitApp(let name), .forceQuitApp(let name): opposite = .openApp(name)
        case .displaySleep: opposite = .displayWake
        case .browser(.newTab): opposite = .browser(.closeTab)
        case .browser(.back): opposite = .browser(.forward)
        case .browser(.forward): opposite = .browser(.back)
        case .browser(.nextTab): opposite = .browser(.previousTab)
        case .browser(.previousTab): opposite = .browser(.nextTab)
        case .video(.play): opposite = .video(.pause)
        case .video(.pause): opposite = .video(.play)
        case .video(.mute(let on)): opposite = .video(.mute(!on))
        case .video(.subtitles(let on)): opposite = .video(.subtitles(on: !on))
        case .video(.seekBy(let seconds)): opposite = .video(.seekBy(-seconds))
        default: opposite = nil
        }
        return opposite.map { .system($0) }
    }

    /// What undoes `ran`, last step first; empty when none of it can be undone.
    static func steps(undoing ran: [VoiceCommand]) -> [VoiceCommand] {
        ran.reversed().compactMap(inverse(of:))
    }
}
