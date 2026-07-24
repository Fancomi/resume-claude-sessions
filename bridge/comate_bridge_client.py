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


@dataclass(frozen=True)
class BridgeCandidate:
    """A live, validated bridge socket discovered on disk.

    "Live" means: the socket file exists; its adjacent metadata file is mode
    0600, has ``version == 1``, and an ``identity`` field matching the
    filename-derived identity; its ``pid`` field is a positive integer that
    is currently a live process (checked via a signal-0 ``kill``, never by
    reading /proc contents); and a bounded connect-then-close to the socket
    itself succeeds.
    """

    identity: str
    socket_path: str
    metadata_path: str
    server_pid: int


PAIR_FILE_NAME = "paired-window.json"
PAIR_VERSION = 1


def _runtime_dir_for(uid: int | None, tmpdir: str | None) -> str:
    resolved_uid = os.getuid() if uid is None else uid
    resolved_tmpdir = tempfile.gettempdir() if tmpdir is None else tmpdir
    return os.path.join(resolved_tmpdir, f"resume-claude-sessions-{resolved_uid}")


def _pid_is_live(pid: object) -> bool:
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # The process exists but is owned by someone else; for our purposes
        # (same-uid runtime dir, same-uid extension host) this should not
        # normally happen, but if it does the process is still live.
        return True
    except OSError:
        return False
    return True


