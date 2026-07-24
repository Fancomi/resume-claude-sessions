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

# Same safe lookup style as resume-claude-sessions.sh's vscode_cli() (command -v),
# restricted to the Comate CLI only (this installer targets Comate exclusively).
COMATE_CLI="$(command -v comate 2>/dev/null || true)"
if [ -z "$COMATE_CLI" ]; then
  echo "未找到 comate CLI，无法安装扩展。" >&2
  exit 1
fi

"$COMATE_CLI" --install-extension "$VSIX" --force
INSTALL_STATUS=$?
if [ "$INSTALL_STATUS" -ne 0 ]; then
  echo "扩展安装失败（退出码 $INSTALL_STATUS）。" >&2
  exit "$INSTALL_STATUS"
fi

echo "扩展已安装；未重载任何窗口。请在下次自然重启 Comate 后使用当前窗口追加终端。"
