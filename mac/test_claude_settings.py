# mac/test_claude_settings.py — run: cd mac && python3 -m unittest test_claude_settings -v
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import claude_settings  # noqa: E402

HOOK = "/x/bin/claude-board-hook"


def run(*args):
    subprocess.run([sys.executable, os.path.join(HERE, "claude_settings.py"), *args], check=True, capture_output=True)


def ours(settings, event):
    return [h for e in settings.get("hooks", {}).get(event, []) for h in e.get("hooks", [])
            if h.get("command", "").strip().strip("\"'").endswith("claude-board-hook")]


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "settings.json")
        with open(self.path, "w") as f:
            json.dump({"model": "x", "hooks": {
                "Stop": [{"hooks": [{"type": "command", "command": "other-tool"}]}],
                "Notification": [{"matcher": "idle_prompt", "hooks": [{"type": "command", "command": '"%s"' % HOOK, "async": True}]}],
            }}, f)

    def load(self):
        with open(self.path) as f:
            return json.load(f)

    def test_session_hooks_follow_the_spike(self):
        events = {e for e, _, _ in claude_settings.HOOKS}
        self.assertTrue({"PermissionRequest", "Stop", "Notification", "UserPromptSubmit"} <= events)
        self.assertEqual("SessionStart" in events, claude_settings.SESSION_HOOKS)
        self.assertEqual("SessionEnd" in events, claude_settings.SESSION_HOOKS)

    def test_install_adds_every_hook_once_and_only_permission_is_sync(self):
        run("install", self.path, HOOK)
        run("install", self.path, HOOK)            # idempotent
        s = self.load()
        for event, _, _ in claude_settings.HOOKS:
            hooks = ours(s, event)
            self.assertEqual(len(hooks), 1, event)
            if event == "PermissionRequest":
                self.assertEqual(hooks[0].get("timeout"), 100)
                self.assertNotIn("async", hooks[0])
            else:
                self.assertIs(hooks[0].get("async"), True, event)
        self.assertEqual(s["model"], "x")
        self.assertIn({"type": "command", "command": "other-tool"}, [h for e in s["hooks"]["Stop"] for h in e["hooks"]])

    def test_notification_hook_takes_every_type(self):
        run("install", self.path, HOOK)
        entries = [e for e in self.load()["hooks"]["Notification"] if ours({"hooks": {"N": [e]}}, "N")]
        self.assertEqual(len(entries), 1)
        self.assertNotIn("matcher", entries[0])     # the old idle_prompt-only entry is replaced

    def test_uninstall_removes_only_ours(self):
        run("install", self.path, HOOK)
        run("uninstall", self.path)
        s = self.load()
        for event, _, _ in claude_settings.HOOKS:
            self.assertEqual(ours(s, event), [], event)
        self.assertEqual(s["hooks"]["Stop"], [{"hooks": [{"type": "command", "command": "other-tool"}]}])


if __name__ == "__main__":
    unittest.main()
