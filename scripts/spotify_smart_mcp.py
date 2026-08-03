#!/usr/bin/env python3
"""
Spotify Smart Dual-Mode MCP Server
Model Context Protocol (MCP) server for Spotify control on macOS.
Supports both Online Web API mode (when credentials & internet are available)
and Offline AppleScript Fallback mode (%100 local, no network required).

NOTE: This process is launched with `/usr/bin/python3` (macOS system Python,
currently 3.9.x). `from __future__ import annotations` below is required so
PEP 604 union-type annotations (`dict | str`) don't raise a TypeError at
import time on 3.9 — without it, the whole process dies before the stdio
loop ever starts, and every Swift-side call silently times out after 3s.
Keep this as the first statement after the docstring if editing this file.
"""

from __future__ import annotations

import sys
import json
import subprocess
import urllib.request
import urllib.parse
import urllib.error
import os
import re


EXPLICIT_INTENT_KEY = "explicit_intent"
EXPLICIT_INTENT_ERROR = (
    "Refused: Spotify action requires a validated explicit user command "
    f"({EXPLICIT_INTENT_KEY}=true)."
)


def has_explicit_intent(params: dict) -> bool:
    """Accept only an exact JSON boolean true, never truthy strings/numbers."""
    return isinstance(params, dict) and params.get(EXPLICIT_INTENT_KEY) is True


def require_explicit_intent(params: dict) -> str | None:
    """Return a refusal message unless the caller attests explicit user intent."""
    return None if has_explicit_intent(params) else EXPLICIT_INTENT_ERROR

# --- Helper Functions for Local AppleScript Control ---

def run_applescript(script: str) -> tuple[bool, str]:
    """Runs an AppleScript command via osascript and returns (success, output)."""
    full_script = f'tell application "Spotify" to {script}'
    try:
        res = subprocess.run(
            ["osascript", "-e", full_script],
            capture_output=True,
            text=True,
            timeout=5
        )
        if res.returncode == 0:
            return True, res.stdout.strip()
        else:
            return False, res.stderr.strip()
    except Exception as e:
        return False, str(e)

def is_spotify_running() -> bool:
    """Checks if Spotify application is currently running on macOS."""
    try:
        res = subprocess.run(
            ["pgrep", "-x", "Spotify"],
            capture_output=True,
            text=True
        )
        return res.returncode == 0
    except Exception:
        return False

def check_internet() -> bool:
    """Quick check to verify if internet is accessible."""
    try:
        urllib.request.urlopen("https://1.1.1.1", timeout=2)
        return True
    except Exception:
        return False

# --- Web API Functions (Used when Online & Token provided) ---

def web_api_request(endpoint: str, method: str = "GET", data: dict = None, token: str = None) -> tuple[bool, dict | str]:
    """Executes a Spotify Web API request using python standard library."""
    if not token:
        return False, "No access token provided"
    
    url = f"https://api.spotify.com/v1/{endpoint.lstrip('/')}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }
    
    body_bytes = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body_bytes, headers=headers, method=method)
    
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            if resp.status in (200, 201):
                raw = resp.read().decode("utf-8")
                return True, json.loads(raw) if raw else {}
            elif resp.status == 204:
                return True, {}
            else:
                return False, f"HTTP {resp.status}"
    except urllib.error.HTTPError as e:
        return False, f"HTTP Error {e.code}: {e.reason}"
    except Exception as e:
        return False, str(e)

# --- MCP Tool Handlers (Smart Dual Mode) ---

def tool_play_pause(params: dict) -> str:
    """Toggles play/pause state."""
    if refusal := require_explicit_intent(params):
        return refusal
    ok, out = run_applescript("playpause")
    if ok:
        return "Spotify playback toggled (Local AppleScript)."
    return f"Failed to toggle playback: {out}"

def tool_play(params: dict) -> str:
    """Starts or resumes playback without toggle ambiguity."""
    if refusal := require_explicit_intent(params):
        return refusal
    ok, out = run_applescript("play")
    if ok:
        return "Spotify playback started (Local AppleScript)."
    return f"Failed to start playback: {out}"