def _socket_accepts_connection(socket_path: str, timeout: float) -> bool:
    sock = socket_module.socket(socket_module.AF_UNIX, socket_module.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(socket_path)
    except OSError:
        return False
    finally:
        sock.close()
    return True


def _load_candidate_at(identity: str, runtime_dir: str, timeout: float) -> BridgeCandidate | None:
    """Validate a single candidate socket/metadata pair by identity.

    Returns ``None`` (never raises) when any liveness check fails, so callers
    enumerating many candidates can simply skip invalid ones.
    """
    socket_path = os.path.join(runtime_dir, f"bridge-{identity}.sock")
    metadata_path = os.path.join(runtime_dir, f"bridge-{identity}.json")

    if not os.path.exists(socket_path):
        return None

    try:
        mode = os.stat(metadata_path).st_mode & 0o777
    except OSError:
        return None
    if mode != 0o600:
        return None

    try:
        with open(metadata_path, "r", encoding="utf-8") as handle:
            metadata = json.load(handle)
    except (OSError, ValueError):
        return None

    if not isinstance(metadata, dict):
        return None
    if metadata.get("version") != 1:
        return None
    if metadata.get("identity") != identity:
        return None

    pid = metadata.get("pid")
    if not _pid_is_live(pid):
        return None

    if not _socket_accepts_connection(socket_path, timeout):
        return None

    return BridgeCandidate(
        identity=identity,
        socket_path=socket_path,
        metadata_path=metadata_path,
        server_pid=pid,
    )


def discover_live_candidates(
    *, uid: int | None = None, tmpdir: str | None = None, timeout: float = DEFAULT_PROBE_TIMEOUT
) -> list[BridgeCandidate]:
    """Enumerate every currently-live bridge candidate in the runtime dir.

    Only looks under ``<tmpdir>/resume-claude-sessions-<uid>`` (or the
    injected test ``tmpdir``); never scans anywhere else. A candidate is
    "live" per :class:`BridgeCandidate`'s docstring; anything else (missing
    metadata, wrong mode, identity/version mismatch, dead PID, or a socket
    that refuses a bounded connect) is silently excluded rather than raising.
    """
    runtime_dir = _runtime_dir_for(uid, tmpdir)
    try:
        entries = os.listdir(runtime_dir)
    except OSError:
        return []

    candidates: list[BridgeCandidate] = []
    for entry in entries:
        if not entry.startswith("bridge-") or not entry.endswith(".sock"):
            continue
        identity = entry[len("bridge-") : -len(".sock")]
        candidate = _load_candidate_at(identity, runtime_dir, timeout)
        if candidate is not None:
            candidates.append(candidate)
    return candidates


def create_pairing(
    workspace_root: str, *, confirmed: bool, uid: int | None = None, tmpdir: str | None = None
) -> dict:
    """Pair the sole live bridge candidate with ``workspace_root``.

    Requires the literal opt-in ``confirmed=True`` (mirroring the CLI's
    ``--confirmed-current-window`` flag); refuses otherwise. Canonicalizes
    ``workspace_root`` with ``os.path.realpath``, requires it to already be
    an existing directory, discovers live candidates (exactly one is
    required; zero or multiple is rejected), and atomically writes a
    mode-0600 pair file (temp file + ``os.replace``) inside the mode-0700
    runtime directory, binding version/identity/socketPath/serverPid and the
    canonicalized workspaceRoot. Raises :class:`BridgeUnavailable` for every
    rejection case; never partially writes the pair file.
    """
    if not confirmed:
        raise BridgeUnavailable(
            "pairing requires the explicit --confirmed-current-window opt-in"
        )

    canonical_workspace = os.path.realpath(workspace_root)
    if not os.path.isdir(canonical_workspace):
        raise BridgeUnavailable(f"workspace root is not an existing directory: {canonical_workspace}")

    candidates = discover_live_candidates(uid=uid, tmpdir=tmpdir)
    if len(candidates) == 0:
        raise BridgeUnavailable("no live bridge candidate found; cannot pair")
    if len(candidates) > 1:
        raise BridgeUnavailable(
            f"{len(candidates)} live bridge candidates found; pairing requires exactly one"
        )

    candidate = candidates[0]
    runtime_dir = _runtime_dir_for(uid, tmpdir)
    os.makedirs(runtime_dir, mode=0o700, exist_ok=True)
    os.chmod(runtime_dir, 0o700)

    record = {
        "version": PAIR_VERSION,
        "identity": candidate.identity,
        "socketPath": candidate.socket_path,
        "serverPid": candidate.server_pid,
        "workspaceRoot": canonical_workspace,
    }

    pair_path = os.path.join(runtime_dir, PAIR_FILE_NAME)
    fd, tmp_path = tempfile.mkstemp(dir=runtime_dir, prefix=".paired-window-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(record, handle)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, pair_path)
    except OSError:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise

    return record


def resolve_pairing(
    workspace_root: str, *, uid: int | None = None, tmpdir: str | None = None, timeout: float = DEFAULT_PROBE_TIMEOUT
) -> BridgeCandidate:
    """Revalidate an existing pairing for ``workspace_root`` and return it.

    Every bound field is revalidated from scratch (never trusted from the
    pair file alone): the pair file must exist, be well-formed JSON, and be
    version 1; ``workspaceRoot`` must equal the realpath of
    ``workspace_root``; the identity's live-candidate checks (metadata mode,
    version, identity match, live PID, bounded connect) must all still pass;
    the currently-live socket path and server PID must be unchanged from the
    pair record; and exactly one live candidate must currently exist overall
    (zero or multiple live sockets is ambiguous and rejected), even if the
    paired one still matches. Any mismatch raises :class:`BridgeUnavailable`
    so callers fail closed before sending anything.
    """
    runtime_dir = _runtime_dir_for(uid, tmpdir)
    pair_path = os.path.join(runtime_dir, PAIR_FILE_NAME)

    try:
        with open(pair_path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError) as error:
        raise BridgeUnavailable(f"no valid pairing found: {error}") from error

    if not isinstance(record, dict) or record.get("version") != PAIR_VERSION:
        raise BridgeUnavailable("pair file is malformed or has an unsupported version")

    identity = record.get("identity")
    bound_socket_path = record.get("socketPath")
    bound_server_pid = record.get("serverPid")
    bound_workspace = record.get("workspaceRoot")
    if not identity or not bound_socket_path or bound_server_pid is None or not bound_workspace:
        raise BridgeUnavailable("pair file is missing required fields")

    canonical_workspace = os.path.realpath(workspace_root)
    if bound_workspace != canonical_workspace:
        raise BridgeUnavailable(
            f"pairing is bound to a different workspace root: {bound_workspace!r} != {canonical_workspace!r}"
        )

    candidates = discover_live_candidates(uid=uid, tmpdir=tmpdir, timeout=timeout)
    if len(candidates) != 1:
        raise BridgeUnavailable(
            f"expected exactly one live bridge candidate, found {len(candidates)}"
        )

    live = candidates[0]
    if live.identity != identity:
        raise BridgeUnavailable("live bridge identity no longer matches the pairing")
    if live.socket_path != bound_socket_path:
        raise BridgeUnavailable("live bridge socket path no longer matches the pairing")
    if live.server_pid != bound_server_pid:
        raise BridgeUnavailable("live bridge server PID no longer matches the pairing (host restarted)")

    return live


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


def _cli_pair(args: argparse.Namespace) -> int:
    if not args.confirmed_current_window:
        print(
            "pair requires the explicit --confirmed-current-window opt-in; refusing",
            file=sys.stderr,
        )
        return EXIT_UNAVAILABLE
    try:
        create_pairing(args.workspace_root, confirmed=True)
    except BridgeUnavailable as error:
        print(f"bridge unavailable: {error}", file=sys.stderr)
        return EXIT_UNAVAILABLE
    return EXIT_OK


def _cli_probe_paired(args: argparse.Namespace) -> int:
    try:
        candidate = resolve_pairing(args.workspace_root)
    except BridgeUnavailable as error:
        print(f"bridge unavailable: {error}", file=sys.stderr)
        return EXIT_UNAVAILABLE
    print(
        json.dumps(
            {
                "identity": candidate.identity,
                "socketPath": candidate.socket_path,
                "serverPid": candidate.server_pid,
            },
            separators=(",", ":"),
        )
    )
    return EXIT_OK


def _cli_send_input0(args: argparse.Namespace) -> int:
    paired_workspace = getattr(args, "paired_workspace", None)
    test_mode = getattr(args, "test_mode", False)
    socket_override_arg = getattr(args, "socket", None)

    if paired_workspace is not None and (args.ipc_hook or test_mode or socket_override_arg):
        print(
            "--paired-workspace is mutually exclusive with --ipc-hook and --test-mode/--socket",
            file=sys.stderr,
        )
        return EXIT_UNAVAILABLE

    if paired_workspace is None and not args.ipc_hook:
        print("send-input0 requires either --ipc-hook or --paired-workspace", file=sys.stderr)
        return EXIT_UNAVAILABLE

    data = sys.stdin.buffer.read()
    # "test"-kind terminals (arbitrary script via `<executable> -lc <script>`)
    # are only ever accepted when --test-mode is set; normal launcher
    # invocations never pass --test-mode, so they can never enable this.
    try:
        terminals = build_terminals(data, allow_test=test_mode)
    except ValueError as error:
        print(f"invalid input0 data: {error}", file=sys.stderr)
        return EXIT_UNAVAILABLE

    if not terminals:
        print("no terminals requested", file=sys.stderr)
        return EXIT_UNAVAILABLE

    if paired_workspace is not None:
        try:
            candidate = resolve_pairing(paired_workspace)
        except BridgeUnavailable as error:
            print(f"bridge unavailable: {error}", file=sys.stderr)
            return EXIT_UNAVAILABLE
        ipc_hook_for_request = "paired-mode-placeholder"
        socket_override = candidate.socket_path
    else:
        ipc_hook_for_request = args.ipc_hook
        # ``--socket`` is a private, test-only override: it is only accepted at
        # all when ``--test-mode`` is also passed, and even then only when it
        # points beneath this user's own private runtime directory (the same
        # ``resume-claude-sessions-<uid>`` directory ``socket_paths`` derives).
        # This lets the guarded integration test in
        # ``scripts/test-comate-bridge-window.sh`` target a freshly opened test
        # window's bridge socket explicitly (since that window's IPC hook is not
        # known to this process ahead of time), without giving normal launcher
        # invocations of ``send-input0`` any way to address an arbitrary socket.
        socket_override = None
        if socket_override_arg:
            if not test_mode:
                print("--socket requires --test-mode", file=sys.stderr)
                return EXIT_UNAVAILABLE
            runtime_dir = socket_paths(args.ipc_hook or "test-mode-placeholder").runtime_dir
            candidate_path = os.path.realpath(socket_override_arg)
            allowed_root = os.path.realpath(runtime_dir)
            if os.path.commonpath([candidate_path, allowed_root]) != allowed_root:
                print(
                    f"--socket must be beneath the private runtime directory {allowed_root}",
                    file=sys.stderr,
                )
                return EXIT_UNAVAILABLE
            socket_override = socket_override_arg

    try:
        response = send_request(
            ipc_hook_for_request, terminals, timeout=args.timeout, _socket_path=socket_override
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

    pair_parser = subparsers.add_parser(
        "pair",
        help=(
            "pair the sole live bridge candidate with a workspace root; requires "
            "explicit --confirmed-current-window"
        ),
    )
    pair_parser.add_argument("--workspace-root", required=True)
    pair_parser.add_argument(
        "--confirmed-current-window",
        dest="confirmed_current_window",
        action="store_true",
        help="explicit user opt-in confirming the sole live socket is the current window",
    )
    pair_parser.set_defaults(handler=_cli_pair)

    probe_paired_parser = subparsers.add_parser(
        "probe-paired", help="revalidate an existing pairing for a workspace root, without sending a request"
    )
    probe_paired_parser.add_argument("--workspace-root", required=True)
    probe_paired_parser.set_defaults(handler=_cli_probe_paired)

    send_parser = subparsers.add_parser(
        "send-input0", help="read NUL-delimited terminal records from stdin and request their creation"
    )
    send_parser.add_argument("--ipc-hook", default=None)
    send_parser.add_argument(
        "--paired-workspace",
        default=None,
        help="use the confirmed pairing for this workspace root instead of --ipc-hook",
    )
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

