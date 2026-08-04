#!/usr/bin/env bash
set -Eeuo pipefail

# logs.sh — tail the Paperclip container logs.
# Usage:
#   ./scripts/logs.sh          # last 200 lines
#   ./scripts/logs.sh 500      # last 500 lines

# Re-exec inside the docker group if the current shell cannot reach dockerd.
if ! docker info >/dev/null 2>&1; then
  exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

LINES="${1:-200}"

"$SCRIPT_DIR/dc" logs --tail="$LINES" paperclip
