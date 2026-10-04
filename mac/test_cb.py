# mac/test_cb.py — run: cd mac && python3 -m unittest test_cb -v
# Uses a private tmux server (TMUX_TMPDIR) and a fake `claude` that records its arguments.
import os
import shutil
import subprocess
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
CB = os.path.join(HERE, "cb")
TMUX = shutil.which("tmux") or next(
    (p for p in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux") if os.path.exists(p)), None)

FAKE_CLAUDE = """#!/bin/bash
{ echo "$#"; for a in "$@"; do printf '%s\\n' "$a"; done; } > "$CB_TEST_OUT"
exec sleep 60
"""


@unittest.skipUnless(TMUX, "tmux is not installed")
class CbTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cbt")
        self.sock_dir = tempfile.mkdtemp(prefix="cbs", dir="/tmp")   # Unix socket paths are short
        bindir = os.path.join(self.tmp, "bin")
        os.makedirs(bindir)
        claude = os.path.join(bindir, "claude")
        with open(claude, "w") as f:
            f.write(FAKE_CLAUDE)
        os.chmod(claude, 0o755)
        self.out = os.path.join(self.tmp, "args")
        self.env = {"PATH": bindir + ":/usr/bin:/bin", "HOME": self.tmp, "TMUX_TMPDIR": self.sock_dir,
                    "CB_TMUX": TMUX, "CB_NO_ATTACH": "1", "CB_TEST_OUT": self.out, "TERM": "xterm-256color"}

    def tearDown(self):
        subprocess.run([TMUX, "kill-server"], env=self.env, capture_output=True)
        shutil.rmtree(self.tmp, ignore_errors=True)
        shutil.rmtree(self.sock_dir, ignore_errors=True)

    def project(self, name):
        d = os.path.join(self.tmp, name)
        os.makedirs(d)
        return d

    def cb(self, cwd, *args):
        r = subprocess.run([CB, *args], cwd=cwd, env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def tmux(self, *args):
        return subprocess.run([TMUX, *args], env=self.env, capture_output=True, text=True, timeout=10).stdout.strip()

    def claude_args(self):
        for _ in range(100):
            if os.path.exists(self.out):
                lines = open(self.out).read().splitlines()
                if lines and len(lines) == int(lines[0]) + 1:
                    return lines[1:]
            time.sleep(0.05)
        self.fail("claude was not started")

    def sessions(self):
        return self.tmux("list-sessions", "-F", "#{session_name}").splitlines()

    def test_starts_claude_in_a_marked_session_named_after_the_directory(self):
        pane = self.cb(self.project("esp32-translator"), "--resume", "a b")
        self.assertTrue(pane.startswith("%"), pane)
        self.assertEqual(self.claude_args(), ["--resume", "a b"])
        self.assertEqual(self.sessions(), ["esp32-translator"])
        self.assertEqual(self.tmux("show-options", "-p", "-v", "-t", pane, "@claude_board"), "1")

    def test_no_arguments_still_runs_claude(self):
        self.cb(self.project("plain"))
        self.assertEqual(self.claude_args(), [])

    def test_second_run_attaches_to_the_same_session(self):
        d = self.project("api")
        first = self.cb(d)
        self.claude_args()
        self.assertEqual(self.cb(d), first)
        self.assertEqual(self.sessions(), ["api"])

    def test_odd_directory_names_are_sanitised(self):
        self.cb(self.project("my.proj:x"))
        self.claude_args()
        self.assertEqual(self.sessions(), ["my_proj_x"])

    def test_inside_tmux_marks_this_pane_and_runs_claude_here(self):
        pane = self.tmux("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "host", "sleep 60")
        sock = self.tmux("display-message", "-p", "-t", pane, "#{socket_path}")
        env = dict(self.env, TMUX=sock + ",1,0", TMUX_PANE=pane)
        p = subprocess.Popen([CB, "-c"], cwd=self.project("inner"), env=env)
        try:
            self.assertEqual(self.claude_args(), ["-c"])
            self.assertEqual(self.tmux("show-options", "-p", "-v", "-t", pane, "@claude_board"), "1")
            self.assertEqual(self.sessions(), ["host"])            # no new session
        finally:
            p.kill()
            p.wait()

    def test_missing_claude_is_an_error(self):
        env = dict(self.env, PATH="/usr/bin:/bin")
        r = subprocess.run([CB], cwd=self.project("x"), env=env, capture_output=True, text=True, timeout=20)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("claude not found", r.stderr)


if __name__ == "__main__":
    unittest.main()
