import AppKit
import Foundation

/// Drives the `<video>` in Safari through `do JavaScript`: precise (seek, speed, subtitles)
/// and per tab, unlike media keys or MediaRemote, which only toggle whatever app holds Now
/// Playing (often Spotify). Needs the same Safari setting as the recording pause: Develop >
/// "Allow JavaScript from Apple Events". Play and pause fall back to MediaRemote for other
/// players (Chrome, Stremio, IINA) and for Safari without that setting.
enum VideoController {
    static let safariBundleID = "com.apple.Safari"
    static var notFound: String { L("Oynatılan video bulunamadı", "No playing video found") }
    static var javaScriptOff: String { L("Safari'de Apple Events'ten JavaScript izni kapalı", "Safari's Allow JavaScript from Apple Events is off") }
    static var unreachable: String { L("Safari'ye ulaşılamadı", "Couldn't reach Safari") }
    static var noButton: String { L("Bu videoda o düğme yok", "This video has no such button") }
    static var outOfRange: String { L("Video o kadar uzun değil", "The video isn't that long") }
    static var failures: Set<String> { [notFound, javaScriptOff, unreachable, noButton, outOfRange, BrowserController.notFront, BrowserController.youTubeNeedsVideo] }
    private static var fullscreenFailed: String { L("Tam ekran yapılamadı", "Couldn't go full screen") }
    private static var fullscreenOnlyYouTube: String { L("Tam ekran yalnızca YouTube'da", "Full screen works only on YouTube") }

    static func isFullscreenFailure(_ status: String) -> Bool {
        status == fullscreenFailed || status == fullscreenOnlyYouTube
    }

    static func perform(_ action: VideoAction, onlyYouTube: Bool = false) async -> String {
        await Task.detached(priority: .userInitiated) { performBlocking(action, onlyYouTube: onlyYouTube) }.value
    }

