#!/usr/bin/env bash
# Resume Claude Code sessions — universal launcher (Windows-parity).
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
# Launch (auto-detected):
#   * macOS   -> one Terminal.app WINDOW per group, one TAB per session
#                (+CLI = extra tab). Tabs need Accessibility perm; else windows.
#   * Ubuntu  -> gnome-terminal/konsole: one window per group, tab per session.
#   * VSCode  -> writes .vscode/tasks.json (one dedicated panel per session,
#                grouped); press Ctrl/Cmd+Shift+B.
#   * headless-> tmux: one SESSION per group, one WINDOW per session (+CLI win).
#                No tmux -> sequential in this terminal.
#
# Test/override:
#   RESUME_FORCE_LAUNCH=terminal|vscode|tmux|seq   RESUME_DRY_RUN=1
#   RESUME_AUTO_SELECT=1 (take defaults, no prompt)
# NOTE: no `set -e` here. This script is written throughout in the
# `[ cond ] && action` idiom (move(), case arms, launch loops); under errexit a
# falsy test returns non-zero and aborts the script mid-interaction. Critical
# steps below have explicit `|| { echo…; exit 1; }` guards instead.
set -uo pipefail

PROJECTS_ROOT="${RESUME_PROJECTS_ROOT:-$HOME/.claude/projects}"
CLAUDE_CMD="$(command -v claude || true)"; [ -z "$CLAUDE_CMD" ] && CLAUDE_CMD="claude"
# Resume normally (permissions ON). Dev machines should NOT skip permission
# prompts. Opt in explicitly with RESUME_SKIP_PERMISSIONS=1 if you really want
# `--dangerously-skip-permissions`.
if [ "${RESUME_SKIP_PERMISSIONS:-0}" = "1" ]; then
  RESUME_FLAGS="--dangerously-skip-permissions"
else
  RESUME_FLAGS=""
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUI_HELPER="$SCRIPT_DIR/resume-gui.py"

[ -d "$PROJECTS_ROOT" ] || { echo "Projects dir not found: $PROJECTS_ROOT" >&2; exit 1; }

# --- portable helpers --------------------------------------------------------
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
# --- discover ALL sessions (epoch<TAB>id<TAB>cwd, newest first) --------------
records=()
while IFS= read -r -d '' f; do
  case "$f" in *subagents*) continue;; esac
  cwd="$(first_cwd "$f")"; [ -z "$cwd" ] && continue; [ -d "$cwd" ] || continue
  id="$(basename "$f" .jsonl)"; ep="$(mtime_epoch "$f")"
  records+=("$ep	$id	$cwd")
done < <(find "$PROJECTS_ROOT" -type f -name '*.jsonl' -print0)
[ "${#records[@]}" -eq 0 ] && { echo "No Claude sessions found." >&2; exit 0; }
IFS=$'\n' records=($(printf '%s\n' "${records[@]}" | sort -t'	' -k1,1nr)); unset IFS

# parallel arrays indexed by session number
sel_id=(); sel_cwd=(); sel_name=(); sel_date=(); sel_time=()
sel_checked=(); sel_group=(); sel_cli=()
newest_date=""; group_of_date=""; next_group=0
group_for_date() {                          # stable integer group id per date -> sets $REPLY_GROUP
  local d="$1" pair
  for pair in $group_of_date; do
    [ "${pair%%=*}" = "$d" ] && { REPLY_GROUP="${pair#*=}"; return; }
  done
  REPLY_GROUP="$next_group"; group_of_date="$group_of_date $d=$next_group"; next_group=$((next_group+1))
}
for rec in "${records[@]}"; do
  ep="${rec%%	*}"; rest="${rec#*	}"; id="${rest%%	*}"; cwd="${rest#*	}"
  d="$(epoch_date "$ep")"; t="$(epoch_time "$ep")"
  [ -z "$newest_date" ] && newest_date="$d"
  sel_id+=("$id"); sel_cwd+=("$cwd"); sel_name+=("$(basename "$cwd")")
  sel_date+=("$d"); sel_time+=("$t")
  [ "$d" = "$newest_date" ] && sel_checked+=("1") || sel_checked+=("0")
  group_for_date "$d"; sel_group+=("$REPLY_GROUP")   # DEFAULT: one window per date group
  sel_cli+=("0")
