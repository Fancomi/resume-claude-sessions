#!/usr/bin/env bash
# Resume sessions — one unified launcher for Claude Code and Codex.
#
# Entered through resume-claude-sessions.sh / resume-codex-sessions.sh (thin
# wrappers that set RESUME_PROVIDER); run this file directly with
# RESUME_PROVIDER=claude|codex if you prefer.
#
# Works on:  GUI Ubuntu · headless Ubuntu/CentOS · GUI macOS  (+VSCode remote)
#
# Picker (same on every platform — zero deps, pure bash checkbox TUI, mirrors
# the Windows GUI): sessions grouped by date (newest first), newest date group
# ticked by default. Per row you control:
#     [✔] Open      SPACE toggles          (on a date header: toggle whole group)
#     Gn  Group     g = set window-group   (same Gn  = one window, many tabs)
#     +CLI          c = attach an extra shell tab for running commands
# Keys: ↑/↓ or j/k move · SPACE toggle · a all · n none · g group · c cli
#       ENTER confirm · q quit
#
# DEFAULT: Claude -> print, launch nothing. Pick sessions as usual, then get one
# paste-ready command per session on stdout (grouped by Gn) — paste each into
# whichever terminal you want it in. Launching is opt-in because no launcher can
# put a session in a terminal you already have open; they all make new ones.
# The picker draws on /dev/tty, so `> cmds.txt` / `| xclip` stay clean.
# Codex keeps the upstream default: auto-detect the platform and launch.
# Force either with RESUME_FORCE_LAUNCH=print|auto|terminal|vscode|tmux|seq.
#
# Launch modes (`auto` picks one):
#   * macOS   -> one Terminal.app WINDOW per group, one TAB per session
#                (+CLI = extra tab). Tabs need Accessibility perm; else windows.
#   * Ubuntu  -> gnome-terminal/konsole: one window per group, tab per session.
#   * VSCode  -> Claude: bridge into the current window if paired, else a new
#                window rooted at the work folder with one dedicated terminal
#                per session (runOn: folderOpen). Codex: always the new-window
#                path (the bridge protocol only speaks Claude's --resume).
#   * headless-> tmux: one SESSION per group, one WINDOW per session (+CLI win).
#                No tmux -> sequential in this terminal.
#
# Test/override:
#   RESUME_PROVIDER=claude|codex   RESUME_FORCE_LAUNCH=...   RESUME_DRY_RUN=1
#   RESUME_AUTO_SELECT=1 (take defaults, no prompt)
# NOTE: no `set -e` here. This script is written throughout in the
# `[ cond ] && action` idiom (move(), case arms, launch loops); under errexit a
# falsy test returns non-zero and aborts the script mid-interaction. Critical
# steps below have explicit `|| { echo…; exit 1; }` guards instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUI_HELPER="$SCRIPT_DIR/resume-gui.py"
SESSION_HELPER="$SCRIPT_DIR/codex_sessions.py"

# --- portable helpers --------------------------------------------------------
shquote() {   # single-quote a string for eval/paste. The ${x//\'/…} idiom is
              # broken on macOS's bash 3.2, so build the result character by
              # character; it is the one form that round-trips everywhere.
  local s="$1" out="" ch i
  for ((i=0;i<${#s};i++)); do
    ch="${s:i:1}"
    if [ "$ch" = "'" ]; then out+="'\\''"; else out+="$ch"; fi
  done
  printf "'%s'" "$out"
}
mtime_epoch() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null; }
first_cwd() {
  grep -m1 -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' "$1" 2>/dev/null \
    | sed -E 's/.*"cwd"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' | sed 's/\\\//\//g'
}
epoch_date() { date -r "$1" '+%Y-%m-%d' 2>/dev/null || date -d "@$1" '+%Y-%m-%d'; }
epoch_time() { date -r "$1" '+%m-%d %H:%M' 2>/dev/null || date -d "@$1" '+%m-%d %H:%M'; }
day_label() {
  local d="$1" today yday
  today="$(date '+%Y-%m-%d')"
  yday="$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || echo '')"
  if   [ "$d" = "$today" ]; then echo "今天  ($d)"
  elif [ -n "$yday" ] && [ "$d" = "$yday" ]; then echo "昨天  ($d)"
  else echo "$d"; fi
}
find_python() {   # echo first python >= 3.8 (for the Codex metadata reader)
  local candidate resolved
  for candidate in "${RESUME_PYBIN:-}" python3 python; do
    [ -n "$candidate" ] || continue
    resolved="$(command -v "$candidate" 2>/dev/null || true)"
    [ -n "$resolved" ] || continue
    "$resolved" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1 \
      && { printf '%s\n' "$resolved"; return; }
  done
  return 1
}

# --- provider setup ----------------------------------------------------------
# Everything below is shared; only discovery, the resume command, display text
# and the default launch mode differ. Keeping one implementation means the
# picker, quoting, printing and safety rules can never drift apart again.
PROVIDER="${RESUME_PROVIDER:-claude}"
case "$PROVIDER" in
  claude)
    PROVIDER_LABEL="Claude"
    DEFAULT_LAUNCH_MODE="print"
    GUI_TITLE="Claude Code · 恢复会话（按日期分组）"
    GUI_HINT="勾选要恢复的会话（点“开”列的框）。相同 组 号 = 合并到一个窗口的多个标签页（双击“组”列改号）；+CLI = 为该会话再开一个可跑命令的终端。"
    PROJECTS_ROOT="${RESUME_PROJECTS_ROOT:-$HOME/.claude/projects}"
    [ -d "$PROJECTS_ROOT" ] || { echo "Projects dir not found: $PROJECTS_ROOT" >&2; exit 1; }
    CLAUDE_CMD="$(command -v claude || true)"; [ -z "$CLAUDE_CMD" ] && CLAUDE_CMD="claude"
    ;;
  codex)
    PROVIDER_LABEL="Codex"
    DEFAULT_LAUNCH_MODE="auto"
    GUI_TITLE="Codex · 恢复会话（按日期分组）"
    GUI_HINT="勾选要恢复的会话。相同的正整数分组 = 一个窗口多个标签页；组 0 = 独立窗口。+CLI 额外打开命令行。"
    CODEX_DATA_HOME="${RESUME_CODEX_HOME:-${CODEX_HOME:-$HOME/.codex}}"
    [ -d "$CODEX_DATA_HOME/sessions" ] || { echo "Sessions dir not found: $CODEX_DATA_HOME/sessions" >&2; exit 1; }
    CODEX_DATA_HOME="$(cd "$CODEX_DATA_HOME" && pwd)"
    SESSIONS_ROOT="$CODEX_DATA_HOME/sessions"
    CODEX_CMD="${RESUME_CODEX_CMD:-$(command -v codex || true)}"; [ -n "$CODEX_CMD" ] || CODEX_CMD="codex"
    [ -f "$SESSION_HELPER" ] || { echo "Session helper not found: $SESSION_HELPER" >&2; exit 1; }
    PYBIN="$(find_python)" || { echo "Python 3.8+ is required for Codex sessions (or set RESUME_PYBIN)." >&2; exit 1; }
    ;;
  *)
    echo "Unknown RESUME_PROVIDER: $PROVIDER (expected claude or codex)" >&2
    exit 2
    ;;
