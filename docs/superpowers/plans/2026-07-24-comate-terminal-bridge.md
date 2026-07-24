# Comate Current-Window Terminal Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Append selected Claude sessions as independent terminals to the exact Comate window containing the invoking terminal, without changing any existing window or terminal.

**Architecture:** A dependency-free Comate extension listens on a per-window Unix socket derived from `VSCODE_IPC_HOOK_CLI`. A Python client derives the same socket, encodes selected sessions, and requests terminal creation. The shell launcher uses the bridge when an exact-window probe succeeds and otherwise opens the existing isolated `.code-workspace` in a new window.

**Tech Stack:** Bash 4+, Python 3.10 standard library, Node.js 20 standard library, VS Code extension API, `node:test`, `unittest`, Unix-domain sockets.

## Global Constraints

- Never call `comate -r`, `--reuse-window`, a reload command, a workspace replacement command, or an extension-host restart command.
- Never close, hide, rename, reuse, split, or send text to a pre-existing terminal.
- Each requested session must use a new top-level terminal created without a split location.
- Installation must not reload the current Comate window; the bridge becomes active after a natural restart.
- All integration requests must target a separately opened test window, never the original window.
- If exact-window routing cannot be proven, refuse the bridge request and fall back to `comate -n`.
- The bridge uses only local standard-library code; do not add runtime npm or Python dependencies.
- The socket directory must be mode `0700`; requests are capped at 1 MiB and 100 terminals.

---

## File Structure

- `comate-bridge/package.json`: extension metadata and startup activation.
- `comate-bridge/extension.js`: VS Code activation, terminal adapter, and server lifecycle.
- `comate-bridge/lib/identity.js`: deterministic per-window identity and private socket paths.
- `comate-bridge/lib/protocol.js`: request validation and bounded JSON-line framing.
- `comate-bridge/lib/server.js`: Unix socket server independent of the VS Code API.
- `comate-bridge/test/identity.test.js`: identity/path unit tests.
- `comate-bridge/test/protocol.test.js`: validation and framing unit tests.
- `comate-bridge/test/server.test.js`: socket request/response tests with a fake terminal adapter.
- `bridge/comate_bridge_client.py`: exact-window probe and request client.
- `tests/test_comate_bridge_client.py`: Python client and shell-quoting tests.
- `scripts/package-comate-bridge.py`: deterministic VSIX packager using `zipfile`.
- `scripts/install-comate-bridge.sh`: explicit install command that never reloads a window.
- `scripts/test-comate-bridge-window.sh`: guarded integration test that opens only a new test window.
- `resume-claude-sessions.sh`: bridge-first VSCode launch with safe new-window fallback.
- `README.md`: setup, normal use, first-install behavior, and safety guarantees.

---

### Task 1: Window Identity And Protocol Validation

**Files:**
- Create: `comate-bridge/lib/identity.js`
- Create: `comate-bridge/lib/protocol.js`
- Create: `comate-bridge/test/identity.test.js`
- Create: `comate-bridge/test/protocol.test.js`
- Create: `comate-bridge/package.json`

**Interfaces:**
- Produces: `deriveIdentity(ipcHook: string): string`
- Produces: `pathsFor(ipcHook: string, options?): { runtimeDir, socketPath, metadataPath, identity }`
- Produces: `validateRequest(value): { version, requestId, terminals }`
- Produces: `readJsonLine(socket, options?): Promise<object>`
- Produces: `writeJsonLine(socket, value): void`

- [ ] **Step 1: Add extension metadata and a failing identity test**

```json
{
  "name": "resume-claude-sessions-bridge",
  "displayName": "Resume Claude Sessions Bridge",
  "publisher": "penghaotian-local",
  "version": "0.1.0",
  "engines": { "vscode": "^1.85.0" },
  "categories": ["Other"],
  "activationEvents": ["onStartupFinished"],
  "main": "./extension.js",
  "scripts": { "test": "node --test test/*.test.js" }
}
```

