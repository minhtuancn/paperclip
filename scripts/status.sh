#!/usr/bin/env bash
set -Eeuo pipefail

# status.sh — print deployment status for the Paperclip instance on this host.
# Usage: ./scripts/status.sh

# Re-exec inside the docker group if the current shell cannot reach dockerd.
if ! docker info >/dev/null 2>&1; then
  exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

COMPOSE=("$SCRIPT_DIR/dc")

DATA_DIR="${PAPERCLIP_DATA_DIR:-/home/dev/data/paperclip}"
PUBLIC_URL="${PAPERCLIP_PUBLIC_URL:-http://127.0.0.1:3100}"

echo "== Repository =="
git -C "$PROJECT_DIR" branch --show-current
git -C "$PROJECT_DIR" rev-parse --short HEAD
git -C "$PROJECT_DIR" log -1 --format="%h %ad %s" --date=short 2>/dev/null || true
echo

echo "== Sync with upstream =="
git -C "$PROJECT_DIR" fetch --quiet upstream 2>/dev/null || true
LEFT_RIGHT=$(git -C "$PROJECT_DIR" rev-list --left-right --count origin/master...upstream/master 2>/dev/null || echo "?")
echo "origin/master vs upstream/master (ahead behind): $LEFT_RIGHT"
echo

echo "== Containers =="
"${COMPOSE[@]}" ps || true
echo

echo "== HTTP health =="
if curl -fsS -o /dev/null --max-time 5 "$PUBLIC_URL/api/health"; then
  echo "HTTP $PUBLIC_URL/api/health -> OK"
  curl -fsS --max-time 5 "$PUBLIC_URL/api/health" | python3 -m json.tool 2>/dev/null \
    | grep -E '"status"|"bootstrapStatus"|"deploymentMode"' || true
else
  echo "HTTP $PUBLIC_URL/api/health -> FAILED" >&2
  exit 1
fi
echo

echo "== Data directory =="
du -sh "$DATA_DIR" 2>/dev/null || true
ls -ld "$DATA_DIR" 2>/dev/null || true
echo

echo "== Backup directory =="
du -sh /home/dev/backups/paperclip 2>/dev/null || true
ls -1 /home/dev/backups/paperclip 2>/dev/null | tail -5 || true