esac

# Resume unattended by default. Set RESUME_SKIP_PERMISSIONS=0 to keep prompts:
# Claude then drops --dangerously-skip-permissions, and Codex is invoked with
# none of its own bypass flags (falling back to Codex's own safe defaults).
if [ "${RESUME_SKIP_PERMISSIONS:-1}" = "1" ]; then SKIP_PERMISSIONS=1; else SKIP_PERMISSIONS=0; fi

# parallel arrays indexed by session number
sel_id=(); sel_cwd=(); sel_name=(); sel_date=(); sel_time=()
sel_checked=(); sel_group=(); sel_cli=()
newest_date=""; group_of_date=""
if [ "$PROVIDER" = "codex" ]; then next_group=1; else next_group=0; fi
group_for_date() {                          # stable integer group id per date -> sets $REPLY_GROUP
  local d="$1" pair
  for pair in $group_of_date; do
    [ "${pair%%=*}" = "$d" ] && { REPLY_GROUP="${pair#*=}"; return; }
  done
  REPLY_GROUP="$next_group"; group_of_date="$group_of_date $d=$next_group"; next_group=$((next_group+1))
}
add_session() {   # $1 epoch  $2 id  $3 cwd  $4 display name
  local ep="$1" id="$2" cwd="$3" name="$4" d t
  d="$(epoch_date "$ep")"; t="$(epoch_time "$ep")"
  [ -z "$newest_date" ] && newest_date="$d"
  sel_id+=("$id"); sel_cwd+=("$cwd"); sel_name+=("$name")
  sel_date+=("$d"); sel_time+=("$t")
  [ "$d" = "$newest_date" ] && sel_checked+=("1") || sel_checked+=("0")
  group_for_date "$d"; sel_group+=("$REPLY_GROUP")
  sel_cli+=("0")
}

# --- discover sessions -------------------------------------------------------
discover_claude() {
  local f cwd id ep rec rest records=()
  while IFS= read -r -d '' f; do
    case "$f" in *subagents*) continue;; esac
    cwd="$(first_cwd "$f")"; [ -z "$cwd" ] && continue; [ -d "$cwd" ] || continue
    id="$(basename "$f" .jsonl)"; ep="$(mtime_epoch "$f")"
    records+=("$ep	$id	$cwd")
  done < <(find "$PROJECTS_ROOT" -type f -name '*.jsonl' -print0)
  [ "${#records[@]}" -eq 0 ] && { echo "No Claude sessions found." >&2; exit 0; }
  IFS=$'\n' records=($(printf '%s\n' "${records[@]}" | sort -t'	' -k1,1nr)); unset IFS
  for rec in "${records[@]}"; do
    ep="${rec%%	*}"; rest="${rec#*	}"; id="${rest%%	*}"; cwd="${rest#*	}"
    add_session "$ep" "$id" "$cwd" "$(basename "$cwd")"
  done
}
CODEX_SCAN_FILE=""   # global: the EXIT trap runs after discover_codex returns
discover_codex() {
  local ep id cwd
  CODEX_SCAN_FILE="$(mktemp "${TMPDIR:-/tmp}/resume-codex.XXXXXX")" || exit 1
  trap 'rm -f -- "${CODEX_SCAN_FILE:-}"' EXIT
  local scan_args=(--root "$SESSIONS_ROOT" --format nul)
  [ "${RESUME_INCLUDE_SUBAGENTS:-0}" = "1" ] && scan_args+=(--include-subagents)
  "$PYBIN" "$SESSION_HELPER" "${scan_args[@]}" > "$CODEX_SCAN_FILE" || exit 1
  while IFS= read -r -d '' ep && IFS= read -r -d '' id && IFS= read -r -d '' cwd; do
    add_session "$ep" "$id" "$cwd" "$(basename "$cwd") [${id:0:8}]"
  done < "$CODEX_SCAN_FILE"
}
"discover_$PROVIDER"
total="${#sel_id[@]}"
[ "$total" -eq 0 ] && { echo "No $PROVIDER_LABEL sessions found." >&2; exit 0; }