```js
// comate-bridge/test/identity.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const { deriveIdentity, pathsFor } = require('../lib/identity');

test('identity is deterministic and window-specific', () => {
  assert.equal(deriveIdentity('/tmp/vscode-ipc-a.sock'), deriveIdentity('/tmp/vscode-ipc-a.sock'));
  assert.notEqual(deriveIdentity('/tmp/vscode-ipc-a.sock'), deriveIdentity('/tmp/vscode-ipc-b.sock'));
  assert.match(deriveIdentity('/tmp/vscode-ipc-a.sock'), /^[a-f0-9]{24}$/);
});

test('socket path is private, short, and uid-scoped', () => {
  const paths = pathsFor('/tmp/vscode-ipc-a.sock', { uid: 1234, tmpdir: '/tmp' });
  assert.equal(paths.runtimeDir, '/tmp/resume-claude-sessions-1234');
  assert.equal(paths.socketPath, `${paths.runtimeDir}/bridge-${paths.identity}.sock`);
  assert.ok(Buffer.byteLength(paths.socketPath) < 108);
});

test('missing window identity is rejected', () => {
  assert.throws(() => deriveIdentity(''), /VSCODE_IPC_HOOK_CLI/);
});
```

- [ ] **Step 2: Run the identity test and verify it fails**

Run: `node --test comate-bridge/test/identity.test.js`

Expected: FAIL with `Cannot find module '../lib/identity'`.

- [ ] **Step 3: Implement deterministic identity and private paths**

```js
// comate-bridge/lib/identity.js
'use strict';
const crypto = require('node:crypto');
const os = require('node:os');
const path = require('node:path');

function deriveIdentity(ipcHook) {
  if (typeof ipcHook !== 'string' || ipcHook.length === 0) {
    throw new Error('VSCODE_IPC_HOOK_CLI is required for exact-window routing');
  }
  return crypto.createHash('sha256').update(ipcHook).digest('hex').slice(0, 24);
}

function pathsFor(ipcHook, options = {}) {
  const uid = options.uid ?? process.getuid();
  const tmpdir = options.tmpdir ?? os.tmpdir();
  const identity = deriveIdentity(ipcHook);
  const runtimeDir = path.join(tmpdir, `resume-claude-sessions-${uid}`);
  return {
    identity,
    runtimeDir,
    socketPath: path.join(runtimeDir, `bridge-${identity}.sock`),
    metadataPath: path.join(runtimeDir, `bridge-${identity}.json`),
  };
}

module.exports = { deriveIdentity, pathsFor };
```

- [ ] **Step 4: Run the identity tests**

Run: `node --test comate-bridge/test/identity.test.js`

Expected: 3 tests pass, 0 fail.

- [ ] **Step 5: Add failing protocol tests**

```js
// comate-bridge/test/protocol.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const { validateRequest } = require('../lib/protocol');

const valid = () => ({
  version: 1,
  requestId: '0123456789abcdef0123456789abcdef',
  terminals: [{ name: 'resume: demo', cwd: '/tmp', command: "printf '%s\\n' ok" }],
});

test('accepts a valid request', () => assert.deepEqual(validateRequest(valid()), valid()));
test('rejects unsupported versions', () => {
  const value = valid(); value.version = 2;
  assert.throws(() => validateRequest(value), /version/);
});
test('rejects invalid terminal data before creation', () => {
  for (const patch of [
    { cwd: 'relative' },
    { name: 'bad\0name' },
    { command: 'bad\0command' },
  ]) {
    const value = valid(); Object.assign(value.terminals[0], patch);
    assert.throws(() => validateRequest(value));
  }
});
test('rejects more than 100 terminals', () => {
  const value = valid(); value.terminals = Array.from({ length: 101 }, () => valid().terminals[0]);
  assert.throws(() => validateRequest(value), /100/);
});
```

- [ ] **Step 6: Run the protocol tests and verify they fail**

Run: `node --test comate-bridge/test/protocol.test.js`

Expected: FAIL with `Cannot find module '../lib/protocol'`.

- [ ] **Step 7: Implement request validation and bounded framing**

Implement `comate-bridge/lib/protocol.js` with these exact rules:

```js
'use strict';
const path = require('node:path');
const fs = require('node:fs');
const MAX_BYTES = 1024 * 1024;
const MAX_TERMINALS = 100;

function plainString(value, field) {
  if (typeof value !== 'string' || value.length === 0 || value.includes('\0')) {
    throw new Error(`${field} must be a non-empty string without NUL bytes`);
  }
  return value;
}

function validateRequest(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('request must be an object');
  if (value.version !== 1) throw new Error('unsupported protocol version');
  if (!/^[a-f0-9]{32}$/.test(value.requestId || '')) throw new Error('invalid requestId');
  if (!Array.isArray(value.terminals) || value.terminals.length < 1 || value.terminals.length > MAX_TERMINALS) {
    throw new Error('terminals must contain 1 to 100 entries');
  }
  const terminals = value.terminals.map((terminal, index) => {
    const name = plainString(terminal.name, `terminals[${index}].name`);
    const cwd = plainString(terminal.cwd, `terminals[${index}].cwd`);
    const command = plainString(terminal.command, `terminals[${index}].command`);
    if (!path.isAbsolute(cwd) || !fs.statSync(cwd).isDirectory()) throw new Error(`invalid cwd: ${cwd}`);
    return { name, cwd, command };
  });
  return { version: 1, requestId: value.requestId, terminals };
}

function readJsonLine(socket, options = {}) {
  const maxBytes = options.maxBytes ?? MAX_BYTES;
  return new Promise((resolve, reject) => {
    let bytes = 0; const chunks = [];
    socket.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > maxBytes) { reject(new Error('request exceeds 1 MiB')); socket.destroy(); return; }
      chunks.push(chunk);
      const data = Buffer.concat(chunks);
      const newline = data.indexOf(0x0a);
      if (newline !== -1) {
        socket.pause();
        try { resolve(JSON.parse(data.subarray(0, newline).toString('utf8'))); }
        catch (error) { reject(new Error(`invalid JSON: ${error.message}`)); }
      }
    });
    socket.on('end', () => reject(new Error('connection closed before newline')));
    socket.on('error', reject);
  });
}

function writeJsonLine(socket, value) { socket.end(`${JSON.stringify(value)}\n`); }
module.exports = { MAX_BYTES, MAX_TERMINALS, validateRequest, readJsonLine, writeJsonLine };
```

- [ ] **Step 8: Run all Task 1 tests and commit**

Run: `npm --prefix comate-bridge test`

Expected: 7 tests pass, 0 fail.

```bash
git add comate-bridge/package.json comate-bridge/lib comate-bridge/test
git commit -m "Add Comate bridge identity and protocol"
```

---

### Task 2: Unix Socket Server And VS Code Terminal Adapter

**Files:**
- Create: `comate-bridge/lib/server.js`
- Create: `comate-bridge/extension.js`
- Create: `comate-bridge/test/server.test.js`

**Interfaces:**
- Consumes: `pathsFor`, `validateRequest`, `readJsonLine`, `writeJsonLine` from Task 1.
- Produces: `startServer({ ipcHook, createTerminal, logger }): Promise<{ close, paths }>`.
- Produces: VS Code `activate(context)` and `deactivate()` exports.

- [ ] **Step 1: Write failing server tests using a fake terminal adapter**

```js
// comate-bridge/test/server.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');
const { startServer } = require('../lib/server');

function request(socketPath, payload) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    let data = '';
    socket.on('connect', () => socket.write(`${JSON.stringify(payload)}\n`));
    socket.on('data', chunk => { data += chunk; });
    socket.on('end', () => resolve(JSON.parse(data)));
    socket.on('error', reject);
  });
}

const payload = () => ({ version: 1, requestId: 'a'.repeat(32), terminals: [
  { name: 'one', cwd: '/tmp', command: 'printf one' },
  { name: 'two', cwd: '/tmp', command: 'printf two' },
] });

test('creates only requested terminals and returns their count', async t => {
  const tmpdir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-test-'));
  const created = [];
  const server = await startServer({ ipcHook: '/tmp/test-window', tmpdir, uid: 42,
    createTerminal: async descriptor => created.push(descriptor), logger: { info() {}, error() {} } });
  t.after(async () => { await server.close(); fs.rmSync(tmpdir, { recursive: true, force: true }); });
  const response = await request(server.paths.socketPath, payload());
  assert.equal(response.created, 2);
  assert.deepEqual(created, payload().terminals);
});

test('malformed request creates no terminals', async t => {
  const tmpdir = fs.mkdtempSync(path.join(os.tmpdir(), 'bridge-test-'));
  const created = [];
  const server = await startServer({ ipcHook: '/tmp/test-window-2', tmpdir, uid: 43,
    createTerminal: async descriptor => created.push(descriptor), logger: { info() {}, error() {} } });
  t.after(async () => { await server.close(); fs.rmSync(tmpdir, { recursive: true, force: true }); });
  const bad = payload(); bad.terminals[0].cwd = 'relative';
  const response = await request(server.paths.socketPath, bad);
  assert.equal(response.created, 0);
  assert.equal(created.length, 0);
  assert.match(response.errors[0], /cwd/);
});
```