def tool_pause(params: dict) -> str:
    """Pauses playback without toggle ambiguity."""
    if refusal := require_explicit_intent(params):
        return refusal
    ok, out = run_applescript("pause")
    if ok:
        return "Spotify playback paused (Local AppleScript)."
    return f"Failed to pause playback: {out}"

def tool_next_track(params: dict) -> str:
    """Skips to the next track."""
    if refusal := require_explicit_intent(params):
        return refusal
    ok, out = run_applescript("next track")
    if ok:
        return "Skipped to next track (Local AppleScript)."
    return f"Failed to skip track: {out}"

def tool_previous_track(params: dict) -> str:
    """Goes to previous track."""
    if refusal := require_explicit_intent(params):
        return refusal
    ok, out = run_applescript("previous track")
    if ok:
        return "Returned to previous track (Local AppleScript)."
    return f"Failed to go to previous track: {out}"

def tool_set_volume(params: dict) -> str:
    """Sets Spotify volume (0-100)."""
    if refusal := require_explicit_intent(params):
        return refusal
    volume = params.get("volume")
    if isinstance(volume, bool) or not isinstance(volume, (int, float)):
        return "Invalid volume value. Expected integer 0-100."
    if not float(volume).is_integer() or not 0 <= volume <= 100:
        return "Invalid volume value. Expected integer 0-100."
    vol = int(volume)
    
    ok, out = run_applescript(f"set sound volume to {vol}")
    if ok:
        return f"Spotify volume set to {vol}% (Local AppleScript)."
    return f"Failed to set volume: {out}"

def tool_get_current_track(params: dict) -> str:
    """Gets currently playing track info."""
    if refusal := require_explicit_intent(params):
        return refusal
    if not is_spotify_running():
        return "Spotify is not currently running."
    
    ok_state, state = run_applescript("player state as text")
    ok_track, track = run_applescript("name of current track")
    ok_artist, artist = run_applescript("artist of current track")
    ok_album, album = run_applescript("album of current track")
    
    if ok_track and ok_artist:
        status_str = f"Status: {state.capitalize() if ok_state else 'Unknown'}\n"
        status_str += f"Track: {track}\nArtist: {artist}"
        if ok_album and album:
            status_str += f"\nAlbum: {album}"
        return status_str
    
    return "Could not fetch current track info from Spotify."

def tool_search_and_play(params: dict) -> str:
    """Searches for a track or artist and plays it."""
    if refusal := require_explicit_intent(params):
        return refusal
    query_value = params.get("query")
    if not isinstance(query_value, str):
        return "Error: Search query must be a string."
    query = query_value.strip()
    if not query:
        return "Error: Search query cannot be empty."
    
    token = params.get("access_token") or os.environ.get("SPOTIFY_ACCESS_TOKEN")
    
    # Try Web API search if online & token available
    if token and check_internet():
        encoded_q = urllib.parse.quote(query)
        ok, res = web_api_request(f"search?q={encoded_q}&type=track&limit=1", token=token)
        if ok and isinstance(res, dict):
            tracks = res.get("tracks", {}).get("items", [])
            if tracks:
                track_uri = tracks[0]["uri"]
                track_name = tracks[0]["name"]
                artist_name = tracks[0]["artists"][0]["name"]
                # Play via Web API
                play_ok, _ = web_api_request("me/player/play", method="PUT", data={"uris": [track_uri]}, token=token)
                if play_ok:
                    return f"Now playing via Web API: '{track_name}' by {artist_name}"
    
    # Offline fallback: open the search screen only. Starting playback here used to
    # play whatever happened to be queued, not the requested search result.
    spotify_uri = f"spotify:search:{urllib.parse.quote(query)}"
    try:
        subprocess.run(["open", spotify_uri], check=True)
        return f"Opened Spotify search locally for: '{query}'"
    except Exception as e:
        return f"Failed to perform search: {str(e)}"

