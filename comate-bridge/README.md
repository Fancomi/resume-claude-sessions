# Resume Claude Sessions Bridge

A VS Code / Comate extension that lets the `resume-claude-sessions` launcher
create integrated terminals in an **already-open** window, instead of opening
a new window or reusing/reloading the current one.

## Why

The launcher has no CLI way to inject terminals into a running VS Code /
Comate window. This extension exposes a local, per-window Unix domain socket
that a companion Python client (`bridge/comate_bridge_client.py`) connects to
and asks to create one or more terminals (each running a `claude --resume
<session-id>` or a plain shell command).

## How it works

- On activation, the extension derives a deterministic identity from
  `VSCODE_IPC_HOOK_CLI` (the same environment variable VS Code/Comate uses to
  address this exact window) and listens on a socket named after that
  identity under a per-user runtime directory.
- A JSON-line protocol (one JSON object per line) is used to request
  terminal creation and receive a `created`/`errors` summary.
- The extension never reloads the window, reuses another window, or opens a
  workspace — it only calls `vscode.window.createTerminal(...)` for the
  window it is already running in.

## Files

- `extension.js` — activation entry point; wires the socket server to
  `vscode.window.createTerminal`.
- `lib/identity.js` — derives the socket/metadata paths from the window's
  IPC hook.
- `lib/protocol.js` — JSON-line request validation and framing.
- `lib/server.js` — the per-window Unix domain socket server.

## Installing without a window reload

Use `scripts/install-comate-bridge.sh`, which packages the extension
deterministically and installs it with `--install-extension ... --force`
only. It never passes `-r`/`--reuse-window`, `-n`, or triggers any reload
command. The newly installed extension activates the next time Comate
starts naturally (e.g. its next window/process restart) — not via any
forced reload from this installer.