- [ ] **Step 2: Run the server tests and verify they fail**

Run: `node --test comate-bridge/test/server.test.js`

Expected: FAIL with `Cannot find module '../lib/server'`.

- [ ] **Step 3: Implement the socket server**

`comate-bridge/lib/server.js` must:

- create the runtime directory recursively and `chmod 0700`;
- derive only the exact window's socket path;
- probe an existing socket before removing it as stale;
- write metadata `{ version: 1, pid, identity, ipcHookHash: identity }` with mode `0600`;
- validate the entire request before calling `createTerminal`;
- create terminals sequentially, collect per-terminal errors, and never resend;
- remove only its own socket and metadata on `close()`.

Core request handler:

```js
const raw = await readJsonLine(socket);
const request = validateRequest(raw);
let created = 0; const errors = [];
for (const terminal of request.terminals) {
  try { await createTerminal(terminal); created += 1; }
  catch (error) { errors.push(`${terminal.name}: ${error.message}`); }
}
writeJsonLine(socket, { version: 1, requestId: request.requestId, created, errors });
```

Invalid requests return:

```js
writeJsonLine(socket, {
  version: 1,
  requestId: /^[a-f0-9]{32}$/.test(raw?.requestId || '') ? raw.requestId : null,
  created: 0,
  errors: [error.message],
});
```

- [ ] **Step 4: Run server tests**

Run: `node --test comate-bridge/test/server.test.js`

Expected: 2 tests pass, 0 fail.

- [ ] **Step 5: Implement the VS Code adapter without touching existing terminals**

```js
// comate-bridge/extension.js
'use strict';
const vscode = require('vscode');
const { startServer } = require('./lib/server');
let bridge;

async function activate(context) {
  const ipcHook = process.env.VSCODE_IPC_HOOK_CLI;
  if (!ipcHook) {
    console.error('[resume-bridge] exact-window identity unavailable; bridge disabled');
    return;
  }
  bridge = await startServer({
    ipcHook,
    createTerminal: async ({ name, cwd, command }) => {
      const terminal = vscode.window.createTerminal({ name, cwd });
      terminal.sendText(command, true);
      terminal.show(false);
    },
    logger: console,
  });
  context.subscriptions.push({ dispose: () => bridge?.close() });
}

async function deactivate() { if (bridge) await bridge.close(); }
module.exports = { activate, deactivate };
```

Do not read `vscode.window.terminals`, call `dispose()` on a terminal, pass `location`, or execute reload commands.

- [ ] **Step 6: Add source-safety assertions**

Extend `comate-bridge/test/server.test.js`:

```js
test('extension never manipulates pre-existing terminals or split locations', () => {
  const source = fs.readFileSync(path.join(__dirname, '..', 'extension.js'), 'utf8');
  for (const forbidden of ['window.terminals', '.dispose(', 'location:', 'reloadWindow', '--reuse-window']) {
    assert.equal(source.includes(forbidden), false, `forbidden extension API: ${forbidden}`);
  }
  assert.match(source, /createTerminal\(\{ name, cwd \}\)/);
});
```

- [ ] **Step 7: Run extension tests and commit**

Run: `npm --prefix comate-bridge test`

Expected: all tests pass, 0 fail.

```bash
git add comate-bridge/extension.js comate-bridge/lib/server.js comate-bridge/test/server.test.js
git commit -m "Add exact-window Comate terminal bridge server"
```

---

### Task 3: Python Bridge Client

**Files:**
- Create: `bridge/comate_bridge_client.py`
- Create: `tests/test_comate_bridge_client.py`