def tool_like_current_track(params: dict) -> str:
    """Likes currently playing track (Web API required)."""
    if refusal := require_explicit_intent(params):
        return refusal
    token = params.get("access_token") or os.environ.get("SPOTIFY_ACCESS_TOKEN")
    if not token or not check_internet():
        return "Offline Mode: Liking songs requires Spotify Web API connection & internet."
    
    ok, res = web_api_request("me/player/currently-playing", token=token)
    if ok and isinstance(res, dict) and "item" in res and res["item"]:
        track_id = res["item"]["id"]
        track_name = res["item"]["name"]
        put_ok, _ = web_api_request(f"me/tracks?ids={track_id}", method="PUT", token=token)
        if put_ok:
            return f"Added '{track_name}' to your Liked Songs! ❤️"
    
    return "Could not save track to Liked Songs. Ensure Spotify is actively playing."

def tool_play_track(params: dict) -> str:
    """Plays an already-resolved Spotify track URI."""
    if refusal := require_explicit_intent(params):
        return refusal
    uri = params.get("uri")
    if not isinstance(uri, str) or not re.fullmatch(r"spotify:track:[A-Za-z0-9]+", uri):
        return "Invalid Spotify track URI."
    ok, out = run_applescript(f'play track "{uri}"')
    if ok:
        return f"Spotify track playback started: {uri}"
    return f"Failed to play Spotify track: {out}"

# --- Tools Manifest for MCP ---

TOOLS = [
    {
        "name": "spotify_play_pause",
        "description": "Oynatmayı duraklatır veya devam ettirir (Play/Pause).",
        "inputSchema": {
            "type": "object",
            "properties": {
                EXPLICIT_INTENT_KEY: {"type": "boolean", "description": "Yalnızca doğrulanmış açık kullanıcı komutunda true"}
            },
            "required": [EXPLICIT_INTENT_KEY]
        }
    },
    {
        "name": "spotify_play",
        "description": "Oynatmayı başlatır veya devam ettirir.",
        "inputSchema": {
            "type": "object",
            "properties": {
                EXPLICIT_INTENT_KEY: {"type": "boolean", "description": "Yalnızca doğrulanmış açık kullanıcı komutunda true"}
            },
            "required": [EXPLICIT_INTENT_KEY]
        }
    },
    {
        "name": "spotify_pause",
        "description": "Oynatmayı duraklatır.",
        "inputSchema": {
            "type": "object",
            "properties": {
                EXPLICIT_INTENT_KEY: {"type": "boolean", "description": "Yalnızca doğrulanmış açık kullanıcı komutunda true"}
            },
            "required": [EXPLICIT_INTENT_KEY]
        }
    },
    {
        "name": "spotify_next_track",
        "description": "Sonraki şarkıya geçer (Next track).",
        "inputSchema": {
            "type": "object",
            "properties": {EXPLICIT_INTENT_KEY: {"type": "boolean"}},
            "required": [EXPLICIT_INTENT_KEY]
        }
    },
    {
        "name": "spotify_previous_track",
        "description": "Önceki şarkıya döner (Previous track).",
        "inputSchema": {
            "type": "object",
            "properties": {EXPLICIT_INTENT_KEY: {"type": "boolean"}},
            "required": [EXPLICIT_INTENT_KEY]
        }
    },
    {
        "name": "spotify_set_volume",
        "description": "Spotify ses seviyesini ayarlar (0 - 100).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "volume": {"type": "integer", "minimum": 0, "maximum": 100, "description": "Ses yüzdesi (0-100)"},
                EXPLICIT_INTENT_KEY: {"type": "boolean"}
            },
            "required": ["volume", EXPLICIT_INTENT_KEY]
        }
    },
    {
        "name": "spotify_get_current_track",
        "description": "Şu an çalan şarkı, sanatçı ve durum bilgisini döner.",
        "inputSchema": {
            "type": "object",
            "properties": {EXPLICIT_INTENT_KEY: {"type": "boolean"}},
            "required": [EXPLICIT_INTENT_KEY]
        }
    },
    {
        "name": "spotify_search_and_play",
        "description": "Şarkı veya sanatçı arar ve oynatmaya başlar.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "minLength": 1, "description": "Aranacak şarkı veya sanatçı adı"},
                EXPLICIT_INTENT_KEY: {"type": "boolean"}
            },
            "required": ["query", EXPLICIT_INTENT_KEY]
        }
    },
    {
        "name": "spotify_play_track",
        "description": "Önceden çözümlenmiş Spotify track URI'sini oynatır.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "uri": {"type": "string", "pattern": "^spotify:track:[A-Za-z0-9]+$"},
                EXPLICIT_INTENT_KEY: {"type": "boolean"}
            },
            "required": ["uri", EXPLICIT_INTENT_KEY]
        }
    },
    {
        "name": "spotify_like_current_track",
        "description": "Çalan şarkıyı Beğenilen Şarkılar kütüphanesine ekler (Online mod gerektirir).",
        "inputSchema": {
            "type": "object",
            "properties": {EXPLICIT_INTENT_KEY: {"type": "boolean"}},
            "required": [EXPLICIT_INTENT_KEY]
        }
    }
]