# --- launch-mode detection ---------------------------------------------------
# RESUME_FORCE_LAUNCH names a mode directly, or `auto` for platform sniffing.
# With nothing set, each provider keeps its documented default (Claude: print,
# Codex: auto).
UNAME="$(uname -s)"
detect_launch() {
  local want="${RESUME_FORCE_LAUNCH:-$DEFAULT_LAUNCH_MODE}"
  [ "$want" = "auto" ] || { echo "$want"; return; }
  if [ "${TERM_PROGRAM:-}" = "vscode" ] || [ -n "${VSCODE_INJECTION:-}" ] \
     || [ -n "${VSCODE_GIT_ASKPASS_NODE:-}" ] || [ -n "${VSCODE_IPC_HOOK_CLI:-}" ]; then
    echo "vscode"; return
  fi
  if [ "$UNAME" = "Darwin" ] || [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    echo "terminal"; return
  fi
  command -v tmux >/dev/null 2>&1 && { echo "tmux"; return; }
  echo "seq"
}
LAUNCH_MODE="$(detect_launch)"

# print mode reserves stdout for the commands themselves, so `> cmds.txt` and
# `| xclip` yield a clean paste-ready file. Everything the picker draws goes to
# the controlling terminal instead. Moving fd 1 wholesale (rather than editing
# every printf in the selection code) keeps the picker untouched; launch_print
# writes to fd 3, which still points at the real stdout.
# The `: >/dev/tty` probe must run BEFORE the exec: a failing `exec`
# redirection kills a non-interactive shell outright. With no controlling
# terminal the UI falls back to stderr and stdout stays clean either way.
if [ "$LAUNCH_MODE" = "print" ]; then
  exec 3>&1
  if { : >/dev/tty; } 2>/dev/null; then exec 1>/dev/tty; else exec 1>&2; fi
fi
# ============================ SELECTION (checkbox TUI) =======================
# rows[] maps visual row -> session index, or "H:<date>" for a date header.
# Collapsed dates hide their session rows (tree fold). ←/→ toggle the fold.
rows=(); nrows=0
collapsed_dates=" "
is_collapsed()    { case "$collapsed_dates" in *" $1 "*) return 0;; *) return 1;; esac; }
set_collapsed()   { is_collapsed "$1" || collapsed_dates="$collapsed_dates$1 "; }
unset_collapsed() { collapsed_dates="${collapsed_dates/ $1 / }"; }
build_rows() {
  rows=(); local i last=""
  for ((i=0;i<total;i++)); do
    [ "${sel_date[$i]}" != "$last" ] && { rows+=("H:${sel_date[$i]}"); last="${sel_date[$i]}"; }
    is_collapsed "${sel_date[$i]}" && continue
    rows+=("$i")
  done
  nrows="${#rows[@]}"
}
row_of_header() {   # echo visual row of header for date $1 (or current cur)
  local d="$1" r
  for ((r=0;r<nrows;r++)); do [ "${rows[$r]}" = "H:$d" ] && { echo "$r"; return; }; done
  echo "$cur"
}
build_rows

chosen_idx=()
collect_default() { chosen_idx=(); local i; for ((i=0;i<total;i++)); do [ "${sel_checked[$i]}" = "1" ] && chosen_idx+=("$i"); done; return 0; }

# --- GUI availability --------------------------------------------------------
# GUI = a graphical display is present AND some python3 can actually open a Tk
# window (init + update, not just import — catches broken system Tk).
# Auto-detected; override with RESUME_FORCE_SELECT=gui|tui, or RESUME_PYBIN=/path.
has_display() {
  [ "$UNAME" = "Darwin" ] && { [ "$(launchctl managername 2>/dev/null)" = "Aqua" ] || [ -z "${SSH_CONNECTION:-}" ]; return; }
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]
}
tk_works() {   # $1 = python binary -> 0 if it can open a real Tk window
  "$1" - <<'PYCHK' >/dev/null 2>&1
import sys
try:
    import tkinter as tk
    r = tk.Tk(); r.withdraw(); r.update(); r.destroy()
except Exception:
    sys.exit(1)
PYCHK
}
find_gui_python() {   # echo first python whose Tk works; empty if none
  local c
  for c in "${RESUME_PYBIN:-}" /opt/homebrew/bin/python3 /usr/local/bin/python3 \
           python3 python /usr/bin/python3; do
    [ -n "$c" ] || continue
    c="$(command -v "$c" 2>/dev/null || echo "$c")"
    [ -x "$c" ] || continue
    tk_works "$c" && { echo "$c"; return; }
  done
}
GUIPY=""
gui_available() {
  case "${RESUME_FORCE_SELECT:-}" in tui) return 1;; esac
  [ -f "$GUI_HELPER" ] || return 1
  has_display || [ "${RESUME_FORCE_SELECT:-}" = "gui" ] || return 1
  GUIPY="$(find_gui_python)"
  [ -n "$GUIPY" ] || return 1
  return 0
}


group_all_checked_in_date() {  # $1=date -> 1 if every session that date is checked
  local d="$1" i any_off=0 any=0
  for ((i=0;i<total;i++)); do
    [ "${sel_date[$i]}" = "$d" ] || continue; any=1
    [ "${sel_checked[$i]}" = "0" ] && any_off=1
  done
  [ "$any" = "1" ] && [ "$any_off" = "0" ] && echo 1 || echo 0
}
toggle_date_group() {          # select-all / deselect-all for a date
  local d="$1" i tgt; [ "$(group_all_checked_in_date "$d")" = "1" ] && tgt=0 || tgt=1
  for ((i=0;i<total;i++)); do [ "${sel_date[$i]}" = "$d" ] && sel_checked[$i]="$tgt"; done
}

TUI_DREW=0      # set by select_tui; launch_print clears the screen only if the
                # full-screen picker actually drew a frame over it.
