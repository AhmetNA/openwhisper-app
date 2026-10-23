import AppKit

/// The app that was in front when recording began. Its words come first wherever a transcript
/// is corrected or routed, without taking anything away from the others: in Claude, "Cloud" is
/// always Claude (its `@Claude` section of ses-benzerleri.txt), and the app's own name is
/// offered first to the ASR hotwords, the cleanup model and app-name matching.
struct AppFocus: Equatable, Sendable {
    let appName: String
    /// The lines of the app's `@Name` section in ses-benzerleri.txt.
    let entries: [SoundAlikeCorrector.Entry]

    /// The app name and the names its section writes, first in glossary and hotword lists.
    var terms: [String] { Self.unique([appName] + entries.map(\.canonical)) }

    init?(appName: String?, entries all: [SoundAlikeCorrector.Entry]) {
        guard let appName, !appName.isEmpty else { return nil }
        self.appName = appName
        let key = SoundAlikeCorrector.fold(appName)
        entries = all.filter { $0.app.map(SoundAlikeCorrector.fold) == key }
    }

    /// OpenWhisper itself in front (Settings, the history window) gives no focus.
    init?(app: NSRunningApplication?, entries all: [SoundAlikeCorrector.Entry]) {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        self.init(appName: app.localizedName, entries: all)
    }

    /// The sound-alike entries for a recording: this app's section first, then the lines that
    /// belong to no app. Other apps' sections are left out.
    static func soundAlikeEntries(_ all: [SoundAlikeCorrector.Entry], focus: AppFocus?) -> [SoundAlikeCorrector.Entry] {
        (focus?.entries ?? []) + all.filter { $0.app == nil }
    }

    /// `terms` with this app's first, each once.
    func prioritized(_ terms: [String]) -> [String] { Self.unique(self.terms + terms) }

    /// The same app names with this app moved to the front, so a spoken name that is equally
    /// close to two apps picks the one in front. Nothing is added or removed.
    func frontFirst(_ apps: [String]) -> [String] {
        let key = appName.lowercased()
        return apps.filter { $0.lowercased() == key } + apps.filter { $0.lowercased() != key }
    }

    private static func unique(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Set when recording starts, for the ASR server's hotwords, which are sent off the main
    /// actor while the session records.
    static var current: AppFocus? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: AppFocus?
}
