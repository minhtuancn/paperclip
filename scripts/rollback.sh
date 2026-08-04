#!/usr/bin/env bash
set -Eeuo pipefail

# rollback.sh — deploy a specific commit without touching data.
#
# Usage:
#   ./scripts/rollback.sh COMMIT_SHA
#
# Flow:
#   1. validate the commit exists
#   2. record current state + pre-rollback backup (./scripts/backup.sh)
#   3. checkout the commit onto a dedicated branch `rollback-<timestamp>`
#   4. build the image (old image kept, no pruning)
#   5. recreate the container and verify health
#   6. on failure: report and restore the previously running code
#
# Safety: never deletes /home/dev/data/paperclip, never uses `down -v`,
# never force-pushes or rewrites history.

# Re-exec inside the docker group if the current shell cannot reach dockerd.
if ! docker info >/dev/null 2>&1; then
  exec sg docker -c "$(printf '%q ' "$0" "$@")"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

COMPOSE=("$SCRIPT_DIR/dc")

HTTP_URL="${PAPERCLIP_PUBLIC_URL:-http://127.0.0.1:3100}"

fail() { echo "ERROR: $*" >&2; }

wait_healthy() {
  local tries=0
  while [ "$tries" -lt 40 ]; do
    if curl -fsS --max-time 5 "$HTTP_URL/api/health" 2>/dev/null | grep -q '"status":"ok"'; then
      return 0
    fi
    sleep 3
    tries=$((tries + 1))
  done
  return 1
}

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 COMMIT_SHA" >&2
  exit 1
fi

TARGET="$1"
if ! git rev-parse --verify --quiet "$TARGET^{commit}" >/dev/null; then
  fail "commit '$TARGET' does not exist in this repository."
  exit 1
fi
TARGET="$(git rev-parse "$TARGET^{commit}")"

# Record the currently running state so we can come back on failure.
CURRENT_COMMIT="$(git rev-parse HEAD)"
CURRENT_BRANCH="$(git branch --show-current)"
CURRENT_IMAGE="$(docker inspect -f '{{.Image}}' paperclip 2>/dev/null || true)"
echo "==> Current: branch=$CURRENT_BRANCH commit=$CURRENT_COMMIT image=${CURRENT_IMAGE:-none}"
echo "==> Target:  commit=$TARGET"

# Pre-rollback backup (data untouched either way, but this is free insurance).
echo "==> Pre-rollback backup"
"$SCRIPT_DIR/backup.sh"

TS="$(date +%Y%m%d-%H%M%S)"
RB_BRANCH="rollback-$TS"
echo "==> Checking out $TARGET on branch $RB_BRANCH"
git checkout -b "$RB_BRANCH" "$TARGET"

echo "==> Building image from $TARGET"
"${COMPOSE[@]}" build --pull

echo "==> Recreating container"
"${COMPOSE[@]}" up -d

if wait_healthy; then
  echo "==> Health OK. Running code is now commit $TARGET on branch $RB_BRANCH."
  echo "    To restore the previous code, run: ./scripts/rollback.sh $CURRENT_COMMIT"
  exit 0
fi

fail "rollback to $TARGET did not become healthy."
echo "==> Restoring previous code $CURRENT_COMMIT" >&2
git checkout -b "restore-${CURRENT_COMMIT:0:12}-$TS" "$CURRENT_COMMIT" 2>/dev/null || git checkout "$CURRENT_BRANCH"
"${COMPOSE[@]}" build --pull
"${COMPOSE[@]}" up -d
if wait_healthy; then
  echo "==> Restored previous code and health OK."
  exit 1
fi
fail "restore also failed to become healthy — investigate manually."
exit 1
