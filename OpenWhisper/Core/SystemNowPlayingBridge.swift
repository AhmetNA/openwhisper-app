import Foundation
import AppKit

/// Swift owns the session and per-player receipts. The system OSA host exposes metadata
/// restricted in third-party executables on newer macOS. State is read per saved
/// MRPlayerPath, but MediaRemote delivers commands to the global Now Playing app whatever
/// path they name (a "pause Safari" paused Spotify). So a command is sent only once the
/// global selection is that exact player and item; macOS moves it to the remaining player
/// shortly after the current one pauses.
struct SystemNowPlayingBridge: MediaRemoteAccess {
    func snapshots() -> [MediaPlaybackSnapshot] {
        let candidates = SystemMediaActivityMonitor.outputtingProcessIDs(excluding: ProcessInfo.processInfo.processIdentifier)
            .compactMap { pid -> Candidate? in
                guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
                return Candidate(pid: pid, bundle: bundle)
            }
        guard let data = try? JSONEncoder().encode(candidates), let json = String(data: data, encoding: .utf8),
              let result = run(["list", json]), let resultData = result.data(using: .utf8),
              let states = try? JSONDecoder().decode([State].self, from: resultData) else {
            owLog("[RecordingMedia] Now Playing list failed for \(candidates.map(\.bundle))")
            return []
        }
        owLog("[RecordingMedia] Now Playing \(candidates.map { "\($0.pid):\($0.bundle)" }) → \(states.map { "\($0.playerID)=\($0.playing ? "playing" : "paused")" })")
        return states.map(\.snapshot)
    }

    func snapshot(for player: MediaPlaybackSnapshot) -> MediaPlaybackSnapshot? {
        guard let route = player.route, let result = run(["status", route]),
              let data = result.data(using: .utf8),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        return state.snapshot
    }

    func send(_ command: MediaTransportCommand, to expected: MediaPlaybackSnapshot) -> Bool {
        guard expected.route != nil,
              let data = try? JSONEncoder().encode(State(expected)),
              let json = String(data: data, encoding: .utf8) else { return false }
        return run([String(command.rawValue), json]) == "true"
    }

    private struct Candidate: Codable { let pid: Int32; let bundle: String }
    private struct State: Codable {
        let playerID: String
        let playing: Bool
        let itemID: String?
        let position: Double?
        let route: String?
        init(_ state: MediaPlaybackSnapshot) {
            playerID = state.playerID; playing = state.isPlaying; itemID = state.itemID
            position = state.position; route = state.route
        }
        var snapshot: MediaPlaybackSnapshot {
            .init(playerID: playerID, isPlaying: playing, itemID: itemID, position: position, route: route)
        }
    }

    private func run(_ arguments: [String]) -> String? {
        OSAScriptRunner.run(["-l", "JavaScript", "-e", Self.source] + arguments)
    }