**Interfaces:**
- Consumes: the Task 1 socket-path algorithm and Task 2 protocol.
- Produces: `socket_paths(ipc_hook, uid=None, tmpdir=None)`.
- Produces: `probe(ipc_hook, timeout=0.25) -> dict`.
- Produces: `send_request(ipc_hook, terminals, timeout=2.0) -> dict`.
- CLI: `probe` and `send-input0`; exit 0 on success, 2 when unavailable/invalid.

- [ ] **Step 1: Write failing Python unit tests**

```python
# tests/test_comate_bridge_client.py
import hashlib
import os
import socket
import tempfile
import threading
import unittest
from pathlib import Path

from bridge.comate_bridge_client import build_terminals, socket_paths

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

if __name__ == "__main__": unittest.main()
```

- [ ] **Step 2: Run tests and verify they fail**

Run: `python3 -m unittest -v tests.test_comate_bridge_client`

Expected: FAIL with `ModuleNotFoundError: No module named 'bridge.comate_bridge_client'`.

- [ ] **Step 3: Implement exact-window path derivation and input0 parsing**

Use a `SocketPaths` dataclass. `build_terminals(data)` parses six NUL-delimited fields per terminal:

```text
kind, name, cwd, executable, session_id_or_empty, skip_permissions_0_or_1
```

Supported kinds:

- `resume`: command is `shlex.join([executable, '--resume', session_id] + optional dangerous flag)`.
- `cli`: command is `shlex.join([executable])`.

Reject unknown kinds, missing fields, embedded empty names/cwds/executables, and more than 100 records.

- [ ] **Step 4: Implement bounded socket probe and send**

`send_request` must:

```python
request = {
    "version": 1,
    "requestId": secrets.token_hex(16),
    "terminals": terminals,
}
```

Connect only to the path derived from the supplied `ipc_hook`, set a two-second timeout, send one compact JSON line, read at most 1 MiB through the first newline, and verify version/requestId/created/errors. Never retry a sent request.

`probe` sends one syntactically valid request with a reserved empty operation is not allowed by the terminal protocol, so probe by connecting and validating metadata instead: read the adjacent mode-0600 metadata file, verify version and identity, then connect and close without sending. The server must tolerate an empty connection without creating a terminal.

- [ ] **Step 5: Add a fake-server success and timeout test**

Add tests using a temporary Unix socket server that:

- reads one line;
- echoes the request ID with `created == len(terminals)`;
- verifies `send_request` returns that response;
- verifies a server that accepts but never replies raises `BridgeUnavailable` after a 50 ms test timeout;
- verifies the client sends only once.

- [ ] **Step 6: Run Python tests and commit**

Run: `python3 -m unittest -v tests.test_comate_bridge_client`

Expected: all tests pass, 0 errors, 0 failures.

```bash
git add bridge/comate_bridge_client.py tests/test_comate_bridge_client.py
git commit -m "Add exact-window Comate bridge client"
```

---

### Task 4: Package And Install Without Reloading

**Files:**
- Create: `scripts/package-comate-bridge.py`
- Create: `scripts/install-comate-bridge.sh`
- Create: `tests/test_package_comate_bridge.py`
- Create: `comate-bridge/README.md`

**Interfaces:**
- Produces: `dist/resume-claude-sessions-bridge-0.1.0.vsix`.
- Produces: explicit installer command `scripts/install-comate-bridge.sh`.

- [ ] **Step 1: Write a failing VSIX structure test**

```python
# tests/test_package_comate_bridge.py
import subprocess
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VSIX = ROOT / "dist/resume-claude-sessions-bridge-0.1.0.vsix"

class PackageTests(unittest.TestCase):
    def test_vsix_contains_required_files(self):
        subprocess.run(["python3", "scripts/package-comate-bridge.py"], cwd=ROOT, check=True)
        with zipfile.ZipFile(VSIX) as archive:
            names = set(archive.namelist())
        self.assertIn("extension.vsixmanifest", names)
        self.assertIn("[Content_Types].xml", names)
        self.assertIn("extension/package.json", names)
        self.assertIn("extension/extension.js", names)
        self.assertIn("extension/lib/server.js", names)

if __name__ == "__main__": unittest.main()
```