select_tui() {
  [ -t 0 ] && [ -t 1 ] || { select_plain; return; }
  local cur=1 key rest r si off=0
  # start cursor on first real session
  for ((r=0;r<nrows;r++)); do case "${rows[$r]}" in H:*) ;; *) cur=$r; break;; esac; done
  tput civis 2>/dev/null || true
  printf '\033[2J'                            # one full clear up front; draw() is incremental after
  TUI_DREW=1
  trap 'tput cnorm 2>/dev/null || true' RETURN

  term_rows() { local n; n="$(tput lines 2>/dev/null || echo 24)"; [ "$n" -ge 6 ] || n=24; echo "$n"; }

  draw() {
    local lines vis top bot r item si mark grp cli hd fold
    lines="$(term_rows)"
    vis=$((lines - 5))                       # reserve: title + 2 hint lines + status + prompt safety
    [ "$vis" -lt 3 ] && vis=3
    # keep cursor within [off, off+vis)
    [ "$cur" -lt "$off" ] && off="$cur"
    [ "$cur" -ge $((off+vis)) ] && off=$((cur-vis+1))
    [ "$off" -lt 0 ] && off=0
    top="$off"; bot=$((off+vis)); [ "$bot" -gt "$nrows" ] && bot="$nrows"

    # Flicker-free: home the cursor and clear each line as we overwrite it
    # (\033[K), then clear anything left below (\033[J). Never full-clear.
    printf '\033[H'
    printf "\033[1m %s 会话 · 按日期分组\033[0m\033[K\n" "$PROVIDER_LABEL"
    printf " \033[2m↑↓/jk 移动 · ←折叠 →展开 · f 下翻页 b 上翻页 · [ ] 上/下一日期\033[0m\033[K\n"
    printf " \033[2m空格勾选 · g 设窗口组 · c 加CLI标签 · a 全选 n 全不选 · / 搜索 · 回车确认 · q 退出\033[0m\033[K\n"
    for ((r=top;r<bot;r++)); do
      item="${rows[$r]}"
      if [ "${item:0:2}" = "H:" ]; then
        hd="${item:2}"
        is_collapsed "$hd" && fold="▶" || fold="▼"
        [ "$(group_all_checked_in_date "$hd")" = "1" ] && mark="[\033[32m✔\033[0m]" || mark="[ ]"
        if [ "$r" -eq "$cur" ]; then printf "\033[7m %s %b %s \033[0m\033[K\n" "$fold" "$mark" "$(day_label "$hd")"
        else printf " \033[36m%s\033[0m %b \033[36m%s\033[0m\033[K\n" "$fold" "$mark" "$(day_label "$hd")"; fi
      else
        si="$item"
        [ "${sel_checked[$si]}" = "1" ] && mark="[\033[32m✔\033[0m]" || mark="[ ]"
        grp="G${sel_group[$si]}"
        [ "${sel_cli[$si]}" = "1" ] && cli="\033[33m+CLI\033[0m" || cli="    "
        if [ "$r" -eq "$cur" ]; then printf "\033[7m   %b %-4s %b %s  %s \033[0m\033[K\n" "$mark" "$grp" "$cli" "${sel_time[$si]}" "${sel_cwd[$si]}"
        else printf "   %b \033[2m%-4s\033[0m %b %s  %s\033[K\n" "$mark" "$grp" "$cli" "${sel_time[$si]}" "${sel_cwd[$si]}"; fi
      fi
    done
    local shown=$((bot-top)) nsel=0 i
    for ((i=0;i<total;i++)); do [ "${sel_checked[$i]}" = "1" ] && nsel=$((nsel+1)); done
    printf " \033[2m[%d-%d/%d 行 · 已选 %d]  相同 G 号=合并到一个窗口的多个标签页\033[0m\033[K\n" \
      $((top+1)) "$bot" "$nrows" "$nsel"
    printf '\033[J'                          # erase anything below the status line
  }
  move() { local dir="$1"; cur=$((cur+dir)); [ "$cur" -lt 0 ] && cur=0; [ "$cur" -ge "$nrows" ] && cur=$((nrows-1)); }
  page() { local lines vis; lines="$(term_rows)"; vis=$((lines-5)); [ "$vis" -lt 3 ] && vis=3; move $(( $1 * vis )); }
  # jump to next/prev date header
  jump_hdr() { local dir="$1" i="$cur"; while :; do i=$((i+dir)); [ "$i" -lt 0 ] && return; [ "$i" -ge "$nrows" ] && return; case "${rows[$i]}" in H:*) cur="$i"; return;; esac; done; }
  fold_current() {   # ← : collapse the date group the cursor is in
    local d
    if [ "${item:0:2}" = "H:" ]; then d="${item:2}"; else d="${sel_date[$item]}"; fi
    set_collapsed "$d"; build_rows
    cur="$(row_of_header "$d")"
    [ "$cur" -ge "$nrows" ] && cur=$((nrows-1)); [ "$cur" -lt 0 ] && cur=0
  }
  unfold_current() {  # → : expand the date group under the cursor
    [ "${item:0:2}" = "H:" ] || return
    unset_collapsed "${item:2}"; build_rows
    [ "$cur" -ge "$nrows" ] && cur=$((nrows-1))
  }

  while true; do
    draw
    IFS= read -rsn1 key || break
    if [ "$key" = $'\033' ]; then
      read -rsn2 -t 0.01 rest || rest=""
      case "$rest" in
        '[A') key='k';; '[B') key='j';;
        '[C') key='RIGHT';; '[D') key='LEFT';;          # →expand  ←collapse
        '[5') read -rsn1 -t 0.01 _ || true; key='PU';;   # PageUp  (ESC[5~)
        '[6') read -rsn1 -t 0.01 _ || true; key='PD';;   # PageDown(ESC[6~)
        '[H') cur=0; key='';; '[F') cur=$((nrows-1)); key='';;
        *) key='';;
      esac
    fi
    item="${rows[$cur]}"
    case "$key" in
      k) move -1 ;;  j) move 1 ;;
      LEFT)  fold_current ;;  RIGHT) unfold_current ;;
      PU|b|B) page -1 ;; PD|f|F) page 1 ;;         # f/b page down/up (no Page keys needed)
      '[') jump_hdr -1 ;;  ']') jump_hdr 1 ;;      # [ / ] jump between date groups
      ' ')
        if [ "${item:0:2}" = "H:" ]; then toggle_date_group "${item:2}"
        else si="$item"; [ "${sel_checked[$si]}" = "1" ] && sel_checked[$si]="0" || sel_checked[$si]="1"; fi ;;
      g|G)
        if [ "${item:0:2}" != "H:" ]; then
          tput cnorm 2>/dev/null||true; printf "\n  为该会话设置窗口组号 (相同号=合并, 直接回车取消): "
          read -r g; tput civis 2>/dev/null||true
          [[ "$g" =~ ^[0-9]+$ ]] && sel_group[$item]="$g"
        fi ;;
      c|C) [ "${item:0:2}" != "H:" ] && { si="$item"; [ "${sel_cli[$si]}" = "1" ] && sel_cli[$si]="0" || sel_cli[$si]="1"; } ;;
      /)  # incremental path filter: jump to first session whose cwd matches
        tput cnorm 2>/dev/null||true; printf "\n  搜索路径关键字: "; read -r q; tput civis 2>/dev/null||true
        if [ -n "$q" ]; then
          for ((r=0;r<nrows;r++)); do
            case "${rows[$r]}" in H:*) ;; *) case "${sel_cwd[${rows[$r]}]}" in *"$q"*) cur="$r"; break;; esac;; esac
          done
        fi ;;
      a|A) for ((si=0;si<total;si++)); do sel_checked[$si]="1"; done ;;
      n|N) for ((si=0;si<total;si++)); do sel_checked[$si]="0"; done ;;
      q|Q) tput cnorm 2>/dev/null||true; echo "已取消。"; exit 0 ;;
      '') break ;;
    esac
  done
  tput cnorm 2>/dev/null || true
  collect_default
}

