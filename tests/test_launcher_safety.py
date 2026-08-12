"""Safety tests for resume-claude-sessions.sh's VSCode launch path.

Two layers:

1. Source-safety assertions (no subprocess): grep the shell script text to
   make sure the bridge-first / fixed-new-window-fallback contract is wired
   up the way the brief requires, and that no reuse/reload path exists.
2. Subprocess behaviour tests: copy the real script into a temp directory
   alongside a FAKE bridge client (a tiny Python script we write ourselves)
   and a FAKE Comate CLI (a recording shell script), then run the launcher
   with RESUME_AUTO_SELECT=1 and assert what each bridge exit code causes it
   to do. The real `comate`/`code` CLI and the real bridge client are never
   invoked; VSCODE_IPC_HOOK_CLI is only ever pointed at a harmless temp path.
"""

import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_PATH = ROOT / "resume-claude-sessions.sh"


class LauncherSafetyTests(unittest.TestCase):
    """Source-level checks: no reuse/reload path, bridge attempted first."""

    def setUp(self):
        self.source = SOURCE_PATH.read_text()

    def test_never_reuses_or_reloads_current_window(self):
        for forbidden in ["RESUME_VSCODE_REUSE", "--reuse-window", '"$cli" -r', "reloadWindow"]:
            self.assertNotIn(forbidden, self.source)

    def test_new_window_is_the_only_comate_fallback(self):
        self.assertIn('"$cli" -n "$wsfile"', self.source)

    def test_bridge_client_is_attempted_before_new_window(self):
        self.assertLess(
            self.source.index("launch_vscode_bridge"),
            self.source.index("launch_vscode_new_window"),
        )

    def test_dispatcher_handles_all_four_documented_exit_codes(self):
        # status 0: success, no fallback. status 2: bridge unavailable before
        # any bytes were sent -> safe to fall back to a fixed new window.
        # status 3/4: request may have been delivered / bridge reported
        # terminal-creation errors -> must NOT fall back (would duplicate
        # terminals), so launch_vscode_new_window must not appear in those
        # branches.
        self.assertIn("launch_vscode_bridge", self.source)
        idx = self.source.index("launch_vscode() {")
        body_end = self.source.index("\n}\n", idx)
        body = self.source[idx:body_end]
        self.assertIn("launch_vscode_bridge", body)
        self.assertIn("launch_vscode_new_window", body)
        # Exactly one call site for launch_vscode_new_window inside the
        # dispatcher body: the status==2 arm. (The function definition and
        # its explanatory comment live outside `body`, so this only counts
        # actual call sites within the dispatcher.)
        self.assertEqual(body.count("launch_vscode_new_window"), 1)
        for code in ("0)", "2)", "3|4)"):
            self.assertIn(code, body)

    def test_bridge_path_uses_confirmed_pairing_not_ipc_hook(self):
        # Normal routing must use the confirmed pairing (probe-paired /
        # send-input0 --paired-workspace), never VSCODE_IPC_HOOK_CLI or
        # --ipc-hook: an isolated live test proved the IPC hook differs
        # between terminals in the same window, so it cannot identify "this
        # window" for routing.
        idx = self.source.index("launch_vscode_bridge() {")
        body_end = self.source.index("\n}\n", idx)
        body = self.source[idx:body_end]
        self.assertIn("probe-paired", body)
        self.assertIn("--paired-workspace", body)
        self.assertNotIn("VSCODE_IPC_HOOK_CLI", body)
        self.assertNotIn("--ipc-hook", body)