    private static let source = #"""
    ObjC.import('Foundation');
    function klass(name) { return $.NSClassFromString(name); }
    function controller(path) {
        const destination = klass('MRDestination').alloc.initWithPlayerPath(path);
        const result = klass('MRNowPlayingController').alloc.initWithDestination(destination);
        result.beginLoadingUpdates;
        return result;
    }
    function decodeRoute(token) {
        return klass('MRPlayerPath').alloc.initWithData($.NSData.alloc.initWithBase64EncodedStringOptions(token, 0));
    }
    function state(controller) {
        try {
            const response = controller.response;
            const path = response.playerPath;
            const info = ObjC.deepUnwrap(response._mostRelevantItem.nowPlayingInfo);
            if (!info) return null;
            // Spotify often omits PlaybackRate in its item metadata. Playback state belongs
            // to the player response (1 = playing, 2 = paused), not the content item.
            const playback = response.playbackState;
            if (playback !== 1 && playback !== 2) return null;
            const p = 'kMRMediaRemoteNowPlayingInfo';
            const title = info[p + 'Title'] || '';
            const content = info[p + 'ContentItemIdentifier'] || info[p + 'UniqueIdentifier'] || title;
            if (!content) return null;
            return {
                playerID: String(path.client.processIdentifier) + ':' + ObjC.unwrap(path.client.bundleIdentifier) + ':' + ObjC.unwrap(path.player.identifier),
                route: ObjC.unwrap(path.data.base64EncodedStringWithOptions(0)),
                itemID: JSON.stringify([content, title, info[p + 'Artist'] || '', info[p + 'Duration'] || 0]),
                playing: playback === 1,
                position: info[p + 'ElapsedTime']
            };
        } catch (_) { return null; }
    }
    function run(args) {
        let controllers = [];
        try {
            $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
            if (args[0] === 'list') {
                const local = klass('MRPlayerPath').localPlayerPath;
                for (const candidate of JSON.parse(args[1])) {
                    try {
                        const client = klass('MRClient').alloc.initWithProcessIdentifierBundleIdentifier(candidate.pid, candidate.bundle);
                        const path = klass('MRPlayerPath').alloc.initWithOriginClientPlayer(local.origin, client, klass('MRPlayer').defaultPlayer);
                        controllers.push(controller(path));
                    } catch (_) {}
                }
                // Include the selected path in case it uses a non-default player identifier.
                try { controllers.push(controller(klass('MRNowPlayingRequest').localNowPlayingPlayerPath)); } catch (_) {}
                // Responses load asynchronously and slower while the microphone starts, so a
                // single short delay can miss a playing player. Wait until one plays (max 1 s).
                let result = [];
                for (let i = 0; i < 10; i++) {
                    delay(i === 0 ? 0.2 : 0.1);
                    const seen = new Set();
                    result = [];
                    for (const c of controllers) {
                        const current = state(c);
                        if (current && !seen.has(current.playerID)) { result.push(current); seen.add(current.playerID); }
                    }
                    // Spotify is handled over AppleScript; wait for the others.
                    if (result.some(r => r.playing && r.playerID.indexOf(':com.spotify.client:') < 0)) break;
                }
                return JSON.stringify(result);
            }
            const expected = args[0] === 'status' ? null : JSON.parse(args[1]);
            const c = controller(decodeRoute(expected ? expected.route : args[1]));
            controllers.push(c);
            let current = null;
            for (let i = 0; i < 5 && !current; i++) { delay(0.1); current = state(c); }
            if (args[0] === 'status') return JSON.stringify(current);
            if (!current || current.playerID !== expected.playerID || current.itemID !== expected.itemID ||
                current.playing !== expected.playing) return 'false';
            let target = null;
            for (let i = 0; i < 5; i++) {
                const global = controller(klass('MRNowPlayingRequest').localNowPlayingPlayerPath);
                controllers.push(global);
                delay(0.1);
                const selected = state(global);
                if (selected && selected.playerID === expected.playerID && selected.itemID === expected.itemID) {
                    target = global;
                    current = selected;
                    break;
                }
            }
            if (!target) return 'false';
            const command = Number(args[0]);
            if (command === 0) {
                if (current.playing) return 'false';
                if (typeof current.position === 'number' && typeof expected.position === 'number' &&
                    Math.abs(current.position - expected.position) > 2) return 'false';
            } else if (command !== 1 || !current.playing) { return 'false'; }
            target.sendCommandOptionsCompletion(command, $.NSDictionary.alloc.init, null);
            delay(0.05);
            return 'true';
        } catch (_) { return 'false'; }
        finally { for (const c of controllers) { try { c.endLoadingUpdates; } catch (_) {} } }
    }
    """#
}

/// Runs `osascript` out of process with a timeout, so a hung player cannot block the media
/// queue and no in-process AppleScript competes with SpotifyController's commands.
enum OSAScriptRunner {
    static func run(_ arguments: [String], timeout: TimeInterval = 3) -> String? {
        #if APP_STORE
        return nil
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            owLog("[RecordingMedia] osascript failed to start: \(error)")
            return nil
        }
        let timeoutItem = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
        // Drain while running: a list of several players must not fill the pipe and deadlock.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutItem.cancel()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            owLog("[RecordingMedia] osascript exited \(process.terminationStatus)\(process.terminationReason == .uncaughtSignal ? " (timeout)" : ""): \(message.prefix(200))")
            return nil
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        #endif
    }
}

enum ScriptedMediaPlayers {
    static let all: [ScriptedMediaPlayer] = [spotify, vlc, safari]

    /// The track ID is stable across pause/resume, unlike Spotify's MediaRemote content ID.
    static let spotify = AppleScriptMediaPlayer(
        name: "Spotify",
        bundleID: SpotifyController.spotifyBundleID,
        pauseSource: """
            tell application id "com.spotify.client"
                if player state is playing then
                    set trackID to id of current track
                    pause
                    return trackID
                end if
            end tell
            return ""
            """,
        resumeSource: """
            on run argv
                tell application id "com.spotify.client"
                    if player state is paused and (id of current track) is (item 1 of argv) then
                        play
                        return "true"
                    end if
                end tell
                return "false"
            end run
            """
    )

    /// VLC's `play` toggles, so it is only sent after `playing` confirmed the state.
    static let vlc = AppleScriptMediaPlayer(
        name: "VLC",
        bundleID: "org.videolan.vlc",
        pauseSource: """
            tell application id "org.videolan.vlc"
                if playing then
                    set itemName to name of current item
                    play
                    return itemName
                end if
            end tell
            return ""
            """,
        resumeSource: """
            on run argv
                tell application id "org.videolan.vlc"
                    if not playing and (name of current item) is (item 1 of argv) then
                        play
                        return "true"
                    end if
                end tell
                return "false"
            end run
            """
    )

    /// Every tab's playing <video>/<audio> is paused and marked, and resume plays only the
    /// marked ones that are still paused. Needs Safari > Settings > Advanced > "Show features
    /// for web developers", then Develop > "Allow JavaScript from Apple Events"; until then
    /// the script fails and Safari falls back to MediaRemote.
    static let safari = AppleScriptMediaPlayer(
        name: "Safari",
        bundleID: "com.apple.Safari",
        coveredBundleIDs: ["com.apple.Safari", "com.apple.WebKit.GPU"],
        pauseSource: tabsScript(javaScript: """
            (function(){var n=0;document.querySelectorAll('[data-jarvis-paused]').forEach(function(m){delete m.dataset.jarvisPaused});\
            document.querySelectorAll('video,audio').forEach(function(m){if(!m.paused&&!m.ended){m.dataset.jarvisPaused='1';m.pause();n++}});return n})()
            """, result: "tabs"),
        resumeSource: tabsScript(javaScript: """
            (function(){var n=0;document.querySelectorAll('[data-jarvis-paused]').forEach(function(m){delete m.dataset.jarvisPaused;\
            if(m.paused){m.play();n++}});return n})()
            """, result: "true", otherwise: "false")
    )

    /// Runs `javaScript` in every Safari tab and sums the counts it returns. A tab that can't
    /// run it is skipped, except for error 8 (JavaScript from Apple Events is off), which
    /// fails the whole script.
    private static func tabsScript(javaScript: String, result: String, otherwise: String = "") -> String {
        """
        tell application id "com.apple.Safari"
            set total to 0
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set total to total + (do JavaScript "\(javaScript)" in t)
                    on error errText number errNum
                        if errNum is 8 then error errText number errNum
                    end try
                end repeat
            end repeat
        end tell
        if total > 0 then return "\(result)"
        return "\(otherwise)"
        """
    }
}

/// A player driven by AppleScript. The running check keeps `tell` from launching the app.
struct AppleScriptMediaPlayer: ScriptedMediaPlayer {
    let name: String
    let bundleID: String
    var coveredBundleIDs: Set<String>
    let pauseSource: String
    let resumeSource: String

    init(name: String, bundleID: String, coveredBundleIDs: Set<String>? = nil, pauseSource: String, resumeSource: String) {
        self.name = name
        self.bundleID = bundleID
        self.coveredBundleIDs = coveredBundleIDs ?? [bundleID]
        self.pauseSource = pauseSource
        self.resumeSource = resumeSource
    }

    func pause() -> ScriptedPauseResult {
        guard isRunning else { return .unavailable }
        guard let token = OSAScriptRunner.run(["-e", pauseSource]) else {
            owLog("[RecordingMedia] \(name) script unavailable; falling back to Now Playing")
            return .unavailable
        }
        return token.isEmpty ? .notPlaying : .paused(token: token)
    }

    func resume(token: String) -> Bool {
        guard isRunning else { return false }
        return OSAScriptRunner.run(["-e", resumeSource, token]) == "true"
    }

    private var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