# --- plain fallback (non-TTY / piped) ----------------------------------------
select_plain() {
  local i line tok
  print_plain() {
    local last="" i mark grp
    echo; echo "==== $PROVIDER_LABEL 会话（按日期分组）===="
    for ((i=0;i<total;i++)); do
      [ "${sel_date[$i]}" != "$last" ] && { last="${sel_date[$i]}"; echo; echo "  ▼ $(day_label "$last")"; }
      [ "${sel_checked[$i]}" = "1" ] && mark="x" || mark=" "; grp="G${sel_group[$i]}"
      printf "   [%s] %3d %-4s %s   %s\n" "$mark" "$((i+1))" "$grp" "${sel_time[$i]}" "${sel_cwd[$i]}"
    done
    echo; echo "数字/范围切换(1 3 5-8) · gN:M 设组(会话N→组M) · cN 切CLI · a全选 n全不选 · 回车确认 · q退出"
  }
  print_plain
  while true; do
    printf "> "; read -r line || break
    line="${line%$'\r'}"                       # Windows/paste CRLF
    case "$line" in
      q|Q) echo "已取消。"; exit 0 ;;
      "" ) break ;;
      a|A) for ((i=0;i<total;i++)); do sel_checked[$i]="1"; done ;;
      n|N) for ((i=0;i<total;i++)); do sel_checked[$i]="0"; done ;;
      g*) tok="${line#g}"; local nn="${tok%%:*}" mm="${tok#*:}"
          [[ "$nn" =~ ^[0-9]+$ && "$mm" =~ ^[0-9]+$ && "$nn" -ge 1 && "$nn" -le "$total" ]] && sel_group[$((nn-1))]="$mm" ;;
      c*) tok="${line#c}"; [[ "$tok" =~ ^[0-9]+$ && "$tok" -ge 1 && "$tok" -le "$total" ]] && \
          { [ "${sel_cli[$((tok-1))]}" = "1" ] && sel_cli[$((tok-1))]="0" || sel_cli[$((tok-1))]="1"; } ;;
      *) for tok in $line; do
           if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
             for ((n=${BASH_REMATCH[1]};n<=${BASH_REMATCH[2]};n++)); do
               [ "$n" -ge 1 ] && [ "$n" -le "$total" ] && { [ "${sel_checked[$((n-1))]}" = "1" ] && sel_checked[$((n-1))]="0" || sel_checked[$((n-1))]="1"; }
             done
           elif [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "$total" ]; then
             [ "${sel_checked[$((tok-1))]}" = "1" ] && sel_checked[$((tok-1))]="0" || sel_checked[$((tok-1))]="1"
           fi
         done ;;
    esac
    print_plain
  done
  collect_default
}
# --- GUI selection (python3 + tkinter): full-featured window -----------------
# Presents a scrollable, date-grouped checklist mirroring the Windows GUI:
#   per row: [Open] checkbox · Group spinbox · [+CLI] checkbox · time · path
#   per date header: a checkbox that selects/deselects the whole group.
# Sends the session records in on stdin (TSV), reads selection back on stdout as
#   idx<TAB>group<TAB>cli   (one line per chosen session).
sanitize_tsv() { local s="$1"; s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; printf '%s' "$s"; }
select_gui() {
  local payload="" record i display_path display_name
  for ((i=0;i<total;i++)); do
    # TSV is only a display protocol; retain the original path for launching.
    display_path="$(sanitize_tsv "${sel_cwd[$i]}")"
    display_name="$display_path"
    [ "$PROVIDER" = "codex" ] && display_name="$display_path [${sel_id[$i]:0:8}]"
    printf -v record '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "${sel_date[$i]}" "$(day_label "${sel_date[$i]}")" "${sel_time[$i]}" "${sel_group[$i]}" "${sel_checked[$i]}" "$display_path" "$display_name"
    payload+="$record"
  done
  local out
  out="$(printf '%s' "$payload" | RESUME_GUI_TITLE="$GUI_TITLE" RESUME_GUI_HINT="$GUI_HINT" "$GUIPY" "$GUI_HELPER")" || { echo "已取消。"; exit 0; }
  [ -z "$out" ] && { chosen_idx=(); return; }
  chosen_idx=()
  while IFS=$'\t' read -r idx grp cli; do
    [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt "$total" ] || continue
    [[ "$grp" =~ ^[0-9]+$ ]] || grp=0
    sel_group[$idx]="$grp"; sel_cli[$idx]="$cli"; chosen_idx+=("$idx")
  done <<< "$out"
}

# --- run selection -----------------------------------------------------------
if [ "${RESUME_AUTO_SELECT:-}" = "1" ]; then
  collect_default
elif gui_available; then
  select_gui
else
  select_tui
fi
[ "${#chosen_idx[@]}" -eq 0 ] && { echo "未选择任何会话。"; exit 0; }

# Codex's group 0 means "its own window", matching the Windows launcher.
if [ "$PROVIDER" = "codex" ]; then
  for i in "${chosen_idx[@]}"; do
    [ "${sel_group[$i]}" = "0" ] && sel_group[$i]="single-$i"
  done
fi