class PairScriptSafetyTests(unittest.TestCase):
    """Source-level checks for scripts/pair-comate-bridge.sh.

    No subprocess execution: this script's only side effect (writing the
    pair file) is exercised by the Python pairing tests via
    ``create_pairing`` directly. Here we only confirm the shell wrapper
    itself has no Comate invocation, no reuse/reload, and gates on the exact
    confirmation flag.
    """

    def setUp(self):
        self.source = (SOURCE_PATH.parent / "scripts/pair-comate-bridge.sh").read_text()

    def test_requires_confirmed_current_window_flag(self):
        self.assertIn("--confirmed-current-window", self.source)

    def test_never_invokes_comate_or_reuses_reloads(self):
        for forbidden in ["comate -r", "comate -n", '"$cli" -n', "--reuse-window", "reloadWindow", "createTerminal"]:
            self.assertNotIn(forbidden, self.source)

    def test_only_calls_the_pair_subcommand(self):
        self.assertIn("comate_bridge_client.py\" pair", self.source)
        self.assertNotIn("send-input0", self.source)
        self.assertNotIn("probe-paired", self.source)


class IntegrationTestScriptSafetyTests(unittest.TestCase):
    """Source-level checks for scripts/test-comate-bridge-window.sh.

    No subprocess execution here: this only inspects the script's text to
    confirm it opens exactly one new window with `comate -n`, records and
    excludes the pre-existing socket identity before probing for a new one,
    and never reuses/reloads/closes any window.
    """

    def setUp(self):
        self.source = (SOURCE_PATH.parent / "scripts/test-comate-bridge-window.sh").read_text()

    def test_integration_test_opens_new_window_and_excludes_original_identity(self):
        source = self.source
        self.assertIn('"$COMATE_CLI" -n "$TEST_DIR"', source)
        self.assertIn("ORIGINAL_IDENTITY=", source)
        self.assertIn('if [ "$candidate" = "$ORIGINAL_SOCKET" ]; then continue; fi', source)
        for forbidden in [" --reuse-window ", " -r ", "reloadWindow"]:
            self.assertNotIn(forbidden, source)

    def test_requires_explicit_guard_flag(self):
        self.assertIn("--i-understand-this-opens-a-new-test-window", self.source)

    def test_never_closes_a_window(self):
        for forbidden in [".dispose(", "workbench.action.closeWindow", "workbench.action.closeFolder", "kill "]:
            self.assertNotIn(forbidden, self.source)

    def test_socket_override_requires_test_mode_and_private_runtime_dir(self):
        self.assertIn("--test-mode", self.source)
        self.assertIn('--socket "$TEST_SOCKET"', self.source)

    def test_both_terminal_scripts_present(self):
        # First terminal writes VSCODE_IPC_HOOK_CLI to terminal-ipc.txt, then
        # execs bash. Second terminal prints the fixed marker line, then
        # execs bash. Both must use the test-only "test" kind (gated by
        # --test-mode on the client side), not the plain "cli" kind, so that
        # each can run its own script before dropping into an interactive
        # shell.
        self.assertIn('$VSCODE_IPC_HOOK_CLI', self.source)
        self.assertIn("terminal-ipc.txt", self.source)
        self.assertIn("exec bash", self.source)
        self.assertIn("bridge second terminal ready", self.source)
        self.assertIn('test "bridge-test-identity"', self.source)
        self.assertIn('test "bridge-test-second"', self.source)

    def test_automatic_ipc_hash_comparison_and_mismatch_failure(self):
        # The script must compute the sha256-based identity of the terminal-
        # reported IPC itself (not just print instructions for a human to run
        # it) and compare it against TEST_IDENTITY, exiting non-zero on a
        # mismatch or timeout while still leaving the window open.
        self.assertIn("hashlib.sha256", self.source)
        self.assertIn('REPORTED_IDENTITY" = "$TEST_IDENTITY"', self.source)
        self.assertIn("VERIFY_STATUS", self.source)
        self.assertIn('if [ "$VERIFY_STATUS" -ne 0 ]; then\n  exit 1\nfi', self.source)

    def test_ipc_marker_file_poll_is_bounded(self):
        # The wait for terminal-ipc.txt must be a bounded poll loop, not an
        # unconditional blocking read.
        self.assertIn("IPC_POLL_SECONDS", self.source)
        self.assertIn("ipc_elapsed", self.source)


