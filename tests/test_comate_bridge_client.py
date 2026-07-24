import hashlib
import json
import os
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from bridge.comate_bridge_client import (
    BridgeDeliveryUncertain,
    BridgeUnavailable,
    build_terminals,
    send_request,
    socket_paths,
)


class ClientTests(unittest.TestCase):
    def test_identity_matches_node_contract(self):
        ipc = "/tmp/vscode-ipc-a.sock"
        expected = hashlib.sha256(ipc.encode()).hexdigest()[:24]
        paths = socket_paths(ipc, uid=1234, tmpdir="/tmp")
        self.assertEqual(paths.identity, expected)
        self.assertEqual(paths.socket_path, f"/tmp/resume-claude-sessions-1234/bridge-{expected}.sock")

    def test_input0_builds_safely_quoted_resume_commands(self):
        fields = ["resume", "resume: a", "/tmp/a b", "/opt/claude bin/claude", "session-id", "0"]
        terminals = build_terminals("\0".join(fields).encode() + b"\0")
        self.assertEqual(terminals[0]["cwd"], "/tmp/a b")
        self.assertEqual(terminals[0]["command"], "'/opt/claude bin/claude' --resume session-id")

    def test_skip_permissions_is_explicit_only(self):
        fields = ["resume", "resume: a", "/tmp", "claude", "session-id", "1"]
        terminals = build_terminals("\0".join(fields).encode() + b"\0")
        self.assertEqual(terminals[0]["command"], "claude --resume session-id --dangerously-skip-permissions")

    def test_rejects_incomplete_input0_record(self):
        with self.assertRaisesRegex(ValueError, "six fields"):
            build_terminals(b"resume\0name\0/tmp\0")

    def test_skip_permissions_only_honored_on_field_index_5(self):
        # Any non-"1" value in field 5 must never enable the dangerous flag.
        for value in ("0", "", "true", "yes", "01", " 1"):
            fields = ["resume", "resume: a", "/tmp", "claude", "session-id", value]
            terminals = build_terminals("\0".join(fields).encode() + b"\0")
            self.assertNotIn("--dangerously-skip-permissions", terminals[0]["command"])

    def test_cli_kind_builds_plain_command(self):
        fields = ["cli", "cli: shell", "/tmp", "/bin/bash", "", "0"]
        terminals = build_terminals("\0".join(fields).encode() + b"\0")
        self.assertEqual(terminals[0]["command"], "/bin/bash")
        self.assertEqual(terminals[0]["name"], "cli: shell")

    def test_rejects_unknown_kind(self):
        fields = ["bogus", "name", "/tmp", "claude", "session-id", "0"]
        with self.assertRaisesRegex(ValueError, "unknown kind"):
            build_terminals("\0".join(fields).encode() + b"\0")

    def test_rejects_empty_required_fields(self):
        fields = ["resume", "", "/tmp", "claude", "session-id", "0"]
        with self.assertRaises(ValueError):
            build_terminals("\0".join(fields).encode() + b"\0")

    def test_rejects_more_than_100_records(self):
        record = "\0".join(["cli", "name", "/tmp", "claude", "", "0"]) + "\0"
        with self.assertRaisesRegex(ValueError, "100"):
            build_terminals((record * 101).encode())

    def test_accepts_exactly_100_records(self):
        record = "\0".join(["cli", "name", "/tmp", "claude", "", "0"]) + "\0"
        terminals = build_terminals((record * 100).encode())
        self.assertEqual(len(terminals), 100)

    def test_test_kind_rejected_by_default(self):
        # "test" records must be rejected unless the caller explicitly opts
        # in with allow_test=True; normal (non-test) callers never do this.
        fields = ["test", "bridge-test-identity", "/tmp", "/bin/sh", "echo hi", "0"]
        with self.assertRaisesRegex(ValueError, "test mode"):
            build_terminals("\0".join(fields).encode() + b"\0")

    def test_test_kind_accepted_with_allow_test(self):
        fields = ["test", "bridge-test-identity", "/tmp", "/bin/sh", "echo hi", "0"]
        terminals = build_terminals("\0".join(fields).encode() + b"\0", allow_test=True)
        self.assertEqual(terminals[0]["command"], "/bin/sh -lc 'echo hi'")
        self.assertEqual(terminals[0]["name"], "bridge-test-identity")
        self.assertEqual(terminals[0]["cwd"], "/tmp")

    def test_test_kind_requires_a_script(self):
        fields = ["test", "bridge-test-identity", "/tmp", "/bin/sh", "", "0"]
        with self.assertRaisesRegex(ValueError, "requires a script"):
            build_terminals("\0".join(fields).encode() + b"\0", allow_test=True)

    def test_test_kind_quoting_is_safe_with_shell_metacharacters(self):
        # The script field may itself contain quotes/semicolons/redirects;
        # shlex.join must produce a single safely-quoted argument so the
        # resulting argv is [executable, "-lc", script] verbatim, never
        # allowing the script's content to be split into extra argv entries
        # or to escape its single argument boundary.
        script = "printf '%s' \"$VSCODE_IPC_HOOK_CLI\" > /tmp/x; rm -rf /not-really; exec bash"
        fields = ["test", "bridge-test-identity", "/tmp", "/bin/sh", script, "0"]
        terminals = build_terminals("\0".join(fields).encode() + b"\0", allow_test=True)
        # Round-trip through shlex.split must reproduce exactly [executable, "-lc", script].
        parsed = shlex.split(terminals[0]["command"])
        self.assertEqual(parsed, ["/bin/sh", "-lc", script])

    def test_test_kind_still_rejects_unknown_kind_and_other_validation(self):
        # allow_test=True must not loosen any other validation (unknown
        # kinds, empty required fields, record-count cap remain enforced).
        fields = ["bogus", "name", "/tmp", "claude", "script", "0"]
        with self.assertRaisesRegex(ValueError, "unknown kind"):
            build_terminals("\0".join(fields).encode() + b"\0", allow_test=True)


