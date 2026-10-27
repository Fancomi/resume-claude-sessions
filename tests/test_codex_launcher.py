"""Codex provider tests for the shared launcher.

Covers the two pieces that are Codex-specific now that Claude and Codex share
resume-sessions.sh:

1. ``codex_sessions.py`` discovery (rollout parsing, subagent filtering,
   newest-file wins per session id, unusable sessions skipped).
2. End-to-end print/dry-run behaviour of the Codex entry point, using a fake
   CODEX_HOME and a fake `codex` CLI so nothing real is scanned or launched.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / "resume-sessions.sh"
CODEX_ENTRY = ROOT / "resume-codex-sessions.sh"
CLAUDE_ENTRY = ROOT / "resume-claude-sessions.sh"
HELPER = ROOT / "codex_sessions.py"

sys.path.insert(0, str(ROOT))
import codex_sessions  # noqa: E402


def session_id(digit):
    return digit * 8 + "-" + "-".join([digit * 4] * 3) + "-" + digit * 12


def rollout_paths(home, identifier, day="27"):
    return (
        Path(home)
        / "sessions"
        / "2026"
        / "10"
        / day
        / f"rollout-2026-10-{day}T10-00-00-{identifier}.jsonl"
    )


def write_rollout(home, identifier, cwd, source=None, age_seconds=0, day="27"):
    path = rollout_paths(home, identifier, day)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"id": identifier, "cwd": str(cwd)}
    if source is not None:
        payload["source"] = source
    path.write_text(json.dumps({"type": "session_meta", "payload": payload}) + "\n")
    stamp = time.time() - age_seconds
    os.utime(path, (stamp, stamp))
    return path


class CodexDiscoveryTests(unittest.TestCase):
    """codex_sessions.py must be conservative about what it offers to resume."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name) / "codex"
        (self.home / "sessions").mkdir(parents=True)
        self.work = Path(tmp.name) / "work"
        self.work.mkdir()

    def test_reads_session_id_and_cwd_from_session_meta(self):
        write_rollout(self.home, session_id("2"), self.work)
        sessions = codex_sessions.discover_sessions(self.home / "sessions")
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["id"], session_id("2"))
        self.assertEqual(sessions[0]["cwd"], str(self.work))
        self.assertEqual(sessions[0]["name"], "work")

    def test_subagent_sessions_skipped_by_default_and_included_on_request(self):
        write_rollout(self.home, session_id("3"), self.work, source="subagent")
        self.assertEqual(codex_sessions.discover_sessions(self.home / "sessions"), [])
        included = codex_sessions.discover_sessions(self.home / "sessions", include_subagents=True)
        self.assertEqual([s["id"] for s in included], [session_id("3")])

    def test_session_whose_cwd_no_longer_exists_is_skipped(self):
        write_rollout(self.home, session_id("4"), Path("/definitely/not/there"))
        self.assertEqual(codex_sessions.discover_sessions(self.home / "sessions"), [])

    def test_newest_rollout_wins_for_the_same_session_id(self):
        identifier = session_id("5")
        old = write_rollout(self.home, identifier, self.work, age_seconds=3600, day="26")
        new = write_rollout(self.home, identifier, self.work, age_seconds=0, day="27")
        sessions = codex_sessions.discover_sessions(self.home / "sessions")
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["last_seen"], new.stat().st_mtime)
        self.assertGreater(new.stat().st_mtime, old.stat().st_mtime)

    def test_malformed_metadata_does_not_hide_other_sessions(self):
        good = write_rollout(self.home, session_id("6"), self.work)
        broken = rollout_paths(self.home, session_id("7"))
        broken.parent.mkdir(parents=True, exist_ok=True)
        broken.write_text("{not json\n")
        sessions = codex_sessions.discover_sessions(self.home / "sessions")
        self.assertEqual([s["id"] for s in sessions], [session_id("6")])
        self.assertTrue(good.exists())


