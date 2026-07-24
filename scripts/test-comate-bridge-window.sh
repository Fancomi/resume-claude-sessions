#!/usr/bin/env bash
# Isolated integration test for the Comate exact-window terminal bridge.
#
# WHAT THIS SCRIPT DOES: opens exactly ONE brand-new Comate window (via
# `comate -n`, never `-r`/reuse/reload) rooted at a fresh temporary
# workspace, waits for that new window's bridge socket to appear, sends it
# one test request (two harmless terminals), and leaves the new window open
# for manual inspection. It never touches, closes, or reloads the window
# this script is invoked from, and it never closes any window itself.
#
# SAFETY GUARD: refuses to run at all unless invoked with
#   --i-understand-this-opens-a-new-test-window
#
# This script is for manual, authorized verification only. It is not part of
# the normal resume-claude-sessions.sh launch flow and is never invoked by
# it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT="$ROOT/bridge/comate_bridge_client.py"

GUARD_FLAG="--i-understand-this-opens-a-new-test-window"
if [ "${1:-}" != "$GUARD_FLAG" ]; then
  echo "This script opens a brand-new Comate test window. Re-run with:" >&2
  echo "  $0 $GUARD_FLAG" >&2
  exit 1
fi

# --- discover the comate/code CLI, same safe discovery order as the launcher
find_comate_cli() {
  local srv c fallback=""
  if [ -n "${VSCODE_GIT_ASKPASS_NODE:-}" ]; then
    srv="$(dirname "$VSCODE_GIT_ASKPASS_NODE")/bin/remote-cli"
    if [ -d "$srv" ]; then
      for c in "$srv"/*; do
        [ -x "$c" ] || continue
        if [ "$(basename "$c")" = "comate" ]; then
          echo "$c"
          return
        fi
        [ -z "$fallback" ] && fallback="$c"
      done
      if [ -n "$fallback" ]; then
        echo "$fallback"
        return
      fi
    fi
  fi
  for c in comate code code-insiders; do
    command -v "$c" >/dev/null 2>&1 && { command -v "$c"; return; }
  done
}

COMATE_CLI="$(find_comate_cli)"
if [ -z "$COMATE_CLI" ]; then
  echo "未找到 comate/code CLI，无法运行隔离测试。" >&2
  exit 1
fi

if [ ! -f "$CLIENT" ]; then
  echo "未找到桥接客户端：$CLIENT" >&2
  exit 1
fi

# --- record and exclude the ORIGINAL window's identity/socket BEFORE opening
# anything, so the new-socket search below can never mistake the invoking
# window's own (already-running) bridge for the freshly opened test window.
ORIGINAL_IPC="${VSCODE_IPC_HOOK_CLI:-}"
ORIGINAL_IDENTITY=""
ORIGINAL_SOCKET=""
if [ -n "$ORIGINAL_IPC" ]; then
  ORIGINAL_IDENTITY="$(python3 -c "
import hashlib, sys
print(hashlib.sha256(sys.argv[1].encode('utf-8')).hexdigest()[:24])
" "$ORIGINAL_IPC")"
  RUNTIME_DIR="$(python3 -c "
import tempfile, os
print(os.path.join(tempfile.gettempdir(), 'resume-claude-sessions-%d' % os.getuid()))
")"
  ORIGINAL_SOCKET="$RUNTIME_DIR/bridge-$ORIGINAL_IDENTITY.sock"
else
  RUNTIME_DIR="$(python3 -c "
import tempfile, os
print(os.path.join(tempfile.gettempdir(), 'resume-claude-sessions-%d' % os.getuid()))
")"
fi

echo "原窗口身份（将被排除，绝不会成为测试目标）：ORIGINAL_IDENTITY=${ORIGINAL_IDENTITY:-<无，当前不在 VSCode/Comate 终端中>}"
echo "原窗口 socket（将被排除）：ORIGINAL_SOCKET=${ORIGINAL_SOCKET:-<无>}"

# --- create a throwaway temporary workspace with a marker file and settings
# that enable the installed extension (extensions are enabled by default
# once installed; no special settings are required to activate it, but we
# still write a marker + minimal settings so the workspace is self-describing
# and easy to identify as test-only).
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/comate-bridge-test.XXXXXX")"
mkdir -p "$TEST_DIR/.vscode"
cat > "$TEST_DIR/MARKER-bridge-test.txt" <<EOF
This is a disposable workspace created by
scripts/test-comate-bridge-window.sh for isolated Comate bridge testing.
Safe to delete. Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
cat > "$TEST_DIR/.vscode/settings.json" <<'EOF'
{
  "extensions.autoUpdate": false
}
EOF

echo "已创建隔离测试工作区：$TEST_DIR"

# --- open exactly one new window, rooted at the test dir. NEVER -r/reuse.
echo "打开新测试窗口：$COMATE_CLI -n $TEST_DIR"
"$COMATE_CLI" -n "$TEST_DIR" >/dev/null 2>&1 &
COMATE_PID=$!
disown "$COMATE_PID" 2>/dev/null || true

# --- poll the private runtime directory for a NEW bridge socket that is not
# the original window's socket. Refuse to proceed unless exactly one new live
# socket appears.
POLL_SECONDS="${BRIDGE_TEST_POLL_SECONDS:-20}"
POLL_INTERVAL="0.5"
TEST_SOCKET=""
elapsed=0
while [ "$(echo "$elapsed < $POLL_SECONDS" | python3 -c 'import sys; a,b=sys.stdin.read().split("<"); print(1 if float(a)<float(b) else 0)')" = "1" ]; do
  candidates=()
  if [ -d "$RUNTIME_DIR" ]; then
    for candidate in "$RUNTIME_DIR"/bridge-*.sock; do
      [ -e "$candidate" ] || continue
      if [ "$candidate" = "$ORIGINAL_SOCKET" ]; then continue; fi
      candidates+=("$candidate")
    done
  fi
  if [ "${#candidates[@]}" -eq 1 ]; then
    TEST_SOCKET="${candidates[0]}"
    break
  elif [ "${#candidates[@]}" -gt 1 ]; then
    echo "发现多个新 socket，无法确定唯一测试窗口，拒绝继续：${candidates[*]}" >&2
    exit 1
  fi
  sleep "$POLL_INTERVAL"
  elapsed="$(echo "$elapsed + $POLL_INTERVAL" | python3 -c 'import sys; a,b=sys.stdin.read().split("+"); print(float(a)+float(b))')"
done

if [ -z "$TEST_SOCKET" ]; then
  echo "在 ${POLL_SECONDS}s 内未观察到恰好一个新的桥接 socket，拒绝继续（未新建终端）。" >&2
  echo "请确认扩展已安装且新窗口已完全加载。" >&2
  exit 1
fi

echo "发现唯一新测试 socket：TEST_SOCKET=$TEST_SOCKET"

# --- derive the test window's identity from the socket filename, and its
# metadata file, to compare against later terminal-reported IPC hashes.
TEST_IDENTITY="$(basename "$TEST_SOCKET" .sock)"
TEST_IDENTITY="${TEST_IDENTITY#bridge-}"

# --- send the test request via the explicit test-only --socket override.
# This override requires BOTH --test-mode and a socket beneath the private
# runtime directory; it is never used by the normal launcher flow (which
# always derives the socket from --ipc-hook only).
echo "发送测试请求到新窗口（两个独立终端）..."
{
  printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
    cli "bridge-test-identity" "$TEST_DIR" \
    "/bin/sh" '' 0
  printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
    cli "bridge-test-second" "$TEST_DIR" \
    "/bin/sh" '' 0
} | python3 "$CLIENT" send-input0 \
  --ipc-hook "test-window-$TEST_IDENTITY" \
  --test-mode \
  --socket "$TEST_SOCKET"
SEND_STATUS=$?

if [ "$SEND_STATUS" -ne 0 ]; then
  echo "测试请求未成功送达新窗口（退出码 $SEND_STATUS）。测试窗口仍保持打开以供检查。" >&2
  exit "$SEND_STATUS"
fi

echo "测试请求已送达；新窗口应已出现两个终端（bridge-test-identity, bridge-test-second）。"
echo "注意：上面创建的终端运行的是普通 shell（/bin/sh），不会自动打印 IPC hash 文件；"
echo "如需人工核对 IPC 一致性，请在新窗口的任一终端手动执行："
echo "  echo \"\$VSCODE_IPC_HOOK_CLI\" | sha256sum | cut -c1-24"
echo "并确认其输出等于：$TEST_IDENTITY"

echo
echo "验证结果："
echo "  - 原窗口 socket 被排除：$([ -n "$ORIGINAL_SOCKET" ] && echo "是（$ORIGINAL_SOCKET）" || echo "N/A（当前非 VSCode/Comate 终端）")"
echo "  - 新窗口 socket（唯一）：$TEST_SOCKET"
echo "  - 测试请求送达：是（退出码 0）"
echo
echo "测试窗口保持打开状态，供人工检查；本脚本不会关闭任何窗口。"
echo "临时测试工作区：$TEST_DIR（可手动删除）"