class FakeBridgeServer:
    """A temporary Unix socket server used to exercise send_request without a real bridge."""

    def __init__(self, handler):
        self._handler = handler
        self._tmpdir = tempfile.mkdtemp(prefix="bridge-client-test-")
        self.socket_path = os.path.join(self._tmpdir, "bridge-test.sock")
        self._server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server.bind(self.socket_path)
        self._server.listen(1)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._accepted = threading.Event()
        self.connection_count = 0
        self._thread.start()

    def _serve(self):
        try:
            conn, _ = self._server.accept()
        except OSError:
            return
        self.connection_count += 1
        self._accepted.set()
        try:
            self._handler(conn)
        finally:
            conn.close()

    def wait_for_connection(self, timeout=1.0):
        self._accepted.wait(timeout)

    def close(self):
        try:
            self._server.close()
        finally:
            import shutil

            shutil.rmtree(self._tmpdir, ignore_errors=True)


def _echo_handler(conn):
    data = b""
    conn.settimeout(1.0)
    while b"\n" not in data:
        chunk = conn.recv(65536)
        if not chunk:
            break
        data += chunk
    try:
        request = json.loads(data.split(b"\n", 1)[0].decode("utf8"))
    except (ValueError, IndexError):
        return
    response = {
        "version": 1,
        "requestId": request["requestId"],
        "created": len(request["terminals"]),
        "errors": [],
    }
    conn.sendall((json.dumps(response) + "\n").encode("utf8"))


def _make_response_handler(build_response):
    """Build a handler that replies with a caller-supplied response payload,
    derived from the parsed request, instead of the default echo shape."""

    def handler(conn):
        data = b""
        conn.settimeout(1.0)
        while b"\n" not in data:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        try:
            request = json.loads(data.split(b"\n", 1)[0].decode("utf8"))
        except (ValueError, IndexError):
            return
        response = build_response(request)
        conn.sendall((json.dumps(response) + "\n").encode("utf8"))

    return handler


def _silent_handler(conn):
    # Accept the connection and read the request but never reply, to trigger a client timeout.
    data = b""
    conn.settimeout(1.0)
    try:
        while b"\n" not in data:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    time.sleep(0.5)


