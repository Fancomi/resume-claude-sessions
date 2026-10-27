#!/usr/bin/env bash
# Codex entry point. Scans CODEX_HOME/sessions (default ~/.codex/sessions) and
# resumes with `codex resume <id> --cd <cwd>`. Shares resume-sessions.sh with
# the Claude launcher.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RESUME_PROVIDER="${RESUME_PROVIDER:-codex}"
exec bash "$SCRIPT_DIR/resume-sessions.sh" "$@"