    private static func performBlocking(_ action: VideoAction, onlyYouTube: Bool) -> String {
        if action == .fullscreen { return fullscreen() }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: safariBundleID).isEmpty
        let result = running ? runInBestTab(javaScript(for: action), onlyYouTube: onlyYouTube) : "none"
        owLog("[Video] \(action) → \(result ?? "script failed")")
        switch result {
        case "jsoff":
            return (onlyYouTube ? nil : mediaRemoteFallback(action)) ?? javaScriptOff
        case "denied", nil:
            return (onlyYouTube ? nil : mediaRemoteFallback(action)) ?? unreachable
        case "none":
            return (onlyYouTube ? nil : mediaRemoteFallback(action)) ?? notFound
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
        case .play: return playing
        case .pause: return paused
        case .restart: return L("Video başa sarıldı", "Video restarted")
        case .seekBy(let seconds):
            return L("\(Self.duration(abs(seconds))) \(seconds < 0 ? "geri" : "ileri") sarıldı",
                     "\(seconds < 0 ? "Back" : "Forward") \(Self.duration(abs(seconds)))")
        case .seekTo(let seconds): return L("Video \(Self.clock(seconds)) konumuna alındı", "Video at \(Self.clock(seconds))")
        case .speed, .speedStep:
            let rate = Double(result) ?? 1
            return rate == 1 ? L("Video normal hızda", "Video at normal speed") : L("Video hızı \(Self.rate(rate))x", "Video speed \(Self.rate(rate))x")
        case .mute(let mute): return mute ? L("Videonun sesi kapatıldı", "Video muted") : L("Videonun sesi açıldı", "Video unmuted")
        case .subtitles(let on): return on ? L("Altyazı açıldı", "Subtitles on") : L("Altyazı kapatıldı", "Subtitles off")
        case .next: return L("Sonraki video", "Next video")
        case .fullscreen: return fullscreenOn
        case .remaining:
            let parts = result.split(separator: "|").compactMap { Double($0) }
            guard parts.count == 2 else { return notFound }
            guard parts[1].isFinite, parts[1] > 0 else { return L("Bu canlı yayın, süresi yok", "This is a live stream, it has no length") }
            let left = max(0, Int(parts[1] - parts[0]))
            return L("Videonun bitmesine \(Self.duration(left)) var, toplam \(Self.duration(Int(parts[1])))",
                     "\(Self.duration(left)) left of \(Self.duration(Int(parts[1])))")
        }
    }

    // MARK: - Safari

    /// Picks the video in this page: the one the recording paused (`data-jarvis-paused`, see
    /// `ScriptedMediaPlayers.safari`), else a playing one, else the largest loaded one, so a
    /// small hover preview or ad loses to the main player. Muted looping or short (< 120 px)
    /// videos are banner ads: on film sites the film sits in a cross-origin iframe this script
    /// can't reach, and "durdur" paused a 7 s ad while the film went on. Without a real video
    /// the page reports none and Now Playing takes over. No double quotes: the snippet goes
    /// inside `do JavaScript "…"`.
    private static let pickVideo = """
        var vs=Array.prototype.slice.call(document.querySelectorAll('video')).filter(function(m){return !(m.muted&&m.loop)&&m.clientHeight>=120});\
        var v=vs.filter(function(m){return m.dataset.jarvisPaused})[0]\
        ||vs.filter(function(m){return !m.paused&&!m.ended})[0]\
        ||vs.filter(function(m){return m.duration>0}).sort(function(a,b){return b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight})[0];\
        if(!v)return 'none';
        """

    /// 3 = the recording paused a video here, 2 = one is playing, 1 = one is loaded.
    private static let probe = """
        (function(){var s=0;document.querySelectorAll('video').forEach(function(m){\
        if((m.muted&&m.loop)||m.clientHeight<120)return;if(m.dataset.jarvisPaused)s=3;else if(!m.paused&&!m.ended&&m.duration>0)s=Math.max(s,2);\
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
    private static func runInBestTab(_ javaScript: String, onlyYouTube: Bool) -> String? {
        OSAScriptRunner.run(["-e", bestTabScript(javaScript, onlyYouTube: onlyYouTube)], timeout: 8)
    }

    static func bestTabScript(_ javaScript: String, onlyYouTube: Bool = false) -> String {
        let scope = onlyYouTube ? "if(location.hostname!=='youtube.com'&&!location.hostname.endsWith('.youtube.com'))return 0;" : ""
        let scopedProbe = onlyYouTube ? "(function(){\(scope)return \(probe)})()" : probe
        return """
            on probe(t)
                tell application id "com.apple.Safari" to return (do JavaScript "\(scopedProbe)" in t)
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

    /// `before` and `after` are AppleScript keywords; as variable names they broke the whole
    /// script ("Expected expression but found to"), so the state lives in fsBefore/fsAfter.
    /// `VideoScriptCompileTests` compiles this with osacompile.
    static let fullscreenScript: String = {
        let state = "(document.fullscreenElement||document.webkitFullscreenElement)?'on':'off'"
        let focus = "(function(){var a=document.activeElement;if(a&&a.blur){a.blur();}var p=document.getElementById('movie_player');if(p){p.focus();}return 'ok';})()"
        return """
            tell application id "com.apple.Safari"
                set t to current tab of front window
                set u to URL of t
                if u does not contain "youtube.com/watch" then return "nobutton"
                set fsBefore to "unknown"
                try
                    set fsBefore to (do JavaScript "\(state)" in t) as text
                    do JavaScript "\(focus)" in t
                end try
            end tell
            delay 0.15
            tell application "System Events" to keystroke "f"
            if fsBefore is "unknown" then return "sent"
            delay 0.8
            tell application id "com.apple.Safari"
                set fsAfter to (do JavaScript "\(state)" in current tab of front window) as text
            end tell
            if fsAfter is fsBefore then return "unchanged"
            return fsAfter
            """
    }()

    /// YouTube's own "f" shortcut; only into Safari while it is in front, never another app.
    /// The player gets keyboard focus first: with the caret in the search box (or on a button
    /// Jarvis clicked earlier) the "f" went nowhere and Jarvis still said "Tam ekran". Whether
    /// the page actually changed is checked afterwards, when JavaScript is allowed.
    private static func fullscreen() -> String {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariBundleID else {
            return BrowserController.notFront
        }
        let source = fullscreenScript
        let result = OSAScriptRunner.run(["-e", source])
        owLog("[Video] fullscreen → \(result ?? "script failed")")
        switch result {
        case "on", "sent": return fullscreenOn
        case "off": return L("Tam ekrandan çıkıldı", "Left full screen")
        case "unchanged": return fullscreenFailed
        case "nobutton": return fullscreenOnlyYouTube
        default: return unreachable
        }
    }

    /// A YouTube video in the front Safari tab, with Safari in front: "tam ekran yap" is then
    /// the video's, otherwise the front window's (`WindowManager`).
    static func youTubeVideoInFront() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariBundleID else { return false }
        let url = OSAScriptRunner.run(["-e", #"tell application id "com.apple.Safari" to return URL of current tab of front window"#], timeout: 3)
        return url?.contains("youtube.com/watch") == true
    }

    // MARK: - Other players

    /// Play/pause for whatever else holds Now Playing (Chrome, Stremio, IINA, Safari without
    /// the JavaScript setting). Spotify is left alone: "müziği durdur" is its command.
    private static func mediaRemoteFallback(_ action: VideoAction) -> String? {
        if !action.changesPlayback { return nowPlayingSeek(action) }
        let bridge = SystemNowPlayingBridge()
        let players = bridge.snapshots().filter { !$0.playerID.contains(":\(SpotifyController.spotifyBundleID):") }
        if action == .pause {
            guard let playing = players.first(where: \.isPlaying) else {
                // The recording already paused it; not resuming it is the pause.
                return players.isEmpty ? nil : self.paused
            }
            return bridge.send(.pause, to: playing) ? self.paused : nil
        }
        if players.contains(where: \.isPlaying) { return self.playing }
        guard let paused = players.first, bridge.send(.play, to: paused) else { return nil }
        return self.playing
    }

    /// Seek and "kaç dakika kaldı" for a video Safari's JavaScript can't reach (a film in a
    /// cross-origin iframe), through the Now Playing session WebKit keeps for it. Only when the
    /// system's selected Now Playing player is not Spotify: MediaRemote commands go to that
    /// player whatever path they name, and "20 saniye geri al" must never rewind a song.
    private static func nowPlayingSeek(_ action: VideoAction) -> String? {
        let mode: String
        switch action {
        case .seekBy(let seconds): mode = "by:\(seconds)"
        case .seekTo(let seconds): mode = "to:\(seconds)"
        case .restart: mode = "to:0"
        case .remaining: mode = "read"
        default: return nil
        }
        let result = OSAScriptRunner.run(["-l", "JavaScript", "-e", nowPlayingSeekSource, mode, SpotifyController.spotifyBundleID])
        owLog("[Video] Now Playing \(mode) → \(result ?? "script failed")")
        switch result {
        case "range": return outOfRange
        case let value? where value.contains("|"): return status(for: action, result: value)
        default: return nil
        }
    }

    /// Prints "position|duration" (position after the seek), "range" or "none". The live
    /// position is ElapsedTime advanced by the time since its Timestamp at PlaybackRate: the
    /// stored ElapsedTime is only refreshed on state changes. Command 24 = change position.
    static let nowPlayingSeekSource = #"""
    ObjC.import('Foundation');
    function run(argv) {
        let c = null;
        try {
            $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
            const k = n => $.NSClassFromString(n);
            c = k('MRNowPlayingController').alloc.initWithDestination(
                k('MRDestination').alloc.initWithPlayerPath(k('MRNowPlayingRequest').localNowPlayingPlayerPath));
            c.beginLoadingUpdates;
            let response = null, info = null;
            for (let i = 0; i < 8 && !info; i++) {
                delay(0.1);
                response = c.response;
                try { info = ObjC.deepUnwrap(response._mostRelevantItem.nowPlayingInfo); } catch (_) {}
            }
            if (!info || ObjC.unwrap(response.playerPath.client.bundleIdentifier) === argv[1]) return 'none';
            const p = 'kMRMediaRemoteNowPlayingInfo';
            const duration = Number(info[p + 'Duration']) || 0;
            let position = Number(info[p + 'ElapsedTime']) || 0;
            const stamp = info[p + 'Timestamp'];
            if (stamp) position += Math.max(0, (Date.now() - new Date(stamp).getTime()) / 1000) * (Number(info[p + 'PlaybackRate']) || 0);
            if (argv[0] === 'read') return position + '|' + duration;
            const amount = Number(argv[0].slice(3));
            let target = argv[0].startsWith('to:') ? amount : position + amount;
            if (argv[0].startsWith('to:') && duration > 0 && target >= duration) return 'range';
            target = Math.max(0, duration > 0 ? Math.min(duration - 1, target) : target);
            const options = $.NSDictionary.dictionaryWithObjectForKey($.NSNumber.numberWithDouble(target), 'kMRMediaRemoteOptionPlaybackPosition');
            c.sendCommandOptionsCompletion(24, options, null);
            delay(0.05);
            return target + '|' + duration;
        } catch (_) { return 'none'; }
        finally { if (c) { try { c.endLoadingUpdates; } catch (_) {} } }
    }
    """#

    private static var playing: String { L("Video oynatılıyor", "Video playing") }
    private static var paused: String { L("Video durduruldu", "Video paused") }
    private static var fullscreenOn: String { L("Tam ekran", "Full screen") }

    // MARK: - Formatting

    /// "1 dakika 30 saniye", "45 saniye", "1 saat 5 dakika".
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        var parts: [String] = []
        let english = CommandLanguage.isEnglish
        if h > 0 { parts.append(english ? "\(h) hour\(h == 1 ? "" : "s")" : "\(h) saat") }
        if m > 0 { parts.append(english ? "\(m) minute\(m == 1 ? "" : "s")" : "\(m) dakika") }
        if s > 0 && h == 0 { parts.append(english ? "\(s) second\(s == 1 ? "" : "s")" : "\(s) saniye") }
        return parts.isEmpty ? L("0 saniye", "0 seconds") : parts.joined(separator: " ")
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