class SendRequestTests(unittest.TestCase):
    def test_send_request_returns_server_response(self):
        server = FakeBridgeServer(_echo_handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            response = send_request(
                "unused-ipc-hook", terminals, timeout=2.0, _socket_path=server.socket_path
            )
            self.assertEqual(response["created"], 1)
            self.assertEqual(response["errors"], [])
            self.assertTrue(response["requestId"])
        finally:
            server.close()

    def test_send_request_raises_bridge_delivery_uncertain_on_response_timeout(self):
        server = FakeBridgeServer(_silent_handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeDeliveryUncertain):
                send_request(
                    "unused-ipc-hook", terminals, timeout=0.05, _socket_path=server.socket_path
                )
        finally:
            server.close()

    def test_send_request_sends_only_once(self):
        server = FakeBridgeServer(_silent_handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeDeliveryUncertain):
                send_request(
                    "unused-ipc-hook", terminals, timeout=0.05, _socket_path=server.socket_path
                )
            self.assertEqual(server.connection_count, 1)
        finally:
            server.close()

    def test_send_request_raises_bridge_unavailable_on_connect_failure(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            missing_socket = os.path.join(tmpdir, "no-such-bridge.sock")
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeUnavailable):
                send_request(
                    "unused-ipc-hook", terminals, timeout=0.05, _socket_path=missing_socket
                )

    def test_send_request_rejects_boolean_created(self):
        handler = _make_response_handler(
            lambda request: {
                "version": 1,
                "requestId": request["requestId"],
                "created": True,
                "errors": [],
            }
        )
        server = FakeBridgeServer(handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeDeliveryUncertain):
                send_request(
                    "unused-ipc-hook", terminals, timeout=2.0, _socket_path=server.socket_path
                )
        finally:
            server.close()

    def test_send_request_rejects_non_integer_created(self):
        handler = _make_response_handler(
            lambda request: {
                "version": 1,
                "requestId": request["requestId"],
                "created": "1",
                "errors": [],
            }
        )
        server = FakeBridgeServer(handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeDeliveryUncertain):
                send_request(
                    "unused-ipc-hook", terminals, timeout=2.0, _socket_path=server.socket_path
                )
        finally:
            server.close()

    def test_send_request_rejects_created_greater_than_requested_count(self):
        handler = _make_response_handler(
            lambda request: {
                "version": 1,
                "requestId": request["requestId"],
                "created": len(request["terminals"]) + 1,
                "errors": [],
            }
        )
        server = FakeBridgeServer(handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeDeliveryUncertain):
                send_request(
                    "unused-ipc-hook", terminals, timeout=2.0, _socket_path=server.socket_path
                )
        finally:
            server.close()

    def test_send_request_rejects_negative_created(self):
        handler = _make_response_handler(
            lambda request: {
                "version": 1,
                "requestId": request["requestId"],
                "created": -1,
                "errors": [],
            }
        )
        server = FakeBridgeServer(handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeDeliveryUncertain):
                send_request(
                    "unused-ipc-hook", terminals, timeout=2.0, _socket_path=server.socket_path
                )
        finally:
            server.close()

    def test_send_request_accepts_zero_created_with_errors(self):
        handler = _make_response_handler(
            lambda request: {
                "version": 1,
                "requestId": request["requestId"],
                "created": 0,
                "errors": ["failed to spawn terminal"],
            }
        )
        server = FakeBridgeServer(handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            response = send_request(
                "unused-ipc-hook", terminals, timeout=2.0, _socket_path=server.socket_path
            )
            self.assertEqual(response["created"], 0)
            self.assertEqual(response["errors"], ["failed to spawn terminal"])
        finally:
            server.close()

    def test_send_request_rejects_non_list_errors(self):
        handler = _make_response_handler(
            lambda request: {
                "version": 1,
                "requestId": request["requestId"],
                "created": 1,
                "errors": "boom",
            }
        )
        server = FakeBridgeServer(handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeDeliveryUncertain):
                send_request(
                    "unused-ipc-hook", terminals, timeout=2.0, _socket_path=server.socket_path
                )
        finally:
            server.close()

    def test_send_request_rejects_errors_with_non_string_items(self):
        handler = _make_response_handler(
            lambda request: {
                "version": 1,
                "requestId": request["requestId"],
                "created": 1,
                "errors": [{"message": "boom"}],
            }
        )
        server = FakeBridgeServer(handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeDeliveryUncertain):
                send_request(
                    "unused-ipc-hook", terminals, timeout=2.0, _socket_path=server.socket_path
                )
        finally:
            server.close()


class ProbeTests(unittest.TestCase):
    def test_probe_succeeds_against_metadata_and_live_socket(self):
        from bridge.comate_bridge_client import probe

        with tempfile.TemporaryDirectory() as tmpdir:
            ipc_hook = "/tmp/vscode-ipc-probe-test.sock"
            paths = socket_paths(ipc_hook, uid=os.getuid(), tmpdir=tmpdir)
            os.makedirs(paths.runtime_dir, exist_ok=True)

            with open(paths.metadata_path, "w", encoding="utf-8") as handle:
                json.dump(
                    {"version": 1, "pid": 1, "identity": paths.identity, "ipcHookHash": paths.identity},
                    handle,
                )
            os.chmod(paths.metadata_path, 0o600)

            server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            server.bind(paths.socket_path)
            server.listen(1)
            try:
                metadata = probe(ipc_hook, timeout=1.0, uid=os.getuid(), tmpdir=tmpdir)
                self.assertEqual(metadata["identity"], paths.identity)
            finally:
                server.close()

    def test_probe_raises_bridge_unavailable_without_metadata(self):
        from bridge.comate_bridge_client import probe

        with tempfile.TemporaryDirectory() as tmpdir:
            with self.assertRaises(BridgeUnavailable):
                probe("/tmp/vscode-ipc-missing.sock", timeout=0.05, uid=os.getuid(), tmpdir=tmpdir)



class CliTests(unittest.TestCase):
    """Exercise the probe/send-input0 CLI subcommands as subprocesses."""

    def _run(self, args, input_bytes=b""):
        repo_root = Path(__file__).resolve().parents[1]
        return subprocess.run(
            [sys.executable, "-m", "bridge.comate_bridge_client", *args],
            input=input_bytes,
            cwd=repo_root,
            capture_output=True,
        )

    def test_probe_cli_exits_2_when_unavailable(self):
        result = self._run(["probe", "--ipc-hook", "/tmp/vscode-ipc-cli-missing.sock", "--timeout", "0.05"])
        self.assertEqual(result.returncode, 2)

    def test_send_input0_cli_exits_2_on_invalid_input(self):
        result = self._run(
            ["send-input0", "--ipc-hook", "/tmp/vscode-ipc-cli-missing.sock", "--timeout", "0.05"],
            input_bytes=b"resume\0name\0/tmp\0",
        )
        self.assertEqual(result.returncode, 2)

    def test_send_input0_cli_exits_2_when_bridge_unreachable(self):
        fields = ["cli", "cli: shell", "/tmp", "/bin/bash", "", "0"]
        result = self._run(
            ["send-input0", "--ipc-hook", "/tmp/vscode-ipc-cli-missing.sock", "--timeout", "0.05"],
            input_bytes=("\0".join(fields) + "\0").encode(),
        )
        self.assertEqual(result.returncode, 2)

    def test_socket_override_rejected_without_test_mode(self):
        # --socket alone (no --test-mode) must be refused before any bridge
        # I/O is attempted, regardless of whether the path is otherwise valid.
        fields = ["cli", "cli: shell", "/tmp", "/bin/bash", "", "0"]
        result = self._run(
            [
                "send-input0",
                "--ipc-hook",
                "/tmp/vscode-ipc-cli-missing.sock",
                "--timeout",
                "0.05",
                "--socket",
                "/tmp/resume-claude-sessions-0/bridge-doesnotexist.sock",
            ],
            input_bytes=("\0".join(fields) + "\0").encode(),
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"--test-mode", result.stderr)

    def test_socket_override_rejected_outside_private_runtime_dir(self):
        # Even with --test-mode, a --socket path outside the private
        # per-user runtime directory must be rejected.
        fields = ["cli", "cli: shell", "/tmp", "/bin/bash", "", "0"]
        result = self._run(
            [
                "send-input0",
                "--ipc-hook",
                "/tmp/vscode-ipc-cli-missing.sock",
                "--timeout",
                "0.05",
                "--test-mode",
                "--socket",
                "/tmp/not-the-runtime-dir/evil.sock",
            ],
            input_bytes=("\0".join(fields) + "\0").encode(),
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"private runtime directory", result.stderr)

    def test_socket_override_accepted_inside_private_runtime_dir_with_test_mode(self):
        # A --socket path beneath the private runtime dir, combined with
        # --test-mode, is allowed through to send_request (which will then
        # fail with BridgeUnavailable/2 because nothing is listening — this
        # test only proves the gating logic itself does not reject it).
        with tempfile.TemporaryDirectory() as tmp:
            uid = os.getuid()
            fake_runtime_dir = Path(tmp) / f"resume-claude-sessions-{uid}"
            fake_runtime_dir.mkdir()
            fake_socket = fake_runtime_dir / "bridge-test.sock"
            fields = ["cli", "cli: shell", "/tmp", "/bin/bash", "", "0"]
            env = dict(os.environ)
            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "bridge.comate_bridge_client",
                    "send-input0",
                    "--ipc-hook",
                    "irrelevant-in-test-mode",
                    "--timeout",
                    "0.05",
                    "--test-mode",
                    "--socket",
                    str(fake_socket),
                ],
                input=("\0".join(fields) + "\0").encode(),
                cwd=Path(__file__).resolve().parents[1],
                capture_output=True,
                env={**env, "TMPDIR": tmp},
            )
            self.assertEqual(result.returncode, 2)
            self.assertNotIn(b"--test-mode", result.stderr)
            self.assertNotIn(b"private runtime directory", result.stderr)

    def test_send_input0_cli_rejects_test_kind_record_in_normal_mode(self):
        # A "test"-kind record must be rejected by send-input0 when
        # --test-mode is not passed, before any bridge I/O is attempted.
        fields = ["test", "bridge-test-identity", "/tmp", "/bin/sh", "echo hi", "0"]
        result = self._run(
            ["send-input0", "--ipc-hook", "/tmp/vscode-ipc-cli-missing.sock", "--timeout", "0.05"],
            input_bytes=("\0".join(fields) + "\0").encode(),
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"test mode", result.stderr)

    def test_send_input0_cli_accepts_test_kind_record_with_test_mode(self):
        # With --test-mode (and a --socket beneath the private runtime dir),
        # a "test"-kind record is parsed successfully; the only failure past
        # that point is BridgeUnavailable (nothing listening), proving the
        # kind gate itself does not block valid test-mode input.
        with tempfile.TemporaryDirectory() as tmp:
            uid = os.getuid()
            fake_runtime_dir = Path(tmp) / f"resume-claude-sessions-{uid}"
            fake_runtime_dir.mkdir()
            fake_socket = fake_runtime_dir / "bridge-test.sock"
            fields = ["test", "bridge-test-identity", "/tmp", "/bin/sh", "echo hi", "0"]
            env = dict(os.environ)
            result = subprocess.run(
                [
                    sys.executable,
                    "-m",
                    "bridge.comate_bridge_client",
                    "send-input0",
                    "--ipc-hook",
                    "irrelevant-in-test-mode",
                    "--timeout",
                    "0.05",
                    "--test-mode",
                    "--socket",
                    str(fake_socket),
                ],
                input=("\0".join(fields) + "\0").encode(),
                cwd=Path(__file__).resolve().parents[1],
                capture_output=True,
                env={**env, "TMPDIR": tmp},
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn(b"bridge unavailable", result.stderr)
            self.assertNotIn(b"test mode", result.stderr)
            self.assertNotIn(b"unknown kind", result.stderr)


if __name__ == "__main__":
    unittest.main()