class CodexLauncherPrintTests(unittest.TestCase):
    """Run the real Codex entry point against a fake CODEX_HOME and CLI."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

        for name in (
            "resume-sessions.sh",
            "resume-claude-sessions.sh",
            "resume-codex-sessions.sh",
            "codex_sessions.py",
        ):
            target = self.root / name
            shutil.copy2(ROOT / name, target)
            target.chmod(0o755)

        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.codex = self.bin / "codex"
        self.codex.write_text("#!/usr/bin/env bash\necho fake-codex \"$@\"\n")
        self.codex.chmod(0o755)

        self.home = self.root / "codex"
        (self.home / "sessions").mkdir(parents=True)
        self.work = self.root / "work"
        self.work.mkdir()

    def _run(self, entry=CODEX_ENTRY, extra_env=None, stdin=None):
        env = dict(os.environ)
        python_dir = os.path.dirname(os.path.realpath(sys.executable))
        env["PATH"] = os.pathsep.join(
            dict.fromkeys([str(self.bin), python_dir, "/usr/bin", "/bin", "/usr/local/bin"])
        )
        env.update(
            {
                "HOME": str(self.root),
                "RESUME_CODEX_HOME": str(self.home),
                "RESUME_PYBIN": sys.executable,
                "RESUME_AUTO_SELECT": "1",
                "RESUME_FORCE_LAUNCH": "print",
                "TMPDIR": str(self.root),
            }
        )
        env.pop("CODEX_HOME", None)
        env.pop("RESUME_SKIP_PERMISSIONS", None)
        if extra_env:
            env.update({k: v for k, v in extra_env.items() if v is not None})
            for key, value in extra_env.items():
                if value is None:
                    env.pop(key, None)
        return subprocess.run(
            ["bash", str(self.root / entry)],
            cwd=self.root,
            env=env,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def _write_session(self, identifier, age_seconds=0):
        return write_rollout(self.home, identifier, self.work, age_seconds=age_seconds)

    def test_print_emits_a_codex_resume_command(self):
        session_file = self._write_session(session_id("8"))
        result = self._run()
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        identifier = session_id("8")
        stamp = time.strftime("%m-%d %H:%M", time.localtime(session_file.stat().st_mtime))
        lines = result.stdout.splitlines()
        self.assertEqual(lines[0], "# G1  resume: work [88888888] [%s]" % stamp)
        self.assertTrue(lines[1].startswith("cd '%s' && env CODEX_HOME=" % self.work))
        codex_home = lines[1].split("env CODEX_HOME=", 1)[1].split(" ", 1)[0]
        self.assertTrue(os.path.samefile(codex_home, self.home))
        self.assertIn(" %s --dangerously-bypass-approvals-and-sandbox " % self.codex, lines[1])
        self.assertIn(" resume %s --cd %s" % (identifier, self.work), lines[1])
        self.assertEqual(len(lines), 2)

    def test_skip_permissions_zero_drops_the_bypass_flags(self):
        self._write_session(session_id("9"))
        result = self._run(extra_env={"RESUME_SKIP_PERMISSIONS": "0"})
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertNotIn("--dangerously-bypass-approvals-and-sandbox", result.stdout)
        self.assertNotIn("--sandbox", result.stdout)
        self.assertIn(" resume %s --cd %s" % (session_id("9"), self.work), result.stdout)

    def test_default_launch_mode_is_auto_not_print(self):
        # Codex keeps upstream's auto-launch default; RESUME_DRY_RUN proves the
        # detection ran without opening anything.
        self._write_session(session_id("a"))
        result = self._run(extra_env={"RESUME_FORCE_LAUNCH": None, "RESUME_DRY_RUN": "1"})
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("provider=codex launch=", result.stdout)
        self.assertNotIn("launch=print", result.stdout)

    def test_claude_entry_point_still_defaults_to_print(self):
        # The same engine with the Claude wrapper keeps print as its default.
        project = self.root / "projects" / "p"
        project.mkdir(parents=True)
        (project / (session_id("b") + ".jsonl")).write_text('{"cwd": "%s"}\n' % self.work)
        result = self._run(
            entry=CLAUDE_ENTRY,
            extra_env={
                "RESUME_PROJECTS_ROOT": str(self.root / "projects"),
                "RESUME_FORCE_LAUNCH": None,
                "RESUME_CODEX_HOME": None,
            },
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("--resume %s" % session_id("b"), result.stdout)

    def test_group_zero_becomes_an_independent_window(self):
        self._write_session(session_id("c"), age_seconds=0)
        self._write_session(session_id("d"), age_seconds=86400)
        # Plain picker: tick session 2, move it to group 0, confirm.
        result = self._run(
            extra_env={"RESUME_AUTO_SELECT": None, "RESUME_FORCE_SELECT": "tui"},
            stdin="2\ng2:0\n\n",
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("# Gsingle-1  resume:", result.stdout)

    def test_subagents_are_excluded_unless_requested(self):
        write_rollout(self.home, session_id("e"), self.work, source="subagent")
        result = self._run(extra_env={"RESUME_AUTO_SELECT": None, "RESUME_FORCE_SELECT": "tui"})
        # No resumable sessions -> the launcher exits 0 with a message, never a
        # half-built command block.
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertNotIn("resume:", result.stdout)


if __name__ == "__main__":
    unittest.main()
