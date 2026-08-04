# Paperclip — Deployment & Operations Guide

Instance: `http://10.20.10.128:3100` (LAN only)
Last updated: 2026-08-04

---

## 1. Architecture

```
User (LAN) ──> http://10.20.10.128:3100 ──> Docker container "paperclip"
                                              │  embedded PostgreSQL  (in /paperclip)
                                              │  static UI + server   (Express, :3100)
                                              ▼
                              bind mount: /home/dev/data/paperclip → /paperclip
```

- **Single container** built from the official Paperclip Dockerfile.
- **Embedded PostgreSQL** lives inside `/paperclip/instances/default/db`, which is
  a bind mount to `/home/dev/data/paperclip` on the host — data survives
  container recreation.
- Two Compose files are always used together:
  - `docker/docker-compose.quickstart.yml` (upstream, untouched)
  - `docker/docker-compose.production.yml` (our override: UID/GID build args,
    `restart: unless-stopped`, extra env)
- Configuration is provided via `.env` (never committed).

## 2. Key values

| Item            | Value                                          |
|-----------------|------------------------------------------------|
| Host IP         | `10.20.10.128` (LAN, eth0)                     |
| Port            | `3100`                                         |
| Public URL      | `http://10.20.10.128:3100`                     |
| Allowed hosts   | `10.20.10.128`, `paper.go7s.net` (future)      |
| Source          | `/home/dev/apps/paperclip`                     |
| Data            | `/home/dev/data/paperclip`                     |
| Backups         | `/home/dev/backups/paperclip`                  |
| Container name  | `paperclip`                                    |
| Service account | `dev` (uid/gid `1000:1000`)                    |

## 3. Git remotes

```
origin   = https://github.com/minhtuancn/paperclip.git   (fork)
upstream = https://github.com/paperclipai/paperclip.git  (official)
```

Branch model:

```
upstream/master  ──ff──>  origin/master  ──merge--no-ff──>  origin/production  ──> host
```

- `master` is a clean mirror of upstream (fast-forward only).
- `production` is what actually runs on this machine; it holds deployment
  files (`docker/docker-compose.production.yml`, `Makefile`, `scripts/*`,
  `.gitignore`, `.env.example`, `DEPLOYMENT.md`).
- `.env`, `data/`, `backups/`, `*.log` are ignored and never committed.

## 4. Service control

All commands run as `dev` from `/home/dev/apps/paperclip`.

```bash
make up          # start / recreate the container
make down        # stop (NEVER use `docker compose down -v`)
make restart     # restart the paperclip container
make status      # branch/commit/container/health/data-size summary
make logs        # tail 200 lines
./scripts/logs.sh 500   # tail 500 lines
```

Manual form (the Makefile runs the same thing):

```bash
docker compose --env-file .env \
  -f docker/docker-compose.quickstart.yml \
  -f docker/docker-compose.production.yml \
  up -d
```

After `docker compose restart`, environment changes from `.env` are **not**
applied — environment is fixed at container creation. To apply `.env` changes
use `make up` (recreates the container).

## 5. Backups

`./scripts/backup.sh` (or `make backup`):

1. Online, consistent database dump via the in-container CLI
   (`pnpm paperclipai db:backup`, pg_dump/JS engine against embedded PG) —
   **no downtime**.
2. Online archive of the non-DB data directory (workspaces, uploads, config,
   logs) excluding the embedded PostgreSQL cluster.
3. Metadata file (`METADATA.txt`: date, host, branch, commit, image id,
   compose version).
4. Retention: keeps the 14 newest backups (override: `BACKUP_RETENTION_KEEP`).
5. Verifies the files exist, returns non-zero on failure, and always leaves
   Paperclip running.

Backups land in `/home/dev/backups/paperclip/paperclip-<timestamp>/`:
`<db>.sql.gz` + `data-files.tar.gz` + `METADATA.txt`.

## 6. Restore (DR)

Data is NEVER deleted. Restore is two parts:

**Database** (the `.sql.gz` file is a plain pg_dump):