done
total="${#sel_id[@]}"

# --- launch-mode detection ---------------------------------------------------
UNAME="$(uname -s)"
detect_launch() {
  [ -n "${RESUME_FORCE_LAUNCH:-}" ] && { echo "$RESUME_FORCE_LAUNCH"; return; }
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
PYBIN=""    # any python (for non-GUI helpers); GUIPY = one with working Tk
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

select_tui() {
  [ -t 0 ] && [ -t 1 ] || { select_plain; return; }
  local cur=1 key rest r si off=0
  # start cursor on first real session
  for ((r=0;r<nrows;r++)); do case "${rows[$r]}" in H:*) ;; *) cur=$r; break;; esac; done
  tput civis 2>/dev/null || true
  printf '\033[2J'                            # one full clear up front; draw() is incremental after
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
    printf "\033[1m Claude 会话 · 按日期分组\033[0m\033[K\n"
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
    echo; echo "==== Claude 会话（按日期分组）===="
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
select_gui() {
  local payload="" i
  for ((i=0;i<total;i++)); do
    payload+="$i	${sel_date[$i]}	$(day_label "${sel_date[$i]}")	${sel_time[$i]}	${sel_group[$i]}	${sel_checked[$i]}	${sel_cwd[$i]}"$'\n'
  done
  local out
  out="$(printf '%s' "$payload" | "$GUIPY" "$GUI_HELPER")" || { echo "已取消。"; exit 0; }
  [ -z "$out" ] && { chosen_idx=(); return; }
  chosen_idx=()
  while IFS=$'\t' read -r idx grp cli; do
    [[ "$idx" =~ ^[0-9]+$ ]] || continue
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

# unique group ids among chosen, preserving first-seen order
chosen_groups=""
for i in "${chosen_idx[@]}"; do
  g="${sel_group[$i]}"; case " $chosen_groups " in *" $g "*) ;; *) chosen_groups="$chosen_groups $g";; esac
done

resume_cmd() { echo "$CLAUDE_CMD --resume ${sel_id[$1]} $RESUME_FLAGS"; }