- [ ] **Step 2: Run the packaging test and verify it fails**

Run: `python3 -m unittest -v tests.test_package_comate_bridge`

Expected: FAIL because `scripts/package-comate-bridge.py` does not exist.

- [ ] **Step 3: Implement deterministic VSIX packaging**

`scripts/package-comate-bridge.py` must use only `json`, `pathlib`, and `zipfile`; read version/name/publisher from `comate-bridge/package.json`; write static `extension.vsixmanifest` and `[Content_Types].xml`; include only `package.json`, `README.md`, `extension.js`, and `lib/*.js`; sort entries and use a fixed ZIP timestamp for reproducibility.

Do not package tests, sockets, metadata, credentials, workspace files, or user settings.

- [ ] **Step 4: Run packaging test**

Run: `python3 -m unittest -v tests.test_package_comate_bridge`

Expected: 1 test passes.

- [ ] **Step 5: Implement the explicit no-reload installer**

`scripts/install-comate-bridge.sh` must:

```bash
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
python3 "$ROOT/scripts/package-comate-bridge.py"
```

Then detect the CLI using the same safe lookup as `resume-claude-sessions.sh` and execute only:

```bash
"$COMATE_CLI" --install-extension "$VSIX" --force
```

It must print:

```text
扩展已安装；未重载任何窗口。请在下次自然重启 Comate 后使用当前窗口追加终端。
```

It must not invoke `-r`, `--reuse-window`, `-n`, reload commands, or the generated workspace.

- [ ] **Step 6: Add an installer source-safety test**

Extend `tests/test_package_comate_bridge.py` to read the installer and assert these fixed strings are absent: `--reuse-window`, ` -r `, `reloadWindow`, `workbench.action.reloadWindow`; assert `--install-extension` and `--force` are present.

- [ ] **Step 7: Run tests and commit**

Run:

```bash
python3 -m unittest -v tests.test_package_comate_bridge
npm --prefix comate-bridge test
```

Expected: all tests pass.

```bash
git add comate-bridge/README.md scripts/package-comate-bridge.py scripts/install-comate-bridge.sh tests/test_package_comate_bridge.py
git commit -m "Package Comate bridge without window reload"
```

---

### Task 5: Bridge-First Shell Integration With New-Window Fallback

**Files:**
- Modify: `resume-claude-sessions.sh:485-560`
- Create: `tests/test_launcher_safety.py`

**Interfaces:**
- Consumes: `bridge/comate_bridge_client.py probe|send-input0`.
- Produces: `launch_vscode_bridge()` returning success only after a validated bridge response.
- Preserves: `launch_vscode_new_window()` as the only fallback.

- [ ] **Step 1: Write failing shell source-safety tests**

```python
# tests/test_launcher_safety.py
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "resume-claude-sessions.sh"

class LauncherSafetyTests(unittest.TestCase):
    def test_never_reuses_or_reloads_current_window(self):
        source = SOURCE.read_text()
        for forbidden in ["RESUME_VSCODE_REUSE", "--reuse-window", '"$cli" -r', "reloadWindow"]:
            self.assertNotIn(forbidden, source)

    def test_new_window_is_the_only_comate_fallback(self):
        source = SOURCE.read_text()
        self.assertIn('"$cli" -n "$wsfile"', source)

    def test_bridge_client_is_attempted_before_new_window(self):
        source = SOURCE.read_text()
        self.assertLess(source.index("launch_vscode_bridge"), source.index("launch_vscode_new_window"))
        self.assertIn("launch_vscode_bridge || launch_vscode_new_window", source)

if __name__ == "__main__": unittest.main()
```

- [ ] **Step 2: Run the launcher safety tests and verify they fail**

Run: `python3 -m unittest -v tests.test_launcher_safety`

Expected: FAIL because bridge/new-window functions are not separated yet.

- [ ] **Step 3: Extract the existing workspace launcher as a fixed `-n` fallback**

Rename the current `.code-workspace` implementation to `launch_vscode_new_window`. Preserve:

```bash
"$cli" -n "$wsfile"
```

Remove any configurable reuse flag. The fallback must continue to root the workspace at `/root/paddlejob/workspace/env_run/penghaotian` and keep tasks independent by omitting `presentation.group`.

