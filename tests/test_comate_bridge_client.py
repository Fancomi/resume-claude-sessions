import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from bridge.comate_bridge_client import (
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

    def test_send_request_raises_bridge_unavailable_on_timeout(self):
        server = FakeBridgeServer(_silent_handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeUnavailable):
                send_request(
                    "unused-ipc-hook", terminals, timeout=0.05, _socket_path=server.socket_path
                )
        finally:
            server.close()

    def test_send_request_sends_only_once(self):
        server = FakeBridgeServer(_silent_handler)
        try:
            terminals = [{"name": "one", "cwd": "/tmp", "command": "printf one"}]
            with self.assertRaises(BridgeUnavailable):
                send_request(
                    "unused-ipc-hook", terminals, timeout=0.05, _socket_path=server.socket_path
                )
            self.assertEqual(server.connection_count, 1)
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


if __name__ == "__main__":
    unittest.main()