# unique group ids among chosen, preserving first-seen order
chosen_groups=""
for i in "${chosen_idx[@]}"; do
  g="${sel_group[$i]}"; case " $chosen_groups " in *" $g "*) ;; *) chosen_groups="$chosen_groups $g";; esac
done

resume_cmd() {   # $1 = session index -> full command line, unquoted for output
  if [ "$PROVIDER" = "codex" ]; then
    printf 'env CODEX_HOME=%q %q' "$CODEX_DATA_HOME" "$CODEX_CMD"
    [ "$SKIP_PERMISSIONS" = "1" ] && printf ' --dangerously-bypass-approvals-and-sandbox'
    printf ' resume %q --cd %q' "${sel_id[$1]}" "${sel_cwd[$1]}"
  else
    printf '%s --resume %s' "$CLAUDE_CMD" "${sel_id[$1]}"
    [ "$SKIP_PERMISSIONS" = "1" ] && printf ' --dangerously-skip-permissions'
  fi
}

# ============================ LAUNCH =========================================
# --- macOS: one Terminal.app window per group, one tab per session -----------
# Paths/commands are passed as argv, never interpolated into AppleScript
# source, so a quote or backslash in a directory name cannot alter the script.
mac_open_window() {
  osascript - "$1" "$2" >/dev/null 2>&1 <<'OSA'
on run argv
  tell application "Terminal"
    activate
    do script "cd " & quoted form of (item 1 of argv) & " && " & (item 2 of argv)
  end tell
end run
OSA
}
mac_new_tab() {  # $1 dir $2 cmd — needs Accessibility perm; falls back to window
  osascript - "$1" "$2" >/dev/null 2>&1 <<'OSA' || mac_open_window "$1" "$2"
on run argv
  tell application "Terminal" to activate
  tell application "System Events" to keystroke "t" using command down
  delay 0.4
  tell application "Terminal" to do script "cd " & quoted form of (item 1 of argv) & " && " & (item 2 of argv) in front window
end run
OSA
}
mac_group_window() {   # $@ = session indices in this group
  local idxs=("$@") first="${1}" i cwd
  cwd="${sel_cwd[$first]}"
  mac_open_window "$cwd" "$(resume_cmd "$first")"
  [ "${sel_cli[$first]}" = "1" ] && mac_new_tab "$cwd" "echo 'Manual CLI ready'"
  # remaining sessions as new tabs in the same (frontmost) window
  local rest=("${idxs[@]:1}")
  for i in "${rest[@]}"; do
    mac_new_tab "${sel_cwd[$i]}" "$(resume_cmd "$i")"
    [ "${sel_cli[$i]}" = "1" ] && mac_new_tab "${sel_cwd[$i]}" "echo 'Manual CLI ready'"
  done
}

launch_terminal_mac() {
  local g grp_idxs i
  for g in $chosen_groups; do
    grp_idxs=(); for i in "${chosen_idx[@]}"; do [ "${sel_group[$i]}" = "$g" ] && grp_idxs+=("$i"); done
    echo "窗口(组 G$g): ${#grp_idxs[@]} 个标签页"
    mac_group_window "${grp_idxs[@]}"
    sleep 0.4
  done
}

# --- Linux desktop: gnome-terminal/konsole, one window per group, tabs -------
terminal_command_arg() {
  # GNOME/Konsole parse a command string using shell-style double quotes.
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}
launch_konsole_group() {
  local tab_dir i cli script_path title
  tab_dir="$(mktemp -d "${TMPDIR:-/tmp}/resume-${PROVIDER}-tabs.XXXXXX")" || return 1
  for i in "$@"; do
    for cli in 0 1; do
      [ "$cli" = 1 ] && [ "${sel_cli[$i]}" != 1 ] && continue
      script_path="$tab_dir/$i-$cli.sh"
      {
        printf '#!/usr/bin/env bash\ncd -- %q || exit 1\n' "${sel_cwd[$i]}"
        [ "$cli" = 0 ] && printf '%s\n' "$(resume_cmd "$i")"
        printf 'exec bash\n'
      } > "$script_path"
      title="${PROVIDER_LABEL}-${sel_id[$i]:0:8}"
      [ "$cli" = 1 ] && title="$title-cli"
      printf 'title: %s ;; command: bash %s\n' "$title" "$(terminal_command_arg "$script_path")" >> "$tab_dir/tabs"
    done
  done
  # Keep the generated startup files until this separate Konsole process exits.
  (
    trap 'rm -rf -- "$tab_dir"' EXIT
    konsole --separate --tabs-from-file "$tab_dir/tabs"
  ) &
}
launch_terminal_linux() {
  local g grp_idxs i args first
  for g in $chosen_groups; do
    grp_idxs=(); for i in "${chosen_idx[@]}"; do [ "${sel_group[$i]}" = "$g" ] && grp_idxs+=("$i"); done
    if command -v gnome-terminal >/dev/null 2>&1; then
      args=(); first=1
      for i in "${grp_idxs[@]}"; do
        if [ "$first" = 1 ]; then args+=(--window); first=0; else args+=(--tab); fi
        # A per-tab --command is required: -- consumes the rest of the invocation.
        args+=(--title="${sel_name[$i]}" --working-directory="${sel_cwd[$i]}" --command="bash -c $(terminal_command_arg "$(resume_cmd "$i"); exec bash")")
        [ "${sel_cli[$i]}" = "1" ] && args+=(--tab --title="${sel_name[$i]}-cli" --working-directory="${sel_cwd[$i]}" --command=bash)
      done
      gnome-terminal "${args[@]}" &
    elif command -v konsole >/dev/null 2>&1; then
      launch_konsole_group "${grp_idxs[@]}"
    else
      for i in "${grp_idxs[@]}"; do
        if command -v xterm >/dev/null 2>&1; then (cd "${sel_cwd[$i]}" && xterm -e bash -lc "$(resume_cmd "$i"); exec bash") &
        else ( cd "${sel_cwd[$i]}" && bash -lc "$(resume_cmd "$i")" ); fi
      done
    fi
    sleep 0.4
  done
}

