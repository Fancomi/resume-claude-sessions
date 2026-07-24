"""Dependency-free Python client for the exact-window Comate terminal bridge.

Consumes the identity/socket-path algorithm and JSON-line protocol implemented
in ``comate-bridge/lib/identity.js`` and ``comate-bridge/lib/protocol.js``:

- ``socket_paths`` reproduces the Node ``pathsFor`` derivation exactly
  (sha256(ipc_hook) truncated to 24 hex chars; runtime dir
  ``<tmpdir>/resume-claude-sessions-<uid>``; socket/metadata file names).
- ``send_request`` speaks the same newline-delimited JSON request/response
  framing as ``lib/protocol.js`` (``readJsonLine``/``writeJsonLine``), bounded
  to 1 MiB and validated the same way the server validates it.

Standard library only; no third-party dependencies.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import shlex
import socket as socket_module
import sys
import tempfile
from dataclasses import dataclass
from typing import Sequence

MAX_BYTES = 1024 * 1024
MAX_TERMINALS = 100
REQUEST_ID_FIELD_COUNT = 6
DEFAULT_PROBE_TIMEOUT = 0.25
DEFAULT_SEND_TIMEOUT = 2.0

# Exit codes for the CLI, mirroring the launcher's documented contract.
EXIT_OK = 0
EXIT_UNAVAILABLE = 2
EXIT_UNCERTAIN = 3
EXIT_ERRORS = 4


class BridgeUnavailable(Exception):
    """Raised when the bridge cannot be reached before any bytes are sent.

    Callers may safely retry or fall back (e.g. to opening a new window) when
    this is raised, because it is only raised for connect-phase failures,
    strictly before any request bytes are written to the socket.
    """


class BridgeDeliveryUncertain(Exception):
    """Raised once request bytes may have reached the server.

    Callers MUST NOT retry or fall back after this is raised: the server may
    have already started creating terminals, and resending or opening a
    fallback window could duplicate them.
    """


@dataclass(frozen=True)
class SocketPaths:
    identity: str
    runtime_dir: str
    socket_path: str
    metadata_path: str


def _derive_identity(ipc_hook: str) -> str:
    if not isinstance(ipc_hook, str) or not ipc_hook:
        raise ValueError("ipc_hook is required for exact-window routing")
    return hashlib.sha256(ipc_hook.encode("utf-8")).hexdigest()[:24]


def socket_paths(ipc_hook: str, uid: int | None = None, tmpdir: str | None = None) -> SocketPaths:
    """Derive the exact-window socket/metadata paths for ``ipc_hook``.

    Mirrors ``comate-bridge/lib/identity.js``'s ``pathsFor`` byte for byte:
    same hash, same truncation, same runtime directory and file naming.
    """
    resolved_uid = os.getuid() if uid is None else uid
    resolved_tmpdir = tempfile.gettempdir() if tmpdir is None else tmpdir
    identity = _derive_identity(ipc_hook)
    runtime_dir = os.path.join(resolved_tmpdir, f"resume-claude-sessions-{resolved_uid}")
    return SocketPaths(
        identity=identity,
        runtime_dir=runtime_dir,
        socket_path=os.path.join(runtime_dir, f"bridge-{identity}.sock"),
        metadata_path=os.path.join(runtime_dir, f"bridge-{identity}.json"),
    )


def _split_nul_records(data: bytes) -> list[list[str]]:
    """Split NUL-delimited input0 bytes into a list of 6-field records.

    The wire format is a flat sequence of NUL-terminated fields, six fields
    per terminal record, with a trailing NUL after the last field of each
    record (as produced by the shell launcher's ``printf '%s\\0' ...`` loop).
    """
    if data.endswith(b"\0"):
        data = data[:-1]
    if not data:
        return []
    fields = data.decode("utf-8").split("\0")
    if len(fields) % REQUEST_ID_FIELD_COUNT != 0:
        raise ValueError(
            f"input0 record is malformed: each terminal requires six fields, got a total of "
            f"{len(fields)} fields (not a multiple of {REQUEST_ID_FIELD_COUNT})"
        )
    return [
        fields[i : i + REQUEST_ID_FIELD_COUNT]
        for i in range(0, len(fields), REQUEST_ID_FIELD_COUNT)
    ]


def build_terminals(data: bytes, *, allow_test: bool = False) -> list[dict]:
    """Parse NUL-delimited input0 records into bridge terminal descriptors.

    Each record has exactly six fields:
        kind, name, cwd, executable, session_id_or_empty, skip_permissions_0_or_1

    Supported kinds:
        - "resume": command is
          ``shlex.join([executable, "--resume", session_id] + [dangerous_flag?])``
        - "cli": command is ``shlex.join([executable])``
        - "test": command is ``shlex.join([executable, "-lc", session_id])`` —
          i.e. the record's session-id field carries an arbitrary shell
          script to run via ``<executable> -lc <script>``. This kind is
          rejected with ``ValueError`` unless the caller explicitly passes
          ``allow_test=True``; normal launcher flow (which never sets
          ``allow_test``) can never produce a "test" terminal, no matter what
          bytes it is fed. It exists solely so the guarded isolated
          integration test (``scripts/test-comate-bridge-window.sh``, via
          ``send-input0 --test-mode``) can request terminals that run a
          specific script (e.g. write ``$VSCODE_IPC_HOOK_CLI`` to a file, or
          print a fixed marker line) before dropping into an interactive
          shell, without weakening the "resume"/"cli" contract normal
          invocations rely on.

    Raises ``ValueError`` for unknown kinds, a "test" record when
    ``allow_test`` is not set, incomplete records, embedded empty
    name/cwd/executable fields, or more than 100 records. The dangerous
    ``--dangerously-skip-permissions`` flag is only ever added when field
    index 5 is exactly the string ``"1"`` — any other value (including "0",
    empty, or anything else) never enables it.
    """
    records = _split_nul_records(data)
    if len(records) > MAX_TERMINALS:
        raise ValueError(f"input0 contains more than {MAX_TERMINALS} terminal records")

    terminals = []
    for record in records:
        if len(record) != REQUEST_ID_FIELD_COUNT:
            raise ValueError(
                f"input0 record is malformed: each terminal requires six fields, got {len(record)}"
            )
        kind, name, cwd, executable, session_id, skip_permissions = record

        if not name:
            raise ValueError("input0 record has an empty name field")
        if not cwd:
            raise ValueError("input0 record has an empty cwd field")
        if not executable:
            raise ValueError("input0 record has an empty executable field")

        dangerous = skip_permissions == "1"

        if kind == "resume":
            if not session_id:
                raise ValueError("input0 'resume' record requires a session id")
            argv = [executable, "--resume", session_id]
            if dangerous:
                argv.append("--dangerously-skip-permissions")
            command = shlex.join(argv)
        elif kind == "cli":
            command = shlex.join([executable])
        elif kind == "test":
            if not allow_test:
                raise ValueError(
                    "input0 'test' record is only permitted in test mode "
                    "(send-input0 --test-mode); rejected by default"
                )
            if not session_id:
                raise ValueError("input0 'test' record requires a script in the session-id field")
            command = shlex.join([executable, "-lc", session_id])
        else:
            raise ValueError(f"unknown kind in input0 record: {kind!r}")

        terminals.append({"name": name, "cwd": cwd, "command": command})

    return terminals


def _read_json_line(sock: socket_module.socket, max_bytes: int = MAX_BYTES) -> dict:
    """Read at most ``max_bytes`` from ``sock`` up through the first newline.

    Mirrors the server's ``readJsonLine`` bound: if no newline appears within
    the byte cap, raise ``BridgeDeliveryUncertain`` (bytes may already have
    been sent, so callers must not retry or fall back). Never automatically
    resends anything itself; retry policy is entirely the caller's.
    """
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > max_bytes:
            raise BridgeDeliveryUncertain("bridge response exceeds 1 MiB")
        data = b"".join(chunks)
        newline = data.find(b"\n")
        if newline != -1:
            try:
                return json.loads(data[:newline].decode("utf-8"))
            except ValueError as error:
                raise BridgeDeliveryUncertain(f"invalid JSON in bridge response: {error}") from error
    raise BridgeDeliveryUncertain("bridge closed the connection before sending a newline-terminated response")


def send_request(
    ipc_hook: str,
    terminals: Sequence[dict],
    timeout: float = DEFAULT_SEND_TIMEOUT,
    _socket_path: str | None = None,
) -> dict:
    """Send one terminal-creation request to the exact-window bridge.

    Connects only to the Unix socket derived from ``ipc_hook`` (never
    enumerates other sockets), sends one compact JSON line, and reads at
    most 1 MiB of response through the first newline.

    Delivery-state exit semantics: once the connection is established and
    bytes have been written to the socket, this function never retries or
    resends — a failure after that point, including a timeout while waiting
    for the response, is surfaced as ``BridgeDeliveryUncertain`` rather than
    silently swallowed or retried, because the server may already be
    creating terminals and the request bytes may already have been
    delivered. A failure to even connect is surfaced as
    ``BridgeUnavailable``, which is safe to fall back on since nothing was
    sent.

    Returns the parsed response dict with ``version``, ``requestId``,
    ``created`` (an int in ``[0, len(terminals)]``), and ``errors`` (a list
    of strings) verified against the request.

    ``_socket_path`` is a private test-only override letting the test suite
    point at a temporary fake-server socket without threading a real
    ``VSCODE_IPC_HOOK_CLI`` value through; normal callers must not pass it.
    """
    if not terminals:
        raise ValueError("terminals must contain at least one entry")
    if len(terminals) > MAX_TERMINALS:
        raise ValueError(f"terminals must contain at most {MAX_TERMINALS} entries")

    request_id = secrets.token_hex(16)
    request = {
        "version": 1,
        "requestId": request_id,
        "terminals": list(terminals),
    }
    payload = (json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8")
    if len(payload) > MAX_BYTES:
        raise ValueError("request exceeds 1 MiB")

    target_path = _socket_path if _socket_path is not None else socket_paths(ipc_hook).socket_path
    sock = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        try:
            sock.connect(target_path)
        except OSError as error:
            # Nothing was sent yet: safe for the caller to treat as unavailable.
            raise BridgeUnavailable(f"cannot connect to bridge socket: {error}") from error

        try:
            sock.sendall(payload)
        except OSError as error:
            # The OS may have buffered/sent partial bytes already; treat as uncertain.
            raise BridgeDeliveryUncertain(f"failed while sending request: {error}") from error

        try:
            response = _read_json_line(sock, MAX_BYTES)
        except socket_module.timeout as error:
            # Request bytes were already sent: a timeout here does not mean
            # the request never arrived, so this must not be treated as safe
            # to retry or fall back on.
            raise BridgeDeliveryUncertain(f"timed out waiting for bridge response: {error}") from error
        except OSError as error:
            raise BridgeDeliveryUncertain(f"connection failed while reading response: {error}") from error
    finally:
        sock.close()

    if response.get("version") != 1:
        raise BridgeDeliveryUncertain(f"unsupported bridge protocol version: {response.get('version')!r}")
    if response.get("requestId") != request_id:
        raise BridgeDeliveryUncertain(
            f"bridge response requestId mismatch: expected {request_id}, got {response.get('requestId')!r}"
        )
    if "created" not in response or "errors" not in response:
        raise BridgeDeliveryUncertain("bridge response missing created/errors fields")

    created = response.get("created")
    if not isinstance(created, int) or isinstance(created, bool):
        raise BridgeDeliveryUncertain(f"bridge response 'created' is not an integer: {created!r}")
    if created < 0 or created > len(terminals):
        raise BridgeDeliveryUncertain(
            f"bridge response 'created' ({created}) is out of range for {len(terminals)} requested terminal(s)"
        )

    errors = response.get("errors")
    if not isinstance(errors, list) or not all(isinstance(item, str) for item in errors):
        raise BridgeDeliveryUncertain(f"bridge response 'errors' is not a list of strings: {errors!r}")

    return response


def probe(
    ipc_hook: str,
    timeout: float = DEFAULT_PROBE_TIMEOUT,
    uid: int | None = None,
    tmpdir: str | None = None,
) -> dict:
    """Check whether the exact-window bridge is available, without sending a request.

    The terminal protocol has no reserved "no-op" operation, so probing works
    by reading the adjacent mode-0600 metadata file the server writes next to
    its socket (``{"version": 1, "pid", "identity", "ipcHookHash"}``),
    verifying its version and identity match this ``ipc_hook``, then opening
    and immediately closing a connection to the socket without sending any
    bytes. The server tolerates an empty connection without creating a
    terminal, so this never risks duplicating terminals.

    ``uid``/``tmpdir`` mirror :func:`socket_paths` and exist so tests can
    point the derivation at a temporary directory instead of the real
    per-uid runtime directory under ``/tmp``.

    Raises ``BridgeUnavailable`` if the metadata file is missing/invalid or
    the socket cannot be connected to. Returns the metadata dict on success.
    """
    paths = socket_paths(ipc_hook, uid=uid, tmpdir=tmpdir)

    try:
        with open(paths.metadata_path, "r", encoding="utf-8") as handle:
            metadata = json.load(handle)
    except (OSError, ValueError) as error:
        raise BridgeUnavailable(f"cannot read bridge metadata: {error}") from error

    if metadata.get("version") != 1:
        raise BridgeUnavailable(f"unsupported bridge metadata version: {metadata.get('version')!r}")
    if metadata.get("identity") != paths.identity:
        raise BridgeUnavailable("bridge metadata identity does not match this window")

    sock = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(paths.socket_path)
    except OSError as error:
        raise BridgeUnavailable(f"cannot connect to bridge socket: {error}") from error
    finally:
        sock.close()

    return metadata


def _cli_probe(args: argparse.Namespace) -> int:
    try:
        probe(args.ipc_hook, timeout=args.timeout)
    except BridgeUnavailable as error:
        print(f"bridge unavailable: {error}", file=sys.stderr)
        return EXIT_UNAVAILABLE
    return EXIT_OK


def _cli_send_input0(args: argparse.Namespace) -> int:
    data = sys.stdin.buffer.read()
    # "test"-kind terminals (arbitrary script via `<executable> -lc <script>`)
    # are only ever accepted when --test-mode is set; normal launcher
    # invocations never pass --test-mode, so they can never enable this.
    try:
        terminals = build_terminals(data, allow_test=getattr(args, "test_mode", False))
    except ValueError as error:
        print(f"invalid input0 data: {error}", file=sys.stderr)
        return EXIT_UNAVAILABLE

    if not terminals:
        print("no terminals requested", file=sys.stderr)
        return EXIT_UNAVAILABLE

    # ``--socket`` is a private, test-only override: it is only accepted at
    # all when ``--test-mode`` is also passed, and even then only when it
    # points beneath this user's own private runtime directory (the same
    # ``resume-claude-sessions-<uid>`` directory ``socket_paths`` derives).
    # This lets the guarded integration test in
    # ``scripts/test-comate-bridge-window.sh`` target a freshly opened test
    # window's bridge socket explicitly (since that window's IPC hook is not
    # known to this process ahead of time), without giving normal launcher
    # invocations of ``send-input0`` any way to address an arbitrary socket.
    socket_override: str | None = None
    if getattr(args, "socket", None):
        if not getattr(args, "test_mode", False):
            print("--socket requires --test-mode", file=sys.stderr)
            return EXIT_UNAVAILABLE
        runtime_dir = socket_paths(args.ipc_hook or "test-mode-placeholder").runtime_dir
        candidate = os.path.realpath(args.socket)
        allowed_root = os.path.realpath(runtime_dir)
        if os.path.commonpath([candidate, allowed_root]) != allowed_root:
            print(
                f"--socket must be beneath the private runtime directory {allowed_root}",
                file=sys.stderr,
            )
            return EXIT_UNAVAILABLE
        socket_override = args.socket

    try:
        response = send_request(
            args.ipc_hook, terminals, timeout=args.timeout, _socket_path=socket_override
        )
    except BridgeUnavailable as error:
        print(f"bridge unavailable: {error}", file=sys.stderr)
        return EXIT_UNAVAILABLE
    except BridgeDeliveryUncertain as error:
        print(f"bridge delivery uncertain, not retrying: {error}", file=sys.stderr)
        return EXIT_UNCERTAIN

    if response.get("errors"):
        for message in response["errors"]:
            print(f"bridge terminal error: {message}", file=sys.stderr)
        return EXIT_ERRORS

    return EXIT_OK


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="comate_bridge_client", description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    probe_parser = subparsers.add_parser("probe", help="check whether the exact-window bridge is available")
    probe_parser.add_argument("--ipc-hook", required=True)
    probe_parser.add_argument("--timeout", type=float, default=DEFAULT_PROBE_TIMEOUT)
    probe_parser.set_defaults(handler=_cli_probe)

    send_parser = subparsers.add_parser(
        "send-input0", help="read NUL-delimited terminal records from stdin and request their creation"
    )
    send_parser.add_argument("--ipc-hook", required=True)
    send_parser.add_argument("--timeout", type=float, default=DEFAULT_SEND_TIMEOUT)
    send_parser.add_argument(
        "--test-mode",
        action="store_true",
        help="required alongside --socket; never set by the normal launcher",
    )
    send_parser.add_argument(
        "--socket",
        default=None,
        help=(
            "test-only explicit socket path override, beneath the private runtime "
            "directory; requires --test-mode and is rejected otherwise"
        ),
    )
    send_parser.set_defaults(handler=_cli_send_input0)

    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main())

