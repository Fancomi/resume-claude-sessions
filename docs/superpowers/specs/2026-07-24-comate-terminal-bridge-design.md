# Comate Current-Window Terminal Bridge Design

## Goal

Allow `resume-claude-sessions.sh` to append multiple independent terminals to the exact Comate window containing the invoking terminal. Existing windows, terminals, editors, and window-local state must remain unchanged.

The bridge must never reload, reuse, replace, or close the invoking window. Extension installation must not trigger a reload. Integration testing must use a separately opened test window.

## Constraints

- Comate 3.1.1 exposes no CLI command for creating an integrated terminal or invoking an arbitrary workbench command.
- Its `--open-url` option is explicitly unsupported, so a URI handler cannot be the transport.
- `tasks.json` with `runOn: folderOpen` requires opening or reloading a folder/workspace and therefore cannot append terminals to an unchanged existing window.
- Multiple Comate windows may be open. A global queue or shared request file cannot reliably identify the invoking window.
- The current window may contain necessary long-running terminals. Tests and fallback behavior must not alter them.

## Architecture

The feature has three components:

1. **Comate bridge extension**
   - A small local extension installed into Comate's extension directory.
   - Activates on startup in each extension host.
   - Creates one Unix-domain socket per Comate window.
   - Accepts validated requests and calls the public `vscode.window.createTerminal()` API.

2. **Shell bridge client**
   - Added to `resume-claude-sessions.sh`.
   - Detects whether the bridge for the invoking window is ready.
   - Sends selected session descriptors as one JSON request.
   - Falls back to the existing new-window workspace launcher if no bridge is available.

3. **Protocol helper**
   - A small Python helper used by the shell script for JSON encoding, socket transport, bounded timeouts, and response validation.
   - Avoids ad hoc shell JSON escaping and keeps the transport testable without Comate.

## Exact-Window Routing

The terminal environment contains `VSCODE_IPC_HOOK_CLI`, whose value identifies the Comate window's IPC endpoint. The extension host is expected to inherit the same environment value.

Both sides derive a bridge socket name from:

```text
sha256(VSCODE_IPC_HOOK_CLI)[0:24]
```

The socket lives under a private runtime directory owned by the current user, with permissions that prevent other users from sending requests. The extension writes an adjacent metadata file containing its process ID and protocol version.

Before implementation, an integration probe in a new test window must verify that the extension host and integrated terminal observe the same `VSCODE_IPC_HOOK_CLI` value. If this assumption is false, implementation must stop and use a different per-window token design; it must not fall back to a global socket.

## Request Protocol

One newline-delimited JSON request is sent per invocation:

```json
{
  "version": 1,
  "requestId": "random-128-bit-hex",
  "terminals": [
    {
      "name": "resume: project-name [07-24 09:00]",
      "cwd": "/absolute/session/path",
      "command": "/absolute/path/to/claude --resume SESSION_ID"
    }
  ]
}
```

The extension replies with one JSON object:

```json
{
  "version": 1,
  "requestId": "same-id",
  "created": 3,
  "errors": []
}
```

Limits:

- Maximum request size: 1 MiB.
- Maximum terminals per request: 100.
- `cwd` must be absolute and exist as a directory.
- `name`, `cwd`, and `command` must be strings without NUL bytes.
- The client connect/read timeout is two seconds.
- Protocol/version mismatch is a hard bridge failure and triggers the safe fallback.

## Terminal Creation

For each descriptor, the extension calls:

```ts
const terminal = vscode.window.createTerminal({ name, cwd });
terminal.sendText(command, true);
terminal.show(false);
```

No `location` or split-parent option is supplied. Each created terminal is therefore an independent top-level terminal rather than a split/child terminal.

The extension must not enumerate, dispose, hide, rename, reuse, or send text to any pre-existing terminal. It only retains references to terminals created for the current request long enough to report success.

Each session's command retains its own session working directory. The Comate window's workspace root remains `/root/paddlejob/workspace/env_run/penghaotian` when that is the current workspace; appending terminals does not change the workspace.

## Installation And Activation

The script may build and install the extension files, but it must not execute any of the following against the current window:

- `comate -r` / `--reuse-window`
- reload-window commands
- workspace or folder replacement
- extension-host restart commands

After first installation, the script reports that the bridge will become available after the user's next natural Comate restart. Until then, it uses the safe new-window fallback.

No automatic installation occurs without an explicit setup command or explicit user approval.

## Fallback

If the current window's exact bridge socket is absent, stale, mismatched, unreachable, or returns an invalid response:

1. Do not retry by reloading or reusing the current window.
2. Do not send to another window's bridge.
3. Log a concise reason.
4. Use the existing `comate -n resume-sessions.code-workspace` launcher.

The fallback always opens a separate window and never changes the invoking window.

## Failure Handling

- The extension removes a stale socket only when it can prove that the socket belongs to the same derived window identity and no live listener responds.
- A malformed request is rejected before any terminal is created.
- If creation fails partway through, already-created terminals remain and the response lists failures. Existing terminals remain untouched.
- If the client loses the response after sending, it must not automatically resend because that could duplicate terminals.
- Sensitive request data is not written to logs. Session IDs may appear in process command lines as they do in the existing launcher.

## Testing

### Offline tests

- Socket-name derivation is deterministic and differs between window IPC values.
- Request encoding correctly handles spaces, quotes, Unicode paths, and shell metacharacters.
- Protocol validation rejects malformed JSON, relative/nonexistent paths, NUL bytes, oversized requests, and unsupported versions.
- Client timeout and invalid-response paths choose the new-window fallback.
- Source checks ensure there is no `-r`, `--reuse-window`, reload command, or existing-terminal disposal logic.

### Isolated Comate integration test

1. Preserve the current window and record its existing terminal count only by user observation; do not query or manipulate it.
2. Open a separate test window with `comate -n` rooted at a temporary test workspace.
3. Activate the bridge extension only in that test window.
4. Verify the extension host and test terminal derive the same window identity.
5. Send a test request that creates two harmless terminals running commands such as `printf` followed by an interactive shell.
6. Verify the two terminals are independent top-level terminals and existing test-window terminals remain present.
7. Close only the test window after explicit user approval or leave it open for inspection.
8. Never send a bridge request to the original window during testing.

## Success Criteria

- Running the resumer from an extension-enabled Comate window appends all selected sessions as independent terminals in that exact window.
- Existing terminals and window state are unchanged.
- No window is reloaded, replaced, or reused by CLI.
- First installation does not reload the current window.
- Tests operate only in a newly opened test window.
- If exact-window routing cannot be proven, the bridge refuses to run and safely opens a separate window instead.