- [ ] **Step 4: Implement bridge request generation without shell JSON**

Add:

```bash
launch_vscode_bridge() {
  local client="$SCRIPT_DIR/bridge/comate_bridge_client.py" ipc="${VSCODE_IPC_HOOK_CLI:-}"
  [ -n "$ipc" ] && [ -f "$client" ] || return 1
  python3 "$client" probe --ipc-hook "$ipc" >/dev/null 2>&1 || return 1

  {
    local i dangerous=0
    [ "${RESUME_SKIP_PERMISSIONS:-0}" = "1" ] && dangerous=1
    for i in "${chosen_idx[@]}"; do
      printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
        resume "resume: ${sel_name[$i]} [${sel_time[$i]}]" "${sel_cwd[$i]}" \
        "$CLAUDE_CMD" "${sel_id[$i]}" "$dangerous"
      if [ "${sel_cli[$i]}" = "1" ]; then
        printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
          cli "cli: ${sel_name[$i]}" "${sel_cwd[$i]}" "${SHELL:-/bin/bash}" '' 0
      fi
    done
  } | python3 "$client" send-input0 --ipc-hook "$ipc"
}

launch_vscode() {
  launch_vscode_bridge || launch_vscode_new_window
}
```

The client writes errors to stderr. Once `send-input0` has sent a request, it must return a distinct exit code for “delivery uncertain”; the shell must not retry or fall back in that case because doing so could duplicate terminals. Use exit codes:

- `0`: bridge completed successfully;
- `2`: bridge unavailable before send, safe to open a new window;
- `3`: request may have been delivered, do not retry or fall back;
- `4`: bridge returned terminal creation errors, report them and do not duplicate.

Therefore implement the wrapper with explicit status handling rather than a bare `||`:

```bash
launch_vscode() {
  launch_vscode_bridge; local status=$?
  case "$status" in
    0) return 0 ;;
    2) launch_vscode_new_window ;;
    3|4) return "$status" ;;
    *) echo "bridge 客户端内部错误（$status），未启动备用窗口以避免重复终端。" >&2; return "$status" ;;
  esac
}
```

Update the source test to assert these four exit-code branches exactly and remove its earlier `launch_vscode_bridge || launch_vscode_new_window` assertion.

- [ ] **Step 5: Add subprocess tests with a fake bridge client**

Extend `tests/test_launcher_safety.py` with a test harness that copies the shell script to a temporary directory, provides a fake `bridge/comate_bridge_client.py`, sets `RESUME_AUTO_SELECT=1`, and intercepts the Comate CLI. Assert:

- client exit 0: bridge path runs and Comate CLI is never invoked;
- probe exit 2: fallback invokes Comate with exactly `-n` and the workspace path;
- send exit 3: Comate CLI is never invoked;
- records include the selected session cwd and dangerous flag `0` by default.

Do not run the real Comate CLI in unit tests.

- [ ] **Step 6: Run shell and client tests**

Run:

```bash
bash -n resume-claude-sessions.sh
python3 -m unittest -v tests.test_launcher_safety tests.test_comate_bridge_client
```

Expected: syntax valid; all tests pass; fake CLI records no `-r` invocation.

- [ ] **Step 7: Commit shell integration**

```bash
git add resume-claude-sessions.sh tests/test_launcher_safety.py
git commit -m "Append sessions through exact-window Comate bridge"
```

---

### Task 6: Isolated New-Window Integration Test And Documentation

**Files:**
- Create: `scripts/test-comate-bridge-window.sh`
- Modify: `README.md`
- Modify: `.gitignore` if generated VSIX/workspace artifacts are not already ignored.

**Interfaces:**
- Consumes: installed extension, Python client, exact-window metadata, and Comate CLI.
- Produces: a guarded test procedure that never targets the original window.

- [ ] **Step 1: Add a failing safety test for the integration script**

Extend `tests/test_launcher_safety.py`:

