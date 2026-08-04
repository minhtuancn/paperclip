#!/usr/bin/env bash
set -Eeuo pipefail

# backup.sh — create a timestamped, consistent Paperclip backup.
#
# Strategy:
#   1. Online consistent database backup via the in-container CLI
#      (`pnpm paperclipai db:backup`, pg_dump/JS engine against embedded
#      PostgreSQL) — no downtime.
#   2. Online archive of the non-DB data directory (workspaces, uploads,
#      config, logs) excluding the embedded Postgres cluster.
#   3. Metadata file, retention (default: keep the 14 newest backups),
#   4. Verification that the files were actually created.
#
# Usage: ./scripts/backup.sh
# Env:   BACKUP_RETENTION_KEEP=<n>  (default 14)
#
# Safety: this script never stops the container, never uses `down -v`,
# and never touches /home/dev/data/paperclip beyond reading it.

# Re-exec inside the docker group if the current shell cannot reach dockerd.
if ! docker info >/dev/null 2>&1; then
  exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

DATA_DIR="${PAPERCLIP_DATA_DIR:-/home/dev/data/paperclip}"
BACKUP_ROOT="/home/dev/backups/paperclip"
RETENTION_KEEP="${BACKUP_RETENTION_KEEP:-14}"

COMPOSE=("$SCRIPT_DIR/dc")

fail() { echo "ERROR: $*" >&2; }

container_running() {
  "${COMPOSE[@]}" ps --status running 2>/dev/null | grep -q "paperclip"
}

# Safety net: make sure Paperclip is left running when we exit (even on error).
ensure_running() {
  if ! container_running; then
    echo "WARNING: paperclip container is not running after backup; restarting." >&2
    "${COMPOSE[@]}" up -d >&2 || true
  fi
}
trap ensure_running EXIT

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/paperclip-$TIMESTAMP"
mkdir -p "$BACKUP_DIR"
echo "==> Backup directory: $BACKUP_DIR"

# Make sure the container is up so the DB backup is against live data.
if ! container_running; then
  echo "==> Starting paperclip container for consistent backup"
  "${COMPOSE[@]}" up -d
  sleep 8
fi

# Metadata
IMAGE_ID="$(docker inspect -f '{{.Image}}' paperclip 2>/dev/null || true)"
{
  echo "paperclip-backup"
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(hostname)"
  echo "branch=$(git branch --show-current 2>/dev/null || echo unknown)"
  echo "commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "image_id=${IMAGE_ID:-unknown}"
  echo "compose_version=$("${COMPOSE[@]}" version 2>/dev/null | head -1 || echo unknown)"
} > "$BACKUP_DIR/METADATA.txt"

# 1) Consistent online DB backup via the in-container CLI.
echo "==> Creating consistent database backup (db:backup)"
DB_OUTPUT="$("${COMPOSE[@]}" exec --user node paperclip \
  pnpm paperclipai db:backup --dir /paperclip/backups --json 2>&1)" \
  || { fail "db:backup failed:"; printf '%s\n' "$DB_OUTPUT" >&2; exit 1; }

DB_BACKUP_FILE="$(printf '%s\n' "$DB_OUTPUT" \
  | grep -o '"backupFile": "[^"]*"' | head -1 \
  | sed 's/"backupFile": "//; s/"$//')"

if [ -z "$DB_BACKUP_FILE" ]; then
  printf '%s\n' "$DB_OUTPUT" >&2
  fail "could not determine the database backup file from CLI output"
  exit 1
fi

HOST_DB_FILE="${DATA_DIR}${DB_BACKUP_FILE#/paperclip}"
if [ ! -f "$HOST_DB_FILE" ]; then
  fail "database backup file not found on host: $HOST_DB_FILE"
  exit 1
fi
mv "$HOST_DB_FILE" "$BACKUP_DIR/"
echo "==> Database backup moved to: $BACKUP_DIR/$(basename "$DB_BACKUP_FILE")"

# 2) Archive the non-DB data directory (workspaces, uploads, config, logs).
TAR_FILE="$BACKUP_DIR/data-files.tar.gz"
echo "==> Archiving data directory (excluding embedded PostgreSQL data)"
tar --xattrs --acls -czf "$TAR_FILE" \
  -C /home/dev/data \
  --exclude="paperclip/instances/default/db" \
  --exclude="paperclip/instances/default/data/backups" \
  --exclude="paperclip/backups" \
  paperclip

# 3) Verify the backup files exist and are non-empty.
DB_ON_DISK="$(ls "$BACKUP_DIR"/*.sql.gz 2>/dev/null | head -1 || true)"
if [ -z "$DB_ON_DISK" ] || [ ! -s "$DB_ON_DISK" ]; then
  fail "database backup verification failed: missing or empty .sql.gz"
  exit 1
fi
if [ ! -s "$TAR_FILE" ]; then
  fail "data archive verification failed: missing or empty $TAR_FILE"
  exit 1
fi

# 4) Retention: keep the $RETENTION_KEEP newest backups.
mapfile -t OLD_BACKUPS < <(ls -1dt "$BACKUP_ROOT"/paperclip-* 2>/dev/null | tail -n +$((RETENTION_KEEP + 1)))
if [ "${#OLD_BACKUPS[@]}" -gt 0 ]; then
  echo "==> Pruning ${#OLD_BACKUPS[@]} old backup(s) (retention: $RETENTION_KEEP)"
  for old in "${OLD_BACKUPS[@]}"; do
    rm -rf "$old"
  done
fi

# 5) Final health confirmation.
HEALTH="$(curl -fsS --max-time 10 "http://127.0.0.1:3100/api/health" 2>/dev/null || echo unreachable)"
if printf '%s' "$HEALTH" | grep -q '"status":"ok"'; then
  echo "==> Health: OK"
else
  echo "WARNING: health check did not confirm OK (${HEALTH})" >&2
fi

echo
echo "==> Backup completed: $BACKUP_DIR"
du -sh "$BACKUP_DIR"