# --- tmux (headless): one session per group, one window per session ----------
launch_tmux() {
  local g grp_idxs i sess first w target attach=""
  for g in $chosen_groups; do
    grp_idxs=(); for i in "${chosen_idx[@]}"; do [ "${sel_group[$i]}" = "$g" ] && grp_idxs+=("$i"); done
    sess="$PROVIDER-G$g"; tmux has-session -t "$sess" 2>/dev/null && sess="$PROVIDER-G$g-$$"
    [ -z "$attach" ] && attach="$sess"
    first=1
    for i in "${grp_idxs[@]}"; do
      w="${sel_name[$i]}"
      if [ "$first" = "1" ]; then
        target="$(tmux new-session -d -P -F '#{window_id}' -s "$sess" -n "$w" -c "${sel_cwd[$i]}")" || return 1
        first=0
      else
        target="$(tmux new-window -P -F '#{window_id}' -t "$sess" -n "$w" -c "${sel_cwd[$i]}")" || return 1
      fi
      tmux send-keys -t "$target" -l -- "$(resume_cmd "$i")"
      tmux send-keys -t "$target" C-m
      [ "${sel_cli[$i]}" = "1" ] && tmux new-window -t "$sess" -n "$w-cli" -c "${sel_cwd[$i]}"
    done
    echo "tmux 会话 '$sess'：${#grp_idxs[@]} 个窗口"
  done
  if [ -n "${TMUX:-}" ]; then echo "（已在 tmux 内，Ctrl-b s 切换会话）"
  else echo "attach 到 '$attach'（切换其他组: Ctrl-b s，分离: Ctrl-b d）"; tmux attach -t "$attach" 2>/dev/null || true; fi
}

launch_seq() {
  local i
  for i in "${chosen_idx[@]}"; do
    echo; echo ">>> ${sel_name[$i]} (${sel_cwd[$i]}) —— 退出后继续下一个"
    ( cd "${sel_cwd[$i]}" && bash -c "$(resume_cmd "$i")" ) || true
  done
}

# --- print: launch nothing, emit paste-ready commands on fd 3 ----------------
# For when the sessions belong in terminals you already have open — VSCode
# offers no way to attach one there without the Comate bridge, and the
# new-window fallback is often not what you want.
#
# Commands go to fd 3 (the real stdout, saved before fd 1 was pointed at the
# tty); the hint goes to fd 1 so it never lands in a redirected file. Ordering
# mirrors what the other launchers would have built: group by group, and a
# session's +CLI command immediately after its own resume command.
launch_print() {
  local g i cmd first=1
  # Only the full-screen TUI leaves a frame worth erasing. The GUI picker owns a
  # separate window, the plain picker's scrollback may still be wanted, and
  # RESUME_AUTO_SELECT draws nothing at all — clearing an automated caller's
  # screen would be hostile.
  [ "$TUI_DREW" = "1" ] && [ -t 1 ] && printf '\033[2J\033[H'
  echo "以下命令逐条复制，粘贴到你想用的终端里执行（相同 G 号原本会合并到一个窗口）："
  echo "（想让脚本直接开终端/窗口：RESUME_FORCE_LAUNCH=auto）"
  echo
  for g in $chosen_groups; do
    for i in "${chosen_idx[@]}"; do
      [ "${sel_group[$i]}" = "$g" ] || continue
      cmd="$(resume_cmd "$i")"; cmd="${cmd% }"
      [ "$first" = "1" ] || printf '\n' >&3
      printf '# G%s  resume: %s [%s]\n' "$g" "${sel_name[$i]}" "${sel_time[$i]}" >&3
      printf 'cd %s && %s\n' "$(shquote "${sel_cwd[$i]}")" "$cmd" >&3
      first=0
      # A bare cd: the user is already sitting in the shell they pasted into,
      # so there is nothing to exec.
      if [ "${sel_cli[$i]}" = "1" ]; then
        printf '\n' >&3
        printf '# G%s  cli: %s\n' "$g" "${sel_name[$i]}" >&3
        printf 'cd %s\n' "$(shquote "${sel_cwd[$i]}")" >&3
      fi
    done
  done
}

