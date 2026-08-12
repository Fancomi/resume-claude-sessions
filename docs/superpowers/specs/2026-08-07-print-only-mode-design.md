# Print-Only Launch Mode Design

## Goal

Add a launch mode to `resume-claude-sessions.sh` that selects sessions exactly as
today but launches nothing. Instead it prints, one per selected session, a
ready-to-paste shell command. The user pastes each line into whichever existing
terminal they choose.

This exists because VSCode/Comate cannot attach a terminal to an already-open
window except through the Comate bridge, which requires a confirmed pairing and
an installed extension. When the bridge is unavailable, today's only fallback
opens a brand-new window. Print mode makes the human the transport: no window is
opened, no terminal is created, and the user keeps full control over where each
session lands.

## Constraints

- The selection UI (GUI / TUI / plain fallback) must not change. Checkbox state,
  `Gn` window-group numbers, and `+CLI` toggles are all still selectable, and
  the group number still determines print ordering even though no window is
  created.
- `stdout` must carry only the commands, so `> cmds.txt` and `| xclip` produce a
  clean, paste-ready file with no ANSI escapes.
- Permission behavior is unchanged: `--dangerously-skip-permissions` appears in
  a printed command only when `RESUME_SKIP_PERMISSIONS=1`.
- Nothing may execute a resume command, write `resume-sessions.code-workspace`,
  contact the bridge client, or invoke the Comate/VSCode CLI.
- The script has no argument parsing and is configured entirely through
  environment variables; print mode follows that existing convention.

## Activation

`RESUME_FORCE_LAUNCH=print`.

`detect_launch()` already returns `$RESUME_FORCE_LAUNCH` verbatim when it is
set, so no change is needed there — `print` is never auto-detected, only
requested. The dispatcher `case "$LAUNCH_MODE"` gains a `print) launch_print ;;`
arm.

Rejected alternatives: a separate `RESUME_PRINT_ONLY=1` flag (a second,
overlapping switch for something that is simply another launch target), and a
`--print` argument (would introduce the script's first argument parser for one
option).

## Output Channel

`stdout` is reserved for commands. Everything else — the TUI, prompts, the usage
hint, `已取消。` — goes to the controlling terminal.

Immediately after `LAUNCH_MODE` is computed and before any selection runs:

```bash
if [ "$LAUNCH_MODE" = "print" ]; then
  exec 3>&1                                   # fd 3 = the real stdout
  if { : >/dev/tty; } 2>/dev/null; then
    exec 1>/dev/tty
  else
    exec 1>&2
  fi
fi
```

Redirecting fd 1 wholesale, rather than editing every `printf` in the selection
code, keeps the UI code untouched. `launch_print` writes to `>&3`.

The `{ : >/dev/tty; } 2>/dev/null` probe runs *before* the `exec`: a failing
`exec` redirection in a non-interactive shell terminates the script. With no
controlling terminal the UI falls back to stderr and `stdout` stays clean.

Accepted consequences:

- `select_tui`'s `[ -t 1 ]` guard now tests the tty rather than the original
  stdout, so `RESUME_FORCE_LAUNCH=print ./resume-claude-sessions.sh > cmds.txt`
  still gets the full interactive TUI. This is the desired behavior.
- `RESUME_DRY_RUN=1` continues to take precedence over the dispatcher, and its
  summary goes to the tty rather than to `stdout`. Dry-run is a debugging
  switch; combining it with print mode is not a supported workflow and is
  documented as such rather than special-cased.

## Printed Format

`launch_print` iterates `chosen_groups` in first-seen order and, within each
group, the group's members in `chosen_idx` order (the picker's display order,
newest session first), so commands destined for what would have been one window
are adjacent. A session's `+CLI` command immediately follows that session's
resume command.

Each entry is exactly two lines — a comment then a command — and entries are
separated by one blank line. The comment is `# G<group>␠␠<label>`. There is no
leading blank line and no trailing blank line, so the whole block ends with a
single newline after the last command:

```text
# G0  resume: penghaotian [07-28 19:09]
cd '/root/paddlejob/workspace/env_run/penghaotian' && claude --resume 3f2a…c1

# G0  cli: penghaotian
cd '/root/paddlejob/workspace/env_run/penghaotian'
```

The comment reuses the same label text as the bridge and workspace paths
(`resume: <name> [<time>]`, `cli: <name>`) prefixed with the group number. The
resume command reuses `resume_cmd`, so the permission flag rule holds
automatically. `resume_cmd` echoes a single interpolated string ending in
`$RESUME_FLAGS`, which leaves exactly one trailing space when flags are empty, so
`launch_print` strips it (`cmd="${cmd% }"`) and no printed line ends in
whitespace. The `+CLI` entry is a bare `cd` — no `exec $SHELL`, since the user is
already sitting in the shell they pasted into.

## Quoting

Single-quote escaping for `cwd` is extracted into a `shquote()` helper:

```bash
shquote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
```

Verified round-trip: `a'b` → `'a'\''b'`, which `eval` returns to `a'b`; spaces
and `$` in paths survive unchanged.

`launch_vscode_new_window`'s existing inline `'${sel_cwd[$i]//\'/\'\\\'\'}'`
expansions are switched to call it. Same semantics, one implementation.

## Usage Hint

Before printing, `launch_print` writes a one-line hint to the tty (not to
`stdout`) telling the user to paste the lines one at a time into the terminals
they want.

The screen is cleared first only when the full-screen TUI actually drew — that
is the one case where a leftover frame would sit interleaved with the commands
being copied. `select_tui` sets a `TUI_DREW=1` flag for this purpose. The GUI
picker (separate window), the plain non-TTY fallback (whose scrollback the user
may still want), and `RESUME_AUTO_SELECT=1` (which draws nothing, and where
clearing an automated caller's screen would be hostile) never clear. When fd 1
is not a tty the clear is skipped regardless.

## Testing

A `LauncherPrintModeTests` class in `tests/test_launcher_safety.py`, reusing the
existing `_make_sandbox` / `_run` harness (fake bridge client, fake `comate`,
fake `claude`, temp projects root) with `RESUME_FORCE_LAUNCH=print`:

- `stdout` equals the expected comment-plus-command block exactly, contains no
  ESC byte, and every command line is a `cd '<cwd>' && ` prefix followed by a
  resume invocation.
- The fake bridge client received nothing (`bridge_input0.bin` absent), the fake
  `comate` was never invoked (`comate_calls.txt` absent), and
  `resume-sessions.code-workspace` was not written.
- With `RESUME_SKIP_PERMISSIONS=1` the printed command contains
  `--dangerously-skip-permissions`; without it, it does not.

A source-level assertion confirms the print dispatcher arm exists and that
`launch_print` contains no call to `launch_vscode_bridge`,
`launch_vscode_new_window`, `tmux`, or `osascript`.

## Documentation

`README.md` gains `RESUME_FORCE_LAUNCH=print` to the environment-variable table
and a short section showing the invocation, sample output, and the
`> cmds.txt` / `| xclip` redirection cases.