# ============================ LAUNCH =========================================
# --- macOS: one Terminal.app window per group, one tab per session -----------
mac_group_window() {   # $@ = session indices in this group
  local idxs=("$@") first="${1}" osa i cmd cwd
  cmd="$(resume_cmd "$first")"; cwd="${sel_cwd[$first]}"
  # open the group's window with the first session
  osa="tell application \"Terminal\"
    activate
    set w to do script \"cd \" & quoted form of \"$cwd\" & \" && $cmd\"
  end tell"
  osascript -e "$osa" >/dev/null 2>&1 || true
  # +CLI tab for the first session
  [ "${sel_cli[$first]}" = "1" ] && mac_new_tab "$cwd" "echo 'manual CLI — ${sel_name[$first]}'"
  # remaining sessions as new tabs in the same (frontmost) window
  local rest=("${idxs[@]:1}")
  for i in "${rest[@]}"; do
    mac_new_tab "${sel_cwd[$i]}" "$(resume_cmd "$i")"
    [ "${sel_cli[$i]}" = "1" ] && mac_new_tab "${sel_cwd[$i]}" "echo 'manual CLI — ${sel_name[$i]}'"
  done
}
mac_new_tab() {  # $1 dir $2 cmd — needs Accessibility perm; falls back to window
  local dir="$1" cmd="$2"
  osascript >/dev/null 2>&1 <<OSA || osascript >/dev/null 2>&1 <<FALL
tell application "Terminal" to activate
tell application "System Events" to keystroke "t" using command down
delay 0.4
tell application "Terminal" to do script "cd " & quoted form of "$dir" & " && $cmd" in front window
OSA
tell application "Terminal" to do script "cd " & quoted form of "$dir" & " && $cmd"
FALL
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
launch_terminal_linux() {
  local g grp_idxs i args
  for g in $chosen_groups; do
    grp_idxs=(); for i in "${chosen_idx[@]}"; do [ "${sel_group[$i]}" = "$g" ] && grp_idxs+=("$i"); done
    if command -v gnome-terminal >/dev/null 2>&1; then
      args=()
      for i in "${grp_idxs[@]}"; do
        args+=(--tab --title="${sel_name[$i]}" --working-directory="${sel_cwd[$i]}" -- bash -lc "$(resume_cmd "$i"); exec bash")
        [ "${sel_cli[$i]}" = "1" ] && args+=(--tab --title="${sel_name[$i]}-cli" --working-directory="${sel_cwd[$i]}" -- bash)
      done
      gnome-terminal "${args[@]}" &
    elif command -v konsole >/dev/null 2>&1; then
      for i in "${grp_idxs[@]}"; do
        konsole --new-tab --workdir "${sel_cwd[$i]}" -e bash -lc "$(resume_cmd "$i"); exec bash" &
        [ "${sel_cli[$i]}" = "1" ] && konsole --new-tab --workdir "${sel_cwd[$i]}" -e bash &
      done
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
  local g grp_idxs i sess first w
  for g in $chosen_groups; do
    grp_idxs=(); for i in "${chosen_idx[@]}"; do [ "${sel_group[$i]}" = "$g" ] && grp_idxs+=("$i"); done
    sess="claude-G$g"; tmux has-session -t "$sess" 2>/dev/null && sess="claude-G$g-$$"
    first=1
    for i in "${grp_idxs[@]}"; do
      w="${sel_name[$i]}"
      if [ "$first" = "1" ]; then tmux new-session -d -s "$sess" -n "$w" -c "${sel_cwd[$i]}"; first=0
      else tmux new-window -t "$sess" -n "$w" -c "${sel_cwd[$i]}"; fi
      tmux send-keys -t "$sess:$w" "$(resume_cmd "$i")" C-m
      [ "${sel_cli[$i]}" = "1" ] && tmux new-window -t "$sess" -n "$w-cli" -c "${sel_cwd[$i]}"
    done
    echo "tmux 会话 '$sess'：${#grp_idxs[@]} 个窗口"
  done
  local firstg="${chosen_groups%% *}"; firstg="${chosen_groups#* }"; firstg="${firstg%% *}"
  set -- $chosen_groups; local attach="claude-G$1"
  if [ -n "${TMUX:-}" ]; then echo "（已在 tmux 内，Ctrl-b s 切换会话）"
  else echo "attach 到 '$attach'（切换其他组: Ctrl-b s，分离: Ctrl-b d）"; tmux attach -t "$attach" 2>/dev/null || true; fi
}

launch_seq() {
  local i
  for i in "${chosen_idx[@]}"; do
    echo; echo ">>> ${sel_name[$i]} (${sel_cwd[$i]}) —— 退出后继续下一个"
    ( cd "${sel_cwd[$i]}" && $(resume_cmd "$i") ) || true
  done
}

# --- VSCode: exact-window bridge first, fixed-new-window as the only fallback
# Two independent paths, tried in order:
#
#   1. launch_vscode_bridge — talks to the exact-window Comate bridge server
#      (bridge/comate_bridge_client.py) over its per-window Unix socket, so
#      terminals land in the CURRENT window/tabs with no reload and no new
#      window at all. This is the preferred path whenever the bridge is
#      actually running in this window.
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
#      revalidated on every use; see
#      docs/superpowers/specs/2026-07-24-comate-terminal-bridge-design.md for
#      the full rationale.
#
#   2. launch_vscode_new_window — the pre-existing .code-workspace mechanism:
#      VSCode exposes no CLI to spawn/inject terminals in the current window
#      (checked: comate/code only do -n/-r/-a/-g), so parallel auto-launch
#      falls back to tasks with runOn:folderOpen in a brand NEW window opened
#      with a fixed `-n`. Constraints preserved:
#        a. Each session is its OWN independent terminal — NO
#           presentation.group, so they are separate terminals, never
#           split/child panes.
#        b. The opened window is ROOTED at the work folder (default:
#           penghaotian), via a self-contained *.code-workspace written in
#           THIS repo (overwritten each run); penghaotian/.vscode is never
#           touched.
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
#   RESUME_VSCODE_FOLDER   window root folder for the new-window fallback
#                          (default: penghaotian if it exists, else current dir)
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

  local deffolder="/root/paddlejob/workspace/env_run/penghaotian"
  [ -d "$deffolder" ] || deffolder="$PWD"
  local folder="${RESUME_VSCODE_FOLDER:-$deffolder}"
  python3 "$client" probe-paired --workspace-root "$folder" >/dev/null 2>&1 || return 2

  local i dangerous=0
  [ "${RESUME_SKIP_PERMISSIONS:-0}" = "1" ] && dangerous=1
  {
    for i in "${chosen_idx[@]}"; do
      printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
        resume "resume: ${sel_name[$i]} [${sel_time[$i]}]" "${sel_cwd[$i]}" \
        "$CLAUDE_CMD" "${sel_id[$i]}" "$dangerous"
      if [ "${sel_cli[$i]}" = "1" ]; then
        printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
          cli "cli: ${sel_name[$i]}" "${sel_cwd[$i]}" "${SHELL:-/bin/bash}" '' 0
      fi
    done
  } | python3 "$client" send-input0 --paired-workspace "$folder"
}

