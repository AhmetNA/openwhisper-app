import AppKit
import Foundation

/// A video by voice: "videoyu durdur", "başa sar", "10 saniye ileri sar", "hızı 1.5 yap".
enum VideoAction: Equatable, Sendable {
    case play
    case pause
    case restart
    /// Relative jump in seconds; negative goes back.
    case seekBy(Int)
    /// Absolute position in seconds ("videoyu 5. dakikaya al").
    case seekTo(Int)
    /// Absolute playback rate (1 = normal).
    case speed(Double)
    /// One 0.25 step faster or slower.
    case speedStep(faster: Bool)
    case mute(Bool)
    /// YouTube's subtitles button.
    case subtitles(on: Bool)
    /// YouTube's next-video button.
    case next
    /// YouTube's "f" key; there is no fullscreen without a real user gesture otherwise.
    case fullscreen
    /// "Videonun bitmesine ne kadar var?"
    case remaining

    /// Play and pause decide what should be playing after the command, so the video the
    /// recording paused is not resumed over them. Everything else continues afterwards.
    var changesPlayback: Bool { self == .play || self == .pause }
}

/// Drives the `<video>` in Safari through `do JavaScript`: precise (seek, speed, subtitles)
/// and per tab, unlike media keys or MediaRemote, which only toggle whatever app holds Now
/// Playing (often Spotify). Needs the same Safari setting as the recording pause: Develop >
/// "Allow JavaScript from Apple Events". Play and pause fall back to MediaRemote for other
/// players (Chrome, Stremio, IINA) and for Safari without that setting.
enum VideoController {
    static let safariBundleID = "com.apple.Safari"
    static let notFound = "Oynatılan video bulunamadı"
    static let javaScriptOff = "Safari'de Apple Events'ten JavaScript izni kapalı"
    static let unreachable = "Safari'ye ulaşılamadı"
    static let noButton = "Bu videoda o düğme yok"
    static let outOfRange = "Video o kadar uzun değil"
    static let failures: Set<String> = [notFound, javaScriptOff, unreachable, noButton, outOfRange, BrowserController.notFront]

    static func perform(_ action: VideoAction) async -> String {
        await Task.detached(priority: .userInitiated) { performBlocking(action) }.value
    }

