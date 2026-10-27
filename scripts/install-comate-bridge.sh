#!/usr/bin/env bash
# Install the Comate bridge extension WITHOUT reloading or reusing any window.
#
# This script only ever runs:
#   "$COMATE_CLI" --install-extension "$VSIX" --force
#
# No window-reuse flag, no new-window flag, and no reload-window command are
# ever passed, and the generated workspace file is never opened. The
# extension activates the next time Comate restarts naturally; this script
# does not force that restart.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

python3 "$ROOT/scripts/package-comate-bridge.py"
PACKAGE_STATUS=$?
if [ "$PACKAGE_STATUS" -ne 0 ]; then
  echo "打包失败：scripts/package-comate-bridge.py 退出码 $PACKAGE_STATUS" >&2
  exit "$PACKAGE_STATUS"
fi

VSIX="$ROOT/dist/resume-claude-sessions-bridge-0.1.0.vsix"
if [ ! -f "$VSIX" ]; then
  echo "未找到打包产物：$VSIX" >&2
  exit 1
fi

# Same safe discovery order as resume-sessions.sh's vscode_cli(): if
# VSCODE_GIT_ASKPASS_NODE is set, look for an executable entry (preferring
# "comate" if present) under its sibling server/bin/remote-cli directory —
# this is the usable CLI in a remote-container session where no CLI is on
# PATH at all. Otherwise fall back to a plain PATH lookup for comate, then
# code, then code-insiders. Only ever used to resolve a path; never invokes
# -n, -r, reuse, reload, or any workspace command.
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
  echo "未找到 comate CLI，无法安装扩展。" >&2
  exit 1
fi

# Test-only escape hatch: print the resolved CLI path and exit before ever
# invoking it, so installer tests can verify discovery without touching a
# real Comate/VS Code binary.
if [ -n "${PROBE_ONLY:-}" ]; then
  echo "$COMATE_CLI"
  exit 0
fi

"$COMATE_CLI" --install-extension "$VSIX" --force
INSTALL_STATUS=$?
if [ "$INSTALL_STATUS" -ne 0 ]; then
  echo "扩展安装失败（退出码 $INSTALL_STATUS）。" >&2
  exit "$INSTALL_STATUS"
fi

echo "扩展已安装；未重载任何窗口。请在下次自然重启 Comate 后使用当前窗口追加终端。"