# --- fallback path: fixed -n, new window, no reuse/reload -------------------
launch_vscode_new_window() {
  local deffolder="/root/paddlejob/workspace/env_run/penghaotian"
  [ -d "$deffolder" ] || deffolder="$PWD"
  local folder="${RESUME_VSCODE_FOLDER:-$deffolder}"
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
    cmd="cd '${sel_cwd[$i]//\'/\'\\\'\'}' && $(resume_cmd "$i")"
    add_task "$label" "$cmd"
    [ "${sel_cli[$i]}" = "1" ] && add_task "cli: ${sel_name[$i]}" "cd '${sel_cwd[$i]//\'/\'\\\'\'}' && exec \$SHELL"
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
  echo "已写入 $wsfile （窗口根目录=$folder，${#chosen_idx[@]} 个独立终端，folderOpen 自动并行启动）。"
  cli="$(vscode_cli)"
  if [ -n "$cli" ]; then
    echo "新开独立窗口并自动拉起会话：$cli -n $wsfile"
    "$cli" -n "$wsfile" >/dev/null 2>&1 || echo "（打开失败，请手动在 VSCode 新窗口打开该 .code-workspace 文件）"
  else
    echo "未找到 VSCode/comate CLI。请手动在 VSCode 打开：$wsfile"
  fi
}

launch_vscode() {
  launch_vscode_bridge; local status=$?
  case "$status" in
    0) return 0 ;;
    2) launch_vscode_new_window ;;
    3|4) echo "bridge 请求可能已送达或已报告终端创建错误（退出码 $status），为避免重复终端不会新开窗口。" >&2; return "$status" ;;
    *) echo "bridge 客户端内部错误（退出码 $status），未启动备用窗口以避免重复终端。" >&2; return "$status" ;;
  esac
}

if [ "${RESUME_DRY_RUN:-}" = "1" ]; then
  echo "[dry-run] launch=$LAUNCH_MODE  选中 ${#chosen_idx[@]} 个，组:$chosen_groups"
  for i in "${chosen_idx[@]}"; do
    printf "  - G%s %s %s (%s)\n" "${sel_group[$i]}" "$([ "${sel_cli[$i]}" = 1 ] && echo +CLI || echo '    ')" "${sel_name[$i]}" "${sel_cwd[$i]}"
  done
  exit 0
fi

case "$LAUNCH_MODE" in
  vscode)   launch_vscode ;;
  terminal) [ "$UNAME" = "Darwin" ] && launch_terminal_mac || launch_terminal_linux ;;
  tmux)     launch_tmux ;;
  seq)      launch_seq ;;
  *)        launch_seq ;;
esac
