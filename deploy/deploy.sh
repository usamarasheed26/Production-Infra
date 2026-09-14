#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# StratagemEngine production deploy — one script, driven by a per-app manifest.
#
#   deploy.sh <AppDir> [--check]
#
#     <AppDir>   directory name under /opt/apps  (e.g. platform, AIEnterpriseTransformation)
#     --check    validate only: manifest + `docker compose config` + git fetch.
#                No build, no restart, no production change.
#
# Reads /opt/apps/<AppDir>/.deploy.json (see deploy/manifests/*.json in the
# Production Infrastructure repo). Serializes ALL deploys via a global flock
# (the box has an OOM-from-concurrent-build incident history). Builds first
# (a build failure never touches running containers), then `up -d`, then the
# manifest's migrate step, then an HTTPS health gate. Any failure after the
# build rolls the app back to the previously-running images and exits non-zero.
#
# Secrets: this script NEVER reads or writes app .env files. They live only on
# the box, gitignored in every repo. A release needing a new env var = update
# the box .env first (see 10-SEPT-2026-PRODUCTION-DEPLOYMENT.md §14).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

APPS_ROOT="${APPS_ROOT:-/opt/apps}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-/opt/backups/run-backup.sh}"
LOCK="$APPS_ROOT/.deploy.lock"
HISTORY="$APPS_ROOT/.deploy-history.log"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"     # seconds to wait for health
BUILD_CACHE_KEEP_GB="${BUILD_CACHE_KEEP_GB:-15}"

APP="${1:-}"
MODE="${2:-deploy}"
[ -n "$APP" ] || { echo "usage: deploy.sh <AppDir> [--check]" >&2; exit 2; }

APP_DIR="$APPS_ROOT/$APP"
MANIFEST="$APP_DIR/.deploy.json"
START_TS=$SECONDS

log()  { printf '%s  %s\n' "$(date -Is)" "$*"; }
die()  { log "ERROR: $*"; exit 1; }

command -v jq     >/dev/null || die "jq is not installed on the box"
command -v docker >/dev/null || die "docker not found"
[ -d "$APP_DIR" ]        || die "$APP_DIR does not exist"
[ -d "$APP_DIR/.git" ]   || die "$APP_DIR is not a git checkout — Phase 0 (repo reconciliation) not done for '$APP'"
[ -f "$MANIFEST" ]       || die "no manifest at $MANIFEST"

BRANCH=$(jq -r '.branch'                 "$MANIFEST")
DOMAIN=$(jq -r '.domain            // ""' "$MANIFEST")
HEALTH_PATH=$(jq -r '.healthPath   // "/"' "$MANIFEST")
MIGRATE=$(jq -r '.migrate          // ""' "$MANIFEST")
mapfile -t COMPOSE_ARGS < <(jq -r '.compose[]'          "$MANIFEST")
mapfile -t ENV_ARGS     < <(jq -r '(.envFlags   // [])[]' "$MANIFEST")
mapfile -t HEALTH_CODES < <(jq -r '(.healthCodes // ["200"])[]' "$MANIFEST")
[ -n "$BRANCH" ] && [ "$BRANCH" != "null" ] || die "manifest: .branch is required"
[ "${#COMPOSE_ARGS[@]}" -gt 0 ] || die "manifest: .compose is required (e.g. [\"-f\",\"docker-compose.prod.yml\"])"

dc() { ( cd "$APP_DIR" && docker compose "${COMPOSE_ARGS[@]}" "${ENV_ARGS[@]}" "$@" ); }

record() {  # <result>
  printf '%s\t%s\t%s\t%s\t%s\t%ss\n' \
    "$(date -Is)" "$APP" "${TARGET_SHA:-?}" "${GITHUB_ACTOR:-manual}" "$1" "$((SECONDS - START_TS))" \
    >> "$HISTORY" 2>/dev/null || true
}

# ── global lock ─────────────────────────────────────────────────────────────
exec 9>"$LOCK" || die "cannot open lock file $LOCK"
log "[$APP] waiting for deploy lock..."
flock -w 1800 9 || die "could not acquire the global deploy lock within 30 min"
log "[$APP] lock acquired"

# ── fetch target ───────────────────────────────────────────────────────────
git -C "$APP_DIR" fetch --prune origin || die "git fetch failed"
git -C "$APP_DIR" rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1 || die "origin/$BRANCH does not exist"
CURRENT_SHA=$(git -C "$APP_DIR" rev-parse --short HEAD)
TARGET_SHA=$(git  -C "$APP_DIR" rev-parse --short "origin/$BRANCH")
log "[$APP] branch=$BRANCH  $CURRENT_SHA -> $TARGET_SHA"

# ── --check: validate and stop ─────────────────────────────────────────────
if [ "$MODE" = "--check" ]; then
  DIRTY=$(git -C "$APP_DIR" status --porcelain | grep -vE '(^| )(\.env|\.deploy\.json)' || true)
  [ -z "$DIRTY" ] || { log "[$APP] WARNING: working tree has changes that a deploy will discard:"; echo "$DIRTY"; }
  if dc config -q; then log "[$APP] compose config OK"; else die "compose config invalid"; fi
  log "[$APP] --check OK  (would deploy $CURRENT_SHA -> $TARGET_SHA)"
  exit 0