FAKE_BRIDGE_CLIENT_TEMPLATE = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    # FAKE bridge client for tests only. Never touches a real socket, never
    # imports the real bridge/comate_bridge_client.py.
    import sys

    PROBE_EXIT = {probe_exit}
    SEND_EXIT = {send_exit}
    RECORD_FILE = {record_file!r}

    def main(argv):
        if not argv:
            return 4
        cmd = argv[0]
        if cmd == "probe-paired":
            return PROBE_EXIT
        if cmd == "send-input0":
            data = sys.stdin.buffer.read()
            with open(RECORD_FILE, "wb") as fh:
                fh.write(data)
            return SEND_EXIT
        return 4

    if __name__ == "__main__":
        sys.exit(main(sys.argv[1:]))
    """
)

FAKE_COMATE_TEMPLATE = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    # FAKE Comate CLI for tests only. Records its argv and exits 0 without
    # opening any real window.
    printf '%s\\n' "$*" >> {record_file}
    exit 0
    """
)


class LauncherSandboxMixin:
    """Builds a throwaway copy of the launcher with every external edge faked.

    Shared by the bridge tests and the print-mode tests. Nothing here touches
    the real Comate/code CLI, the real bridge client, the real `claude`, the
    real ~/.claude/projects, or a real VSCODE_IPC_HOOK_CLI socket.

    ``sessions`` is a list of (dir_name, age_days) pairs. Each becomes one
    .jsonl session file whose mtime is backdated by that many days, which is
    what the launcher groups by: distinct ages mean distinct date groups, and
    only the newest date is checked by RESUME_AUTO_SELECT=1.
    """

    DEFAULT_SESSIONS = (("work", 0),)

    def _make_sandbox(self, probe_exit=0, send_exit=0, sessions=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)

        # Copy only the files needed to run the launcher in isolation.
        (root / "bridge").mkdir()
        script_text = SOURCE_PATH.read_text()
        (root / "resume-claude-sessions.sh").write_text(script_text)
        (root / "resume-claude-sessions.sh").chmod(0o755)

        bridge_record = root / "bridge_input0.bin"
        fake_client = root / "bridge" / "comate_bridge_client.py"
        fake_client.write_text(
            FAKE_BRIDGE_CLIENT_TEMPLATE.format(
                probe_exit=probe_exit, send_exit=send_exit, record_file=str(bridge_record)
            )
        )
        fake_client.chmod(0o755)

        # Fake Comate CLI on PATH, ahead of anything real.
        bin_dir = root / "bin"
        bin_dir.mkdir()
        comate_record = root / "comate_calls.txt"
        fake_comate = bin_dir / "comate"
        fake_comate.write_text(FAKE_COMATE_TEMPLATE.format(record_file=str(comate_record)))
        fake_comate.chmod(0o755)

        # A fake claude CLI so CLAUDE_CMD resolution doesn't depend on the host.
        fake_claude = bin_dir / "claude"
        fake_claude.write_text("#!/usr/bin/env bash\necho fake-claude \"$@\"\n")
        fake_claude.chmod(0o755)

        # Fake project dirs with minimal sessions so the launcher has >=1
        # session to select via RESUME_AUTO_SELECT=1, without touching the
        # real ~/.claude/projects.
        projects_root = root / "projects"
        proj_dir = projects_root / "proj"
        proj_dir.mkdir(parents=True)
        self.session_info = []
        for n, (dir_name, age_days) in enumerate(sessions or self.DEFAULT_SESSIONS, start=1):
            work_cwd = root / dir_name
            work_cwd.mkdir()
            session_id = str(n) * 8 + "-" + "-".join([str(n) * 4] * 3) + "-" + str(n) * 12
            session_file = proj_dir / (session_id + ".jsonl")
            session_file.write_text('{"cwd": "%s"}\n' % str(work_cwd))
            mtime = time.time() - age_days * 86400
            os.utime(session_file, (mtime, mtime))
            self.session_info.append(
                {
                    "id": session_id,
                    "cwd": str(work_cwd),
                    "name": dir_name,
                    "time": time.strftime("%m-%d %H:%M", time.localtime(mtime)),
                }
            )

        return root, bridge_record, comate_record, bin_dir

    def _run(self, root, bin_dir, extra_env=None, stdin=None):
        env = dict(os.environ)
        # Build a minimal PATH: the fake bin dir first (so the fake `comate`
        # is found ahead of anything real), plus only the directories the
        # script actually needs -- the real python3's own directory (so
        # CLAUDE_CMD/shebang resolution keeps working) and the standard
        # coreutils locations for basename/dirname/sed/grep/find/sort/cat/
        # date/printf. This makes isolation independent of PATH search
        # order rather than relying on a real comate/code binary simply not
        # being present somewhere on the ambient PATH.
        python3_dir = os.path.dirname(os.path.realpath(sys.executable))
        minimal_path = os.pathsep.join(
            dict.fromkeys([str(bin_dir), python3_dir, "/usr/bin", "/bin", "/usr/local/bin"])
        )
        env["PATH"] = minimal_path
        env["RESUME_AUTO_SELECT"] = "1"
        env["RESUME_FORCE_LAUNCH"] = "vscode"
        env["RESUME_PROJECTS_ROOT"] = str(root / "projects")
        env["VSCODE_IPC_HOOK_CLI"] = "/tmp/fake-vscode-ipc-does-not-exist.sock"
        # Deliberately unset any host VSCode-remote-cli hints so vscode_cli()
        # falls through to the fake `comate` on PATH, never a real installed
        # remote-cli binary.
        env.pop("VSCODE_GIT_ASKPASS_NODE", None)
        if extra_env:
            env.update({k: v for k, v in extra_env.items() if v is not None})
            for k, v in extra_env.items():
                if v is None:
                    env.pop(k, None)
        result = subprocess.run(
            ["bash", str(root / "resume-claude-sessions.sh")],
            cwd=root,
            env=env,
            input=stdin,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return result


class LauncherBridgeSubprocessTests(LauncherSandboxMixin, unittest.TestCase):
    """Runs the real shell script against fake bridge client + fake Comate CLI.

    Never invokes the real Comate/code CLI, never connects to a real
    VSCODE_IPC_HOOK_CLI socket, never opens/reloads/reuses a window.
    """

    def test_bridge_success_never_invokes_comate_cli(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox(probe_exit=0, send_exit=0)
        result = self._run(root, bin_dir)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertTrue(bridge_record.exists(), "bridge client should have received an input0 payload")
        self.assertFalse(comate_record.exists(), "fake Comate CLI must never be invoked on bridge success")

    def test_probe_unavailable_falls_back_to_fixed_new_window(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox(probe_exit=2, send_exit=0)
        result = self._run(root, bin_dir)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertFalse(bridge_record.exists(), "send-input0 must not run when probe reports unavailable")
        self.assertTrue(comate_record.exists(), "fallback must invoke the fake Comate CLI exactly once")
        calls = comate_record.read_text().strip().splitlines()
        self.assertEqual(len(calls), 1)
        self.assertRegex(calls[0], r"^-n .*resume-sessions\.code-workspace$")
        self.assertNotIn("-r", calls[0].split())

    def test_send_delivery_uncertain_never_falls_back(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox(probe_exit=0, send_exit=3)
        result = self._run(root, bin_dir)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(bridge_record.exists())
        self.assertFalse(
            comate_record.exists(), "status 3 (delivery uncertain) must never trigger the new-window fallback"
        )

    def test_send_terminal_errors_never_falls_back(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox(probe_exit=0, send_exit=4)
        result = self._run(root, bin_dir)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(bridge_record.exists())
        self.assertFalse(
            comate_record.exists(), "status 4 (terminal creation errors) must never trigger the new-window fallback"
        )

    def test_bridge_record_includes_selected_cwd_and_default_safe_permissions(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox(probe_exit=0, send_exit=0)
        result = self._run(root, bin_dir)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        data = bridge_record.read_bytes()
        fields = data[:-1].decode("utf-8").split("\0") if data.endswith(b"\0") else data.decode("utf-8").split("\0")
        self.assertIn(str(root / "work"), fields)
        # dangerous flag defaults to "0" unless RESUME_SKIP_PERMISSIONS=1.
        self.assertIn("0", fields)
        self.assertNotIn("1", fields)

    def test_skip_permissions_env_sets_dangerous_flag_in_bridge_record(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox(probe_exit=0, send_exit=0)
        result = self._run(root, bin_dir, extra_env={"RESUME_SKIP_PERMISSIONS": "1"})
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        data = bridge_record.read_bytes()
        fields = data[:-1].decode("utf-8").split("\0")
        self.assertIn("1", fields)

    def test_fallback_workspace_is_valid_json_for_a_quoted_cwd(self):
        # The new-window fallback shares shquote() with print mode. A cwd
        # containing a single quote must still produce a parseable workspace
        # file whose task command re-quotes the path correctly.
        root, bridge_record, comate_record, bin_dir = self._make_sandbox(
            probe_exit=2, send_exit=0, sessions=(("it's work", 0),)
        )
        result = self._run(root, bin_dir)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        doc = json.loads((root / "resume-sessions.code-workspace").read_text())
        cmd = doc["tasks"]["tasks"][0]["command"]
        self.assertIn("'%s'" % self.session_info[0]["cwd"].replace("'", "'\\''"), cmd)


class PrintModeSourceTests(unittest.TestCase):
    """Source-level checks: print mode launches nothing at all."""

    def setUp(self):
        self.source = SOURCE_PATH.read_text()

    def test_dispatcher_has_a_print_arm(self):
        idx = self.source.index('case "$LAUNCH_MODE" in')
        body = self.source[idx:]
        self.assertIn("print)", body)
        self.assertIn("launch_print", body)

    def test_print_mode_is_never_auto_detected(self):
        # detect_launch() must not be able to return "print" on its own; the
        # only way in is an explicit RESUME_FORCE_LAUNCH=print.
        idx = self.source.index("detect_launch() {")
        body = self.source[idx : self.source.index("\n}\n", idx)]
        self.assertNotIn("print", body)

    def test_launch_print_invokes_no_launcher(self):
        idx = self.source.index("launch_print() {")
        body = self.source[idx : self.source.index("\n}\n", idx)]
        for forbidden in [
            "launch_vscode_bridge",
            "launch_vscode_new_window",
            "tmux",
            "osascript",
            "gnome-terminal",
            "konsole",
            "code-workspace",
        ]:
            self.assertNotIn(forbidden, body)


class LauncherPrintModeTests(LauncherSandboxMixin, unittest.TestCase):
    """print mode must emit paste-ready commands and launch absolutely nothing."""

    PRINT_ENV = {"RESUME_FORCE_LAUNCH": "print"}

    def _claude(self, bin_dir):
        return str(bin_dir / "claude")

    def test_stdout_is_exactly_the_command_block(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox()
        result = self._run(root, bin_dir, extra_env=self.PRINT_ENV)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        s = self.session_info[0]
        expected = (
            "# G0  resume: %s [%s]\n" % (s["name"], s["time"])
            + "cd '%s' && %s --resume %s\n" % (s["cwd"], self._claude(bin_dir), s["id"])
        )
        self.assertEqual(result.stdout, expected)

    def test_stdout_has_no_ansi_escapes_or_trailing_whitespace(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox()
        result = self._run(root, bin_dir, extra_env=self.PRINT_ENV)
        self.assertNotIn("\x1b", result.stdout)
        for line in result.stdout.splitlines():
            self.assertEqual(line, line.rstrip(), "printed line has trailing whitespace: %r" % line)

    def test_nothing_is_launched(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox()
        result = self._run(root, bin_dir, extra_env=self.PRINT_ENV)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertFalse(bridge_record.exists(), "print mode must never contact the bridge client")
        self.assertFalse(comate_record.exists(), "print mode must never invoke the Comate/VSCode CLI")
        self.assertFalse(
            (root / "resume-sessions.code-workspace").exists(),
            "print mode must never write the workspace file",
        )

    def test_default_command_omits_dangerous_flag(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox()
        result = self._run(root, bin_dir, extra_env=self.PRINT_ENV)
        self.assertNotIn("--dangerously-skip-permissions", result.stdout)

    def test_skip_permissions_env_appears_in_printed_command(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox()
        env = dict(self.PRINT_ENV, RESUME_SKIP_PERMISSIONS="1")
        result = self._run(root, bin_dir, extra_env=env)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        s = self.session_info[0]
        self.assertIn(
            "cd '%s' && %s --resume %s --dangerously-skip-permissions"
            % (s["cwd"], self._claude(bin_dir), s["id"]),
            result.stdout,
        )

    def test_groups_and_cli_tabs_order_the_printed_block(self):
        # Drive the plain (non-TTY) picker instead of RESUME_AUTO_SELECT so
        # more than one window group is reachable: session 1 is today (group
        # 0, checked by default), session 2 is yesterday (group 1, off). Turn
        # session 2 on, add a +CLI entry to session 1, then confirm. The
        # printed block must group by Gn, and a session's cli command must
        # directly follow its own resume command.
        root, bridge_record, comate_record, bin_dir = self._make_sandbox(
            sessions=(("s-new", 0), ("s-old", 1))
        )
        env = dict(self.PRINT_ENV, RESUME_AUTO_SELECT=None, RESUME_FORCE_SELECT="tui")
        result = self._run(root, bin_dir, extra_env=env, stdin="2\nc1\n\n")
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        new, old = self.session_info
        claude = self._claude(bin_dir)
        expected = (
            "# G0  resume: %s [%s]\n" % (new["name"], new["time"])
            + "cd '%s' && %s --resume %s\n" % (new["cwd"], claude, new["id"])
            + "\n"
            + "# G0  cli: %s\n" % new["name"]
            + "cd '%s'\n" % new["cwd"]
            + "\n"
            + "# G1  resume: %s [%s]\n" % (old["name"], old["time"])
            + "cd '%s' && %s --resume %s\n" % (old["cwd"], claude, old["id"])
        )
        self.assertEqual(result.stdout, expected)

    def test_picker_ui_never_pollutes_stdout(self):
        # Same plain-picker run as above: every prompt, header and hint the
        # picker writes must land off stdout (tty when there is one, stderr
        # otherwise), so `> cmds.txt` stays paste-ready.
        root, bridge_record, comate_record, bin_dir = self._make_sandbox(
            sessions=(("s-new", 0), ("s-old", 1))
        )
        env = dict(self.PRINT_ENV, RESUME_AUTO_SELECT=None, RESUME_FORCE_SELECT="tui")
        result = self._run(root, bin_dir, extra_env=env, stdin="2\nc1\n\n")
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertNotIn("Claude 会话", result.stdout)
        self.assertNotIn("> ", result.stdout)
        self.assertIn("Claude 会话", result.stderr)

    def test_cwd_with_single_quote_is_safely_quoted(self):
        root, bridge_record, comate_record, bin_dir = self._make_sandbox(
            sessions=(("it's work", 0),)
        )
        result = self._run(root, bin_dir, extra_env=self.PRINT_ENV)
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        cmd = [l for l in result.stdout.splitlines() if l.startswith("cd ")][0]
        quoted = cmd.split(" && ", 1)[0][len("cd ") :]
        # The printed line must survive a real shell round-trip back to the
        # original path, rather than merely containing it somewhere.
        probe = subprocess.run(
            ["bash", "-c", "eval \"printf '%s' $QUOTED\""],
            env={"QUOTED": quoted, "PATH": "/usr/bin:/bin"},
            capture_output=True,
            text=True,
        )
        self.assertEqual(probe.returncode, 0, msg=probe.stderr)
        self.assertEqual(probe.stdout, self.session_info[0]["cwd"])


if __name__ == "__main__":
    unittest.main()
