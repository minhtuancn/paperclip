#!/usr/bin/env bash
set -Eeuo pipefail

# update.sh — safely sync the fork with upstream and redeploy Paperclip.
#
# Flow (unless --check):
#   1. verify working tree is clean
#   2. fetch origin + upstream
#   3. record current commit + image for rollback
#   4. run ./scripts/backup.sh (pre-update backup)
#   5. fast-forward master from upstream/master, push origin/master
#   6. checkout production, merge --no-ff master
#   7. build the new image (old image is NOT deleted)
#   8. recreate the container and verify health
#   9. on failure: auto-rollback to the previously recorded commit/image
#
# Modes:
#   ./scripts/update.sh           full update
#   ./scripts/update.sh --check   fetch + diff report only (no changes)
#
# Safety: no `git reset --hard` on a dirty tree, no `docker system prune -a`,
# no `down -v`, old images are preserved for rollback.

# Re-exec inside the docker group if the current shell cannot reach dockerd.
if ! docker info >/dev/null 2>&1; then
  exec sg docker "$0" "$@"
fi

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

COMPOSE=(docker compose --env-file .env
  -f docker/docker-compose.quickstart.yml
  -f docker/docker-compose.production.yml)

CONTAINER_NAME="paperclip"
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

rollback() {
  local target_commit="$1"
  local ts rollback_branch
  ts="$(date +%Y%m%d-%H%M%S)"
  rollback_branch="rollback-$ts"
  echo "==> ROLLBACK: restoring code from $target_commit"
  git checkout -b "$rollback_branch" "$target_commit"
  echo "==> ROLLBACK: building image from $target_commit"
  "${COMPOSE[@]}" build --pull
  echo "==> ROLLBACK: starting container"
  "${COMPOSE[@]}" up -d
  if wait_healthy; then
    echo "==> ROLLBACK: health OK on branch $rollback_branch ($target_commit)"
  else
    fail "rollback deployment did not become healthy — investigate manually."
    exit 1
  fi
}

CHECK_MODE=0
for arg in "$@"; do
  if [ "$arg" = "--check" ]; then CHECK_MODE=1; fi
done

# --- 1. working tree -------------------------------------------------------
if [ "$CHECK_MODE" -eq 0 ] && [ -n "$(git status --porcelain)" ]; then
  fail "working tree is not clean. Commit or stash changes first."
  git status --short
  exit 1
fi

# --- 2. fetch --------------------------------------------------------------
echo "==> Fetching origin and upstream"
git fetch origin --prune --tags
git fetch upstream --prune --tags

LEFT_RIGHT="$(git rev-list --left-right --count origin/master...upstream/master 2>/dev/null || echo "0 0")"
echo "origin/master vs upstream/master (ahead behind): $LEFT_RIGHT"
AHEAD="$(printf '%s\n' "$LEFT_RIGHT" | awk '{print $1}')"
BEHIND="$(printf '%s\n' "$LEFT_RIGHT" | awk '{print $2}')"

echo
echo "==> New upstream commits:"
git log --oneline --no-merges origin/master..upstream/master | head -30 || true

if [ "$CHECK_MODE" -eq 1 ]; then
  echo
  echo "==> --check mode: nothing was changed (no merge, no build, no restart)."
  exit 0
fi

if [ "$BEHIND" -eq 0 ]; then
  echo "==> Already up to date with upstream/master. Nothing to deploy."
  exit 0
fi

if [ "$AHEAD" -ne 0 ]; then
  fail "origin/master has $AHEAD commit(s) not in upstream — refusing to overwrite."
  fail "Reconcile origin/master with upstream manually, then re-run."
  exit 1
fi

# --- 3. record rollback point ---------------------------------------------
OLD_COMMIT="$(git rev-parse HEAD)"
OLD_IMAGE="$("${COMPOSE[@]}" images -q paperclip 2>/dev/null | head -1 || true)"
echo "==> Rollback point: commit=$OLD_COMMIT image=${OLD_IMAGE:-none}"

# --- 4. pre-update backup --------------------------------------------------
echo "==> Pre-update backup"
"$SCRIPT_DIR/backup.sh"

# --- 5. fast-forward master from upstream, push ----------------------------
echo "==> Fast-forwarding master from upstream/master"
git checkout master
git pull --ff-only upstream master
git push origin master

# --- 6. merge into production ---------------------------------------------
echo "==> Merging master into production (--no-ff)"
git checkout production
git pull --ff-only origin production

CONFLICTS=""
if ! git merge --no-ff master -m "chore(deploy): sync upstream $(git rev-parse --short upstream/master)"; then
  CONFLICTS="$(git diff --name-only --diff-filter=U)"
  echo "ERROR: merge conflicts in:"
  printf '%s\n' "$CONFLICTS"
  echo "Aborting merge — the running Paperclip is untouched and keeps serving."
  git merge --abort
  fail "resolve the conflicts on branch 'production', then re-run ./scripts/update.sh"
  exit 1
fi

# --- 7. build (old image preserved) ----------------------------------------
echo "==> Building new image (old image $OLD_IMAGE kept for rollback)"
"${COMPOSE[@]}" build --pull

# --- 8. deploy --------------------------------------------------------------
echo "==> Recreating container"
"${COMPOSE[@]}" up -d

if wait_healthy; then
  echo "==> Health OK. Paperclip updated."
  "${COMPOSE[@]}" ps
  git log --oneline -3
  exit 0
fi

# --- 9. auto-rollback -------------------------------------------------------
echo "ERROR: new deployment did not become healthy. Rolling back to $OLD_COMMIT" >&2
git checkout production
rollback "$OLD_COMMIT"