```bash
# 1. stop the container
docker compose --env-file .env \
  -f docker/docker-compose.quickstart.yml \
  -f docker/docker-compose.production.yml \
  stop paperclip

# 2. restore the dump into the embedded postgres data dir, e.g.:
#    (run inside the container; the embedded PG must be started by the server,
#     so restore into a fresh cluster then start once)
docker compose ... start paperclip
#    if needed, drop/recreate + `gunzip -c BACKUP.sql.gz | psql postgres://paperclip:paperclip@127.0.0.1:54329/paperclip`
```

Because the app manages schema itself, the safest restore is:

1. Backup the current (bad) state first.
2. Move `/home/dev/data/paperclip/instances/default/db` aside (do not delete).
3. `make up` — a fresh embedded PG cluster is initialized and migrations applied.
4. `gunzip -c <backup>.sql.gz | psql ...` to load the data.
5. `make restart`, verify `make status`.

**Files** (workspaces/uploads/skills):

```bash
tar -xzf /home/dev/backups/paperclip/paperclip-<ts>/data-files.tar.gz -C /home/dev
```

Always keep the current copy before touching anything.

## 7. Update (sync fork + redeploy)

`./scripts/update.sh` (or `make update`) automates the safe path:

1. Verifies the working tree is clean.
2. Fetches `origin` and `upstream`.
3. Records current commit + image id for rollback.
4. Runs `./scripts/backup.sh`.
5. Fast-forwards `master` from `upstream/master` and pushes `origin/master`.
6. Merges `master` into `production` with `--no-ff`.
7. Builds the new image (old image kept for rollback).
8. Recreates the container and waits for health.
9. If health fails: auto-rollback to the previous commit/image.

Dry-run / check only (no changes):

```bash
./scripts/update.sh --check    # or make update-check
```

If `origin/master` has diverged from upstream, the script refuses to
fast-forward — reconcile manually, then re-run.

## 8. Rollback

```bash
./scripts/rollback.sh <COMMIT_SHA>
```

- Backs up current state first.
- Checks out the commit on a dedicated branch `rollback-<timestamp>`.
- Builds, recreates, waits for health; restores previous code if it fails.
- Never deletes data.

To see candidate commits: `git log --oneline --all --graph -30`.

## 9. Handling merge conflicts during update

`update.sh` merges `master` into `production`. If it conflicts it **stops**,
aborts the merge (leaving the running Paperclip untouched), and prints the
conflicting files. Resolve by hand:

```bash
git checkout production
git pull --ff-only origin production
git merge --no-ff master      # resolve files in $EDITOR
git add <resolved files>
git commit
./scripts/update.sh            # re-run; it will build and deploy
```

Prefer keeping customizations small and in dedicated files (e.g.
`docker/docker-compose.production.yml`, `scripts/*`) so conflicts with
upstream are rare.

## 10. Adding an LLM API key

1. Edit `/home/dev/apps/paperclip/.env` (chmod 600; never commit it):
   ```
   OPENAI_API_KEY=sk-...
   ANTHROPIC_API_KEY=sk-ant-...
   GEMINI_API_KEY=AIza...
   ```
2. `make up` (recreates container to apply env).
3. `make status` to confirm health; check `make logs` for adapter status.

Paperclip starts fine with all keys empty — the adapters report missing
credentials.

## 11. Changing IP / domain

Current: `http://10.20.10.128:3100`. To later serve `paper.go7s.net`:

1. Point DNS `paper.go7s.net` → `10.20.10.128`.
2. Optionally run a reverse proxy (Caddy/nginx) on the host terminating
   `https://paper.go7s.net` and forwarding to `127.0.0.1:3100`.
3. In `.env`:
   ```
   PAPERCLIP_PUBLIC_URL=https://paper.go7s.net
   PAPERCLIP_ALLOWED_HOSTNAMES=10.20.10.128,paper.go7s.net
   ```
   (`paper.go7s.net` is already in the allowed-hostname allowlist, so the
   container already accepts that Host header — see section 12.)
4. `make up`, then `make status`.

Do not switch `PAPERCLIP_PUBLIC_URL` to a domain that does not yet resolve to
this machine — auth base URLs would break.

## 12. Hostname allowlist

The server (authenticated/private mode) rejects unknown Host headers with
`403`. The allowlist comes from `PAPERCLIP_ALLOWED_HOSTNAMES` in `.env` plus
the hostname of `PAPERCLIP_PUBLIC_URL`. `paper.go7s.net` is already allowed so
a future domain switch needs no container env change.

## 13. Golden rules

- **Never** run `docker compose down -v` — it deletes the named volume/bind
  setup and can destroy data.
- **Never** delete `/home/dev/data/paperclip` or run `rm -rf` on it.
- **Never** force-push, `git reset --hard` a branch with uncommitted changes,
  or overwrite `origin/master` when it has local commits.
- **Never** commit `.env`, database dumps, logs, uploads, or secrets.
- **Never** open port 3100 to the public Internet; keep UFW (if enabled)
  limited to the LAN subnet, e.g. `sudo ufw allow from 10.20.10.0/24 to any
  port 3100 proto tcp`.
- **Never** run `docker system prune -a`; keep at least one rollback image.

## 14. UID/GID checks

The container remaps its `node` user to the host account via `USER_UID` /
`USER_GID` (both `1000` for `dev`). Verify:

```bash
id -u dev; id -g dev            # should match USER_UID / USER_GID in .env
ls -ld /home/dev/data/paperclip # owner dev:dev
docker exec paperclip id node   # inside container, node should be uid/gid 1000
```

If you ever change the service account, update `.env` and re-run `make up`.
Do not use `chmod -R 777` as a shortcut.

## 15. Known notes / open items

- The in-container backup engine falls back to a JavaScript dump when
  `pg_dump` is absent from the image (still consistent).
- No reverse proxy/TLS yet — LAN HTTP only by design for now.
- `docker/system prune` style cleanup is intentionally excluded.
- The pre-deployment LXC rootfs was 7.8G and is now 38G (resized on the
  Proxmox host via `pct resize`).