```python
def test_integration_test_opens_new_window_and_excludes_original_identity(self):
    source = (SOURCE.parent / "scripts/test-comate-bridge-window.sh").read_text()
    self.assertIn('"$COMATE_CLI" -n "$TEST_DIR"', source)
    self.assertIn('ORIGINAL_IDENTITY=', source)
    self.assertIn('if [ "$candidate" = "$ORIGINAL_SOCKET" ]; then continue; fi', source)
    for forbidden in [' --reuse-window ', ' -r ', 'reloadWindow']:
        self.assertNotIn(forbidden, source)
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `python3 -m unittest -v tests.test_launcher_safety.LauncherSafetyTests.test_integration_test_opens_new_window_and_excludes_original_identity`

Expected: FAIL because the integration script does not exist.

- [ ] **Step 3: Implement the guarded test-window script**

The script must:

1. Require `--i-understand-this-opens-a-new-test-window`.
2. Derive and record `ORIGINAL_IDENTITY` and `ORIGINAL_SOCKET` from the invoking terminal before opening anything.
3. Create a temporary workspace containing a marker file and settings that enable the installed extension.
4. Execute only `"$COMATE_CLI" -n "$TEST_DIR"`.
5. Poll the private runtime directory for a newly created bridge socket whose path differs from `ORIGINAL_SOCKET`.
6. Refuse to proceed unless exactly one new live socket appears.
7. Send the test request with an explicit `--socket "$TEST_SOCKET"` override supported only by the test command, not normal launcher flow.
8. Create two harmless independent terminals:

```text
bridge-test-identity: print VSCODE_IPC_HOOK_CLI to $TEST_DIR/terminal-ipc.txt, then exec bash
bridge-test-second: printf 'bridge second terminal ready\n', then exec bash
```

9. Compare the terminal-reported IPC hash with the test socket identity.
10. Print verification results and leave the test window open for user inspection.
11. Never close a Comate window automatically.

The explicit socket override must require both `--test-mode` and a socket beneath the current user's private runtime directory; normal `send-input0` must not expose it.

- [ ] **Step 4: Document setup and safety behavior**

Add README sections with exact commands:

```bash
./scripts/install-comate-bridge.sh
# No window is reloaded. Restart Comate naturally when convenient.

bash resume-claude-sessions.sh
```

Document:

- bridge available: append independent terminals to the invoking window;
- bridge unavailable: open a separate window rooted at `penghaotian`;
- existing terminals are never manipulated;
- isolated test command and its explicit guard flag;
- `RESUME_SKIP_PERMISSIONS=1` remains explicit opt-in only;
- generated `resume-sessions.code-workspace` is overwritten and contains no secrets.

- [ ] **Step 5: Run the full offline verification suite**

Run:

```bash
npm --prefix comate-bridge test
python3 -m unittest discover -s tests -v
bash -n resume-claude-sessions.sh scripts/install-comate-bridge.sh scripts/test-comate-bridge-window.sh
rg -n --fixed-strings -- '--reuse-window' resume-claude-sessions.sh scripts comate-bridge && exit 1 || true
rg -n 'reloadWindow|window\.terminals|\.dispose\(' resume-claude-sessions.sh scripts comate-bridge && exit 1 || true
```

Expected: all Node and Python tests pass, Bash syntax checks pass, forbidden-pattern scans return no matches.

- [ ] **Step 6: Install without reloading and stop for safety review**

Run:

```bash
./scripts/install-comate-bridge.sh
```

Expected: installation succeeds and prints that no window was reloaded. Do not open or reload the current window. Verify the current necessary terminals remain by asking the user, not by manipulating them.

- [ ] **Step 7: Open and test only a new test window after explicit confirmation**

Run only after confirming the user is ready:

```bash
./scripts/test-comate-bridge-window.sh --i-understand-this-opens-a-new-test-window
```

Expected: one new Comate test window opens, two independent test terminals appear there, the original window remains untouched, and the test window stays open for inspection.

- [ ] **Step 8: Commit documentation and integration test**

```bash
git add README.md .gitignore scripts/test-comate-bridge-window.sh tests/test_launcher_safety.py
git commit -m "Document and test safe Comate bridge workflow"
```

- [ ] **Step 9: Final verification before integration**

Run:

```bash
git status --short
npm --prefix comate-bridge test
python3 -m unittest discover -s tests -v
bash -n resume-claude-sessions.sh scripts/*.sh
```

Expected: only intentionally untracked local `.claude/` or `.vscode/` files remain; all tests pass with zero failures; all shell files parse successfully.