    private static func performBlocking(_ action: VideoAction) -> String {
        if action == .fullscreen { return fullscreen() }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: safariBundleID).isEmpty
        let result = running ? runInBestTab(javaScript(for: action)) : "none"
        owLog("[Video] \(action) → \(result ?? "script failed")")
        switch result {
        case "jsoff":
            return mediaRemoteFallback(action) ?? javaScriptOff
        case "denied", nil:
            return mediaRemoteFallback(action) ?? unreachable
        case "none":
            return mediaRemoteFallback(action) ?? notFound
        case "nobutton":
            return noButton
        case "range":
            return outOfRange
        case let value?:
            return status(for: action, result: value)
        }
    }

    private static func status(for action: VideoAction, result: String) -> String {
        switch action {
        case .play: return "Video oynatılıyor"
        case .pause: return "Video durduruldu"
        case .restart: return "Video başa sarıldı"
        case .seekBy(let seconds):
            return "\(Self.duration(abs(seconds))) \(seconds < 0 ? "geri" : "ileri") sarıldı"
        case .seekTo(let seconds): return "Video \(Self.clock(seconds)) konumuna alındı"
        case .speed, .speedStep:
            let rate = Double(result) ?? 1
            return rate == 1 ? "Video normal hızda" : "Video hızı \(Self.rate(rate))x"
        case .mute(let mute): return mute ? "Videonun sesi kapatıldı" : "Videonun sesi açıldı"
        case .subtitles(let on): return on ? "Altyazı açıldı" : "Altyazı kapatıldı"
        case .next: return "Sonraki video"
        case .fullscreen: return "Tam ekran"
        case .remaining:
            let parts = result.split(separator: "|").compactMap { Double($0) }
            guard parts.count == 2 else { return notFound }
            guard parts[1].isFinite, parts[1] > 0 else { return "Bu canlı yayın, süresi yok" }
            let left = max(0, Int(parts[1] - parts[0]))
            return "Videonun bitmesine \(Self.duration(left)) var, toplam \(Self.duration(Int(parts[1])))"
        }
    }

    // MARK: - Safari

    /// Picks the video in this page: the one the recording paused (`data-jarvis-paused`, see
    /// `ScriptedMediaPlayers.safari`), else a playing one, else the largest loaded one, so a
    /// small hover preview or ad loses to the main player. No double quotes: the snippet goes
    /// inside `do JavaScript "…"`.
    private static let pickVideo = """
        var vs=Array.prototype.slice.call(document.querySelectorAll('video'));\
        var v=vs.filter(function(m){return m.dataset.jarvisPaused})[0]\
        ||vs.filter(function(m){return !m.paused&&!m.ended})[0]\
        ||vs.filter(function(m){return m.duration>0}).sort(function(a,b){return b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight})[0];\
        if(!v)return 'none';
        """

    /// 3 = the recording paused a video here, 2 = one is playing, 1 = one is loaded.
    private static let probe = """
        (function(){var s=0;document.querySelectorAll('video').forEach(function(m){\
        if(m.dataset.jarvisPaused)s=3;else if(!m.paused&&!m.ended&&m.duration>0)s=Math.max(s,2);\
        else if(m.duration>0)s=Math.max(s,1)});return s})()
        """

    /// After play/pause the recording's mark is stale: the command decided the state.
    private static let clearMarks = "document.querySelectorAll('[data-jarvis-paused]').forEach(function(m){delete m.dataset.jarvisPaused});"

    static func javaScript(for action: VideoAction) -> String {
        let body: String
        switch action {
        case .play: body = "v.play();\(clearMarks)return 'ok';"
        case .pause: body = "v.pause();\(clearMarks)return 'ok';"
        case .restart: body = "v.currentTime=0;return 'ok';"
        case .seekBy(let seconds):
            body = "v.currentTime=Math.max(0,Math.min(isFinite(v.duration)?v.duration-1:1e9,v.currentTime+(\(seconds))));return 'ok';"
        case .seekTo(let seconds):
            body = "if(isFinite(v.duration)&&\(seconds)>=v.duration)return 'range';v.currentTime=\(seconds);return 'ok';"
        case .speed(let rate):
            body = "v.playbackRate=\(rate);return String(v.playbackRate);"
        case .speedStep(let faster):
            body = "v.playbackRate=Math.min(3,Math.max(0.25,v.playbackRate\(faster ? "+" : "-")0.25));return String(v.playbackRate);"
        case .mute(let mute): body = "v.muted=\(mute);return 'ok';"
        case .subtitles(let on):
            body = "var b=document.querySelector('.ytp-subtitles-button');if(!b||b.style.display==='none')return 'nobutton';"
                + "if((b.getAttribute('aria-pressed')==='true')!==\(on))b.click();return 'ok';"
        case .next:
            body = "var b=document.querySelector('.ytp-next-button');if(!b||!b.offsetParent)return 'nobutton';b.click();return 'ok';"
        case .remaining:
            body = "return v.currentTime+'|'+(isFinite(v.duration)?v.duration:0);"
        case .fullscreen:
            body = "return 'ok';"
        }
        return "(function(){\(pickVideo)\(body)})()"
    }

    /// Probes every tab and runs `javaScript` in the best one; the current tab of the front
    /// window wins a tie. Error 8 = "Allow JavaScript from Apple Events" is off, -1743 = no
    /// Automation permission for Safari.
    private static func runInBestTab(_ javaScript: String) -> String? {
        OSAScriptRunner.run(["-e", bestTabScript(javaScript)], timeout: 8)
    }

    static func bestTabScript(_ javaScript: String) -> String {
        """
            on probe(t)
                tell application id "com.apple.Safari" to return (do JavaScript "\(probe)" in t)
            end probe
            tell application id "com.apple.Safari"
                set best to missing value
                set bestScore to 0
                set candidates to {}
                try
                    set end of candidates to current tab of front window
                end try
                repeat with w in windows
                    repeat with t in tabs of w
                        set end of candidates to contents of t
                    end repeat
                end repeat
                repeat with t in candidates
                    try
                        set s to my probe(contents of t)
                        if s > bestScore then
                            set best to contents of t
                            set bestScore to s
                        end if
                    on error errText number errNum
                        if errNum is 8 then return "jsoff"
                        if errNum is -1743 then return "denied"
                    end try
                end repeat
                if best is missing value then return "none"
                return (do JavaScript "\(javaScript)" in best) as text
            end tell
            """
    }

    /// YouTube's own "f" shortcut; only into Safari while it is in front, never another app.
    /// The player gets keyboard focus first: with the caret in the search box (or on a button
    /// Jarvis clicked earlier) the "f" went nowhere and Jarvis still said "Tam ekran". Whether
    /// the page actually changed is checked afterwards, when JavaScript is allowed.
    private static func fullscreen() -> String {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariBundleID else {
            return BrowserController.notFront
        }
        let state = "(document.fullscreenElement||document.webkitFullscreenElement)?'on':'off'"
        let focus = "(function(){var a=document.activeElement;if(a&&a.blur){a.blur();}var p=document.getElementById('movie_player');if(p){p.focus();}return 'ok';})()"
        let source = """
            tell application id "com.apple.Safari"
                set t to current tab of front window
                set u to URL of t
                if u does not contain "youtube.com/watch" then return "nobutton"
                set before to "unknown"
                try
                    set before to (do JavaScript "\(state)" in t) as text
                    do JavaScript "\(focus)" in t
                end try
            end tell
            delay 0.15
            tell application "System Events" to keystroke "f"
            if before is "unknown" then return "sent"
            delay 0.8
            tell application id "com.apple.Safari"
                set after to (do JavaScript "\(state)" in current tab of front window) as text
            end tell
            if after is before then return "unchanged"
            return after
            """
        let result = OSAScriptRunner.run(["-e", source])
        owLog("[Video] fullscreen → \(result ?? "script failed")")
        switch result {
        case "on", "sent": return "Tam ekran"
        case "off": return "Tam ekrandan çıkıldı"
        case "unchanged": return "Tam ekran yapılamadı"
        case "nobutton": return "Tam ekran yalnızca YouTube'da"
        default: return unreachable
        }
    }

    // MARK: - Other players

    /// Play/pause for whatever else holds Now Playing (Chrome, Stremio, IINA, Safari without
    /// the JavaScript setting). Spotify is left alone: "müziği durdur" is its command.
    private static func mediaRemoteFallback(_ action: VideoAction) -> String? {
        guard action.changesPlayback else { return nil }
        let bridge = SystemNowPlayingBridge()
        let players = bridge.snapshots().filter { !$0.playerID.contains(":\(SpotifyController.spotifyBundleID):") }
        if action == .pause {
            guard let playing = players.first(where: \.isPlaying) else {
                // The recording already paused it; not resuming it is the pause.
                return players.isEmpty ? nil : "Video durduruldu"
            }
            return bridge.send(.pause, to: playing) ? "Video durduruldu" : nil
        }
        if players.contains(where: \.isPlaying) { return "Video oynatılıyor" }
        guard let paused = players.first, bridge.send(.play, to: paused) else { return nil }
        return "Video oynatılıyor"
    }

    // MARK: - Formatting

    /// "1 dakika 30 saniye", "45 saniye", "1 saat 5 dakika".
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) saat") }
        if m > 0 { parts.append("\(m) dakika") }
        if s > 0 && h == 0 { parts.append("\(s) saniye") }
        return parts.isEmpty ? "0 saniye" : parts.joined(separator: " ")
    }

    static func clock(_ seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func rate(_ rate: Double) -> String {
        rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate).replacingOccurrences(of: ".", with: ",")
    }
}
