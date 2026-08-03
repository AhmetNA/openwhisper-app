import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


SCRIPT_PATH = Path(__file__).resolve().parents[2] / "scripts" / "spotify_smart_mcp.py"
SPEC = importlib.util.spec_from_file_location("spotify_smart_mcp", SCRIPT_PATH)
spotify_mcp = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(spotify_mcp)


class SpotifyMCPExplicitIntentTests(unittest.TestCase):
    def test_unvalidated_mutating_tools_have_zero_side_effects(self):
        calls = [
            (spotify_mcp.tool_play_pause, {}),
            (spotify_mcp.tool_play, {"explicit_intent": "true"}),
            (spotify_mcp.tool_pause, {"explicit_intent": 1}),
            (spotify_mcp.tool_next_track, {"explicit_intent": False}),
            (spotify_mcp.tool_previous_track, {}),
            (spotify_mcp.tool_set_volume, {"volume": 50}),
            (spotify_mcp.tool_search_and_play, {"query": "Tarkan"}),
            (spotify_mcp.tool_play_track, {"uri": "spotify:track:abc"}),
            (spotify_mcp.tool_like_current_track, {}),
        ]

        with patch.object(spotify_mcp, "run_applescript") as applescript, \
             patch.object(spotify_mcp.subprocess, "run") as process, \
             patch.object(spotify_mcp, "web_api_request") as web_api, \
             patch.object(spotify_mcp, "check_internet") as internet:
            for handler, params in calls:
                with self.subTest(handler=handler.__name__, params=params):
                    self.assertEqual(handler(params), spotify_mcp.EXPLICIT_INTENT_ERROR)

            applescript.assert_not_called()
            process.assert_not_called()
            web_api.assert_not_called()
            internet.assert_not_called()

    def test_read_tool_does_not_probe_or_launch_without_explicit_intent(self):
        with patch.object(spotify_mcp, "is_spotify_running") as is_running, \
             patch.object(spotify_mcp, "run_applescript") as applescript:
            self.assertEqual(
                spotify_mcp.tool_get_current_track({}),
                spotify_mcp.EXPLICIT_INTENT_ERROR,
            )
            is_running.assert_not_called()
            applescript.assert_not_called()

    def test_explicit_play_and_pause_are_deterministic_not_toggle(self):
        with patch.object(spotify_mcp, "run_applescript", return_value=(True, "")) as run:
            self.assertIn("started", spotify_mcp.tool_play({"explicit_intent": True}))
            self.assertIn("paused", spotify_mcp.tool_pause({"explicit_intent": True}))
            self.assertEqual(run.call_args_list[0].args, ("play",))
            self.assertEqual(run.call_args_list[1].args, ("pause",))

    def test_malformed_search_and_volume_never_execute(self):
        invalid_calls = [
            (spotify_mcp.tool_search_and_play, {"explicit_intent": True, "query": None}),
            (spotify_mcp.tool_search_and_play, {"explicit_intent": True, "query": "   "}),
            (spotify_mcp.tool_set_volume, {"explicit_intent": True}),
            (spotify_mcp.tool_set_volume, {"explicit_intent": True, "volume": True}),
            (spotify_mcp.tool_set_volume, {"explicit_intent": True, "volume": 101}),
        ]
        with patch.object(spotify_mcp, "run_applescript") as applescript, \
             patch.object(spotify_mcp.subprocess, "run") as process:
            for handler, params in invalid_calls:
                with self.subTest(handler=handler.__name__, params=params):
                    self.assertTrue(spotify_mcp.is_error_response(handler(params)))
            applescript.assert_not_called()
            process.assert_not_called()

    def test_search_screen_fallback_never_starts_unrelated_queued_music(self):
        completed = subprocess.CompletedProcess(args=[], returncode=0)
        with patch.object(spotify_mcp, "check_internet", return_value=False), \
             patch.object(spotify_mcp.subprocess, "run", return_value=completed) as process, \
             patch.object(spotify_mcp, "run_applescript") as applescript:
            result = spotify_mcp.tool_search_and_play(
                {"explicit_intent": True, "query": "Tarkan"}
            )

            self.assertIn("Opened Spotify search", result)
            process.assert_called_once()
            self.assertEqual(process.call_args.args[0][0], "open")
            applescript.assert_not_called()

    def test_track_uri_rejects_applescript_injection(self):
        malicious = 'spotify:track:abc" & quit & "'
        with patch.object(spotify_mcp, "run_applescript") as applescript:
            result = spotify_mcp.tool_play_track(
                {"explicit_intent": True, "uri": malicious}
            )
            self.assertEqual(result, "Invalid Spotify track URI.")
            applescript.assert_not_called()

    def test_manifest_requires_explicit_intent_for_every_tool(self):
        for tool in spotify_mcp.TOOLS:
            with self.subTest(tool=tool["name"]):
                required = tool["inputSchema"].get("required", [])
                self.assertIn(spotify_mcp.EXPLICIT_INTENT_KEY, required)

    def test_json_rpc_refusal_is_a_typed_mcp_error(self):
        request = {
            "jsonrpc": "2.0",
            "id": 42,
            "method": "tools/call",
            "params": {"name": "spotify_play", "arguments": {}},
        }
        stdin = io.StringIO(json.dumps(request) + "\n")
        stdout = io.StringIO()

        with patch.object(spotify_mcp.sys, "stdin", stdin), \
             patch.object(spotify_mcp.sys, "stdout", stdout), \
             patch.object(spotify_mcp, "run_applescript") as applescript:
            spotify_mcp.main()

        response = json.loads(stdout.getvalue())
        self.assertTrue(response["result"]["isError"])
        self.assertEqual(
            response["result"]["content"][0]["text"],
            spotify_mcp.EXPLICIT_INTENT_ERROR,
        )
        applescript.assert_not_called()


if __name__ == "__main__":
    unittest.main()