fi

if [ "$CURRENT_SHA" = "$TARGET_SHA" ]; then
  log "[$APP] already at $TARGET_SHA — rebuilding + restarting anyway (idempotent)"
fi

# ── record the running image IDs (informational; rollback rebuilds source) ──
PREV_IMAGES=$(dc ps -q 2>/dev/null | xargs -r docker inspect --format \
  '{{index .Config.Labels "com.docker.compose.service"}}={{.Image}}' 2>/dev/null | tr '\n' ' ')
log "[$APP] currently running: ${PREV_IMAGES:-<none>}"

# Rollback = restore the previous commit and rebuild it. That tree was running
# a moment ago, so it builds; the only failure mode is an upstream base image
# having been yanked, which is logged loudly for manual handling.
rollback() {  # <reason>
  log "[$APP] ROLLBACK ($1): resetting to $CURRENT_SHA and rebuilding"
  git -C "$APP_DIR" reset --hard "$CURRENT_SHA" >/dev/null 2>&1 || true
  if dc build && dc up -d --remove-orphans; then
    log "[$APP] rolled back to $CURRENT_SHA"
  else
    log "[$APP] !! ROLLBACK BUILD FAILED — production may be down, MANUAL INTERVENTION NEEDED"
  fi
  record "rollback:$1"
  die "deploy failed and was rolled back to $CURRENT_SHA ($1)"
}

# ── reset working tree to target ──────────────────────────────────────────
# `git reset --hard` restores tracked files (discards any box-side edits — this
# is why Phase 0 reconciliation matters). Untracked files (.env, .deploy.json)
# are left alone; no `git clean`, deliberately.
git -C "$APP_DIR" reset --hard "origin/$BRANCH" || { record fail-reset; die "git reset failed"; }

# ── build (safe: running containers untouched on failure) ─────────────────
HAS_BUILD=$(dc config --format json 2>/dev/null | jq '[.services[]? | select(.build)] | length' 2>/dev/null || echo 0)
if [ "${HAS_BUILD:-0}" -gt 0 ]; then
  log "[$APP] docker compose build ($HAS_BUILD service(s))"
  if ! dc build --pull; then
    git -C "$APP_DIR" reset --hard "$CURRENT_SHA" >/dev/null 2>&1 || true
    record fail-build
    die "build failed — production unchanged, tree reset to $CURRENT_SHA"
  fi
else
  log "[$APP] no build-able services — skipping build (image-only / static)"
fi

# ── pre-migrate DB snapshot ──────────────────────────────────────────────
if [ -n "$MIGRATE" ] && [ "$MIGRATE" != "null" ] && [ -x "$BACKUP_SCRIPT" ]; then
  log "[$APP] pre-deploy DB snapshot"
  "$BACKUP_SCRIPT" >/dev/null 2>&1 || log "[$APP] WARNING: pre-deploy backup returned non-zero"
fi

# ── deploy ──────────────────────────────────────────────────────────────
log "[$APP] docker compose up -d"
dc up -d --remove-orphans || rollback "compose up failed"

# ── migrate ─────────────────────────────────────────────────────────────
if [ -n "$MIGRATE" ] && [ "$MIGRATE" != "null" ]; then
  log "[$APP] migrate: docker compose $MIGRATE"
  # shellcheck disable=SC2086
  dc $MIGRATE || rollback "migration failed"
fi

# ── health gate ────────────────────────────────────────────────────────
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "null" ]; then
  log "[$APP] health: https://$DOMAIN$HEALTH_PATH  (accept: ${HEALTH_CODES[*]}; timeout ${HEALTH_TIMEOUT}s)"
  deadline=$((SECONDS + HEALTH_TIMEOUT)); healthy=0; last=000
  while [ $SECONDS -lt $deadline ]; do
    last=$(curl -s -o /dev/null -w '%{http_code}' --resolve "$DOMAIN:443:127.0.0.1" -k --max-time 10 \
             "https://$DOMAIN$HEALTH_PATH" 2>/dev/null || echo 000)
    for c in "${HEALTH_CODES[@]}"; do [ "$last" = "$c" ] && healthy=1 && break; done
    [ "$healthy" = 1 ] && break
    sleep 5
  done
  [ "$healthy" = 1 ] && log "[$APP] healthy (HTTP $last)" || rollback "health check never passed (last HTTP $last)"
fi

# ── housekeeping ───────────────────────────────────────────────────────
docker image prune -f  >/dev/null 2>&1 || true
docker builder prune -f --keep-storage "${BUILD_CACHE_KEEP_GB}GB" >/dev/null 2>&1 || true

record success
log "[$APP] ✅ DEPLOYED  $CURRENT_SHA -> $TARGET_SHA  in $((SECONDS - START_TS))s"
