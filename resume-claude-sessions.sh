#!/usr/bin/env bash
# Claude Code entry point — kept as a stable, documented filename.
# The implementation lives in resume-sessions.sh, shared with the Codex
# launcher so the picker, quoting and launch rules cannot drift apart.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RESUME_PROVIDER="${RESUME_PROVIDER:-claude}"
exec bash "$SCRIPT_DIR/resume-sessions.sh" "$@"
