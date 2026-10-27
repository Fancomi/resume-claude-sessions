#!/usr/bin/env bash
# Pair the sole live Comate bridge socket with the current window, using
# explicit user confirmation.
#
# This script only ever runs:
#   python3 bridge/comate_bridge_client.py pair --workspace-root ... \
#     --confirmed-current-window
#
# It never invokes comate/code, never passes any reuse-window or reload-
# window flag, and never creates a terminal. The user must know, from
# having just observed their own single window, that exactly one live
# bridge socket exists and that it belongs to that window; this script does
# not and cannot verify that on its own — it only records the pairing the
# user is confirming.
#
# Usage:
#   scripts/pair-comate-bridge.sh --confirmed-current-window
#
# Env:
#   RESUME_VSCODE_FOLDER   workspace root to pair (default: current directory)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "${1:-}" != "--confirmed-current-window" ]; then
  echo "用法: $0 --confirmed-current-window" >&2
  echo "该标志确认：当前只有一个存活的桥接 socket，且它属于你现在正在使用的这个窗口。" >&2
  exit 1
fi

FOLDER="${RESUME_VSCODE_FOLDER:-$PWD}"

python3 "$ROOT/bridge/comate_bridge_client.py" pair \
  --workspace-root "$FOLDER" \
  --confirmed-current-window
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
  echo "已配对：工作区 $FOLDER 绑定到当前唯一存活的桥接 socket。"
  echo "该确认仅对当前存活的扩展主机 PID 有效，一旦该 PID 变化（例如 Comate 重启），配对会自动失效，需要重新运行本脚本确认。"
else
  echo "配对失败（退出码 $STATUS）：可能不存在恰好一个存活的桥接 socket，或工作区目录不存在。" >&2
fi

exit "$STATUS"