HANDLERS = {
    "spotify_play_pause": tool_play_pause,
    "spotify_play": tool_play,
    "spotify_pause": tool_pause,
    "spotify_next_track": tool_next_track,
    "spotify_previous_track": tool_previous_track,
    "spotify_set_volume": tool_set_volume,
    "spotify_get_current_track": tool_get_current_track,
    "spotify_search_and_play": tool_search_and_play,
    "spotify_play_track": tool_play_track,
    "spotify_like_current_track": tool_like_current_track,
}

ERROR_RESPONSE_PREFIXES = (
    "Refused:",
    "Error:",
    "Invalid ",
    "Failed ",
    "Could not ",
    "Offline Mode:",
    "Spotify is not currently running.",
)


def is_error_response(text: str) -> bool:
    """Map handler outcomes to MCP's typed `isError` result field."""
    return text.startswith(ERROR_RESPONSE_PREFIXES)

# --- JSON-RPC 2.0 stdio MCP Server Loop ---

def main():
    """Main MCP stdin/stdout event loop.

    Uses an explicit readline()/EOF loop instead of `for line in sys.stdin`
    so end-of-stream (parent process closed stdin, e.g. because it's
    shutting down) is unambiguous and the process exits cleanly rather than
    relying on iterator buffering semantics over a long-lived pipe.
    """
    while True:
        line = sys.stdin.readline()
        if line == "":
            # EOF: stdin closed (parent went away). Exit the loop/process.
            break
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue

        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params", {})

        if method == "initialize":
            res = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "spotify-smart-mcp", "version": "1.0.0"}
                }
            }
            sys.stdout.write(json.dumps(res) + "\n")
            sys.stdout.flush()

        elif method == "notifications/initialized":
            pass

        elif method == "tools/list":
            res = {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"tools": TOOLS}
            }
            sys.stdout.write(json.dumps(res) + "\n")
            sys.stdout.flush()

        elif method == "tools/call":
            tool_name = params.get("name")
            tool_args = params.get("arguments", {})
            
            handler = HANDLERS.get(tool_name)
            if handler:
                try:
                    content_str = handler(tool_args)
                    res = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "isError": is_error_response(content_str),
                            "content": [{"type": "text", "text": content_str}]
                        }
                    }
                except Exception as e:
                    res = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "isError": True,
                            "content": [{"type": "text", "text": f"Error executing tool {tool_name}: {str(e)}"}]
                        }
                    }
            else:
                res = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32601, "message": f"Tool not found: {tool_name}"}
                }
            sys.stdout.write(json.dumps(res) + "\n")
            sys.stdout.flush()

        elif method == "ping":
            res = {"jsonrpc": "2.0", "id": req_id, "result": {}}
            sys.stdout.write(json.dumps(res) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