# --- VSCode: exact-window bridge first, fixed-new-window as the only fallback
# Two independent paths, tried in order:
#
#   1. launch_vscode_bridge — talks to the exact-window Comate bridge server
#      (bridge/comate_bridge_client.py) over its per-window Unix socket, so
#      terminals land in the CURRENT window/tabs with no reload and no new
#      window at all. This is the preferred path whenever the bridge is
#      actually running in this window. Claude only: the bridge protocol
#      composes `claude --resume <id>`, so Codex skips straight to path 2.
#
#      Routing is via a user-confirmed pairing (bridge/comate_bridge_client.py
#      `pair`/`probe-paired`/`send-input0 --paired-workspace`), NOT via
#      `VSCODE_IPC_HOOK_CLI`: an isolated live test proved that newly created
#      terminals in the SAME window observe a different IPC hook value than
#      the terminal that launched them, so the hook cannot identify "this
#      window" for routing purposes. The pairing instead binds trust to the
#      sole currently-live bridge socket's identity, its extension-host PID,
#      and the expected workspace root, created once via
#      `scripts/pair-comate-bridge.sh --confirmed-current-window` and
#      revalidated on every use.
#
#   2. launch_vscode_new_window — the pre-existing .code-workspace mechanism:
#      VSCode exposes no CLI to spawn/inject terminals in the current window
#      (checked: comate/code only do -n/-r/-a/-g), so parallel auto-launch
#      falls back to tasks with runOn:folderOpen in a brand NEW window opened
#      with a fixed `-n`. Constraints preserved:
#        a. Each session is its OWN independent terminal — NO
#           presentation.group, so they are separate terminals, never
#           split/child panes.
#        b. The opened window is ROOTED at the work folder
#           (RESUME_VSCODE_FOLDER, default: the current directory), via a
#           self-contained *.code-workspace written in THIS repo (overwritten
#           each run); <folder>/.vscode is never touched.
#        c. Always `-n`. NEVER `-r`/reuse/reload the user's current window:
#           doing so would discard its integrated terminals and other
#           window-local state.
#
# launch_vscode() dispatches on launch_vscode_bridge's documented exit code
# rather than a bare `||`, because falling back after status 3/4 could
# duplicate terminals the bridge may already have created:
#   0        bridge completed successfully -> done, no fallback.
#   2        bridge unavailable BEFORE any bytes were sent -> safe to fall
#            back to the fixed new window.
#   3 or 4   request may have been delivered, or the bridge reported
#            terminal-creation errors -> never retry, never fall back.
#   other    unexpected internal error -> do not fall back either.
#
#   RESUME_VSCODE_FOLDER   workspace root for pairing and the new-window
#                          fallback (default: the current directory)
vscode_cli() {   # echo a usable VSCode/comate CLI path, or empty
  local srv c
  if [ -n "${VSCODE_GIT_ASKPASS_NODE:-}" ]; then
    srv="$(dirname "$VSCODE_GIT_ASKPASS_NODE")"
    for c in "$srv"/bin/remote-cli/*; do [ -x "$c" ] && { echo "$c"; return; }; done
  fi
  for c in comate code code-insiders; do command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return; }; done
}

# --- bridge path: deliver terminals into the CURRENT window, no new window ---
launch_vscode_bridge() {
  local client="$SCRIPT_DIR/bridge/comate_bridge_client.py"
  [ -f "$client" ] || return 2

  local folder="${RESUME_VSCODE_FOLDER:-$PWD}"
  python3 "$client" probe-paired --workspace-root "$folder" >/dev/null 2>&1 || return 2

  local i
  {
    for i in "${chosen_idx[@]}"; do
      printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
        resume "resume: ${sel_name[$i]} [${sel_time[$i]}]" "${sel_cwd[$i]}" \
        "$CLAUDE_CMD" "${sel_id[$i]}" "$SKIP_PERMISSIONS"
      if [ "${sel_cli[$i]}" = "1" ]; then
        printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
          cli "cli: ${sel_name[$i]}" "${sel_cwd[$i]}" "${SHELL:-/bin/bash}" '' 0
      fi
    done
  } | python3 "$client" send-input0 --paired-workspace "$folder"
}

# --- fallback path: fixed -n, new window, no reuse/reload -------------------
launch_vscode_new_window() {
  local folder="${RESUME_VSCODE_FOLDER:-$PWD}"
  local wsfile="$SCRIPT_DIR/resume-sessions.code-workspace"
  local i label cmd json="" cli

  add_task() { # $1 label  $2 shell-cmd
    local l="$1" c="$2"
    l="${l//\"/\'}"; c="${c//\\/\\\\}"; c="${c//\"/\\\"}"
    [ -n "$json" ] && json+=","
    # No "group": each task gets its own dedicated top-level terminal.
    json+='
      { "label": "'"$l"'", "type": "shell", "command": "'"$c"'",
        "presentation": { "panel": "dedicated", "reveal": "always", "focus": false },
        "runOptions": { "runOn": "folderOpen" },
        "problemMatcher": [] }'
  }
  for i in "${chosen_idx[@]}"; do
    label="resume: ${sel_name[$i]} [${sel_time[$i]}]"
    cmd="cd $(shquote "${sel_cwd[$i]}") && $(resume_cmd "$i")"
    add_task "$label" "$cmd"
    [ "${sel_cli[$i]}" = "1" ] && add_task "cli: ${sel_name[$i]}" "cd $(shquote "${sel_cwd[$i]}") && exec \$SHELL"
  done

  # Overwrite each run. Window root = $folder; tasks live inline in the workspace
  # file, so nothing is written under $folder/.vscode.
  cat > "$wsfile" <<EOF
{
  "folders": [ { "path": "${folder//\"/\\\"}" } ],
  "settings": { "task.allowAutomaticTasks": "on" },
  "tasks": {
    "version": "2.0.0",
    "tasks": [$json
    ]
  }
}
EOF
  echo "已写入 $wsfile （窗口根目录=${folder}，${#chosen_idx[@]} 个独立终端，folderOpen 自动并行启动）。"
  cli="$(vscode_cli)"
  if [ -n "$cli" ]; then
    echo "新开独立窗口并自动拉起会话：$cli -n $wsfile"
    "$cli" -n "$wsfile" >/dev/null 2>&1 || echo "（打开失败，请手动在 VSCode 新窗口打开该 .code-workspace 文件）"
  else
    echo "未找到 VSCode/comate CLI。请手动在 VSCode 打开：$wsfile"
  fi
}

launch_vscode() {
  local status=2
  [ "$PROVIDER" = "claude" ] && { launch_vscode_bridge; status=$?; }
  case "$status" in
    0) return 0 ;;
    2) launch_vscode_new_window ;;
    3|4) echo "bridge 请求可能已送达或已报告终端创建错误（退出码 ${status}），为避免重复终端不会新开窗口。" >&2; return "$status" ;;
    *) echo "bridge 客户端内部错误（退出码 ${status}），未启动备用窗口以避免重复终端。" >&2; return "$status" ;;
  esac
}

if [ "${RESUME_DRY_RUN:-}" = "1" ]; then
  echo "[dry-run] provider=$PROVIDER launch=$LAUNCH_MODE  选中 ${#chosen_idx[@]} 个，组:$chosen_groups"
  for i in "${chosen_idx[@]}"; do
    printf "  - G%s %s %s (%s)\n" "${sel_group[$i]}" "$([ "${sel_cli[$i]}" = 1 ] && echo +CLI || echo '    ')" "${sel_name[$i]}" "${sel_cwd[$i]}"
    printf '    %s\n' "$(resume_cmd "$i")"
  done
  exit 0
fi

case "$LAUNCH_MODE" in
  print)    launch_print ;;
  vscode)   launch_vscode ;;
  terminal) [ "$UNAME" = "Darwin" ] && launch_terminal_mac || launch_terminal_linux ;;
  tmux)     launch_tmux ;;
  seq)      launch_seq ;;
  *)        launch_seq ;;
esac
