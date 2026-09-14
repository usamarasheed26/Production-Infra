#!/usr/bin/env bash
# StratagemEngine production DB backup — installed 2026-09-10 (P0 remediation).
# Dumps every production database + the MacroLab SQLite volume to
# /opt/backups/dumps/<timestamp>/, keeps 14 days locally.
# OFF-HOST COPY IS STILL REQUIRED — see 10-SEPT-2026-PRODUCTION-DEPLOYMENT.md 6.4/12.
set -uo pipefail
TS="$(date +%Y%m%d-%H%M%S)"
OUT="/opt/backups/dumps/${TS}"
LOG="/opt/backups/backup.log"
mkdir -p "$OUT"
log(){ echo "$(date -Is) $*" | tee -a "$LOG"; }
ok=1

log "=== backup ${TS} start ==="

# --- authoritative instance: resolved dynamically, not hardcoded ---
# The container name (e.g. om3fwlitdodg2ckjxbwhorn6) is a Coolify-generated
# resource ID that changes if the database resource is ever recreated
# (Coolify upgrade, restore, migration to a new host). Resolve it by the
# label Coolify itself attaches instead of hardcoding the current name, so
# a rename doesn't silently break every nightly backup.
AUTH_DB="$(docker ps -q --filter 'label=coolify.type=database' --filter 'status=running' | head -n1)"
if [ -z "$AUTH_DB" ]; then
  log "FATAL: no running container with label coolify.type=database found — cannot back up the authoritative instance"
  ok=0
else
  AUTH_DB_NAME="$(docker inspect --format '{{.Name}}' "$AUTH_DB" | sed 's#^/##')"
  log "authoritative instance resolved to container: $AUTH_DB_NAME"

  if docker exec "$AUTH_DB" pg_dumpall -U postgres --globals-only 2>>"$LOG" | gzip > "$OUT/authoritative_globals.sql.gz"; then
    log "authoritative globals OK"
  else log "authoritative globals FAILED"; ok=0; fi

  for db in $(docker exec "$AUTH_DB" psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres'"); do
    if docker exec "$AUTH_DB" pg_dump -U postgres -Fc "$db" > "$OUT/authoritative_${db}.dump" 2>>"$LOG"; then
      log "authoritative/${db} OK ($(du -h "$OUT/authoritative_${db}.dump" | cut -f1))"
    else log "authoritative/${db} FAILED"; ok=0; fi
  done
fi

# --- per-simulation Postgres containers ---
# `aets` converged onto the authoritative instance 2026-09-11 (role `aets_app`)
# — no longer needs its own block, the authoritative-instance loop above now
# dumps it automatically as `authoritative_aets.dump`. Old container
# app_aitransformer_db decommissioned same day, volume infra_aet_pgdata kept
# as a safety net. See 10-SEPT-2026-PRODUCTION-DEPLOYMENT.md §12 #3.

# `ai_revenue_assurance` converged onto the authoritative instance 2026-09-11
# (role `ai_revenue_assurance_app`, a fresh least-privilege credential — not a
# reuse of the previously hardcoded POSTGRES_PASSWORD default) — no longer
# needs its own block, the authoritative-instance loop above now dumps it
# automatically as `authoritative_ai_revenue_assurance.dump`. Old container
# db_airevenueleakage decommissioned same day, volume
# airevenueleakage_postgres_data kept as a safety net. See
# 10-SEPT-2026-PRODUCTION-DEPLOYMENT.md §12 #3.

# `contacts` (contact-form API) converged onto the authoritative instance
# 2026-09-11 (role `contacts_app`, same role name reused, fresh password) —
# no longer needs its own block, the authoritative-instance loop above now
# dumps it automatically as `authoritative_contacts.dump`. Old Coolify-managed
# container contacts-db-coolify (rg2p3c5ipuuti98wog46z3y8) removed same day;
# volume postgres-data-rg2p3c5ipuuti98wog46z3y8 kept as a safety net; the
# Coolify dashboard resource record itself still needs a deliberate manual
# deletion (with explicit volume-retention confirmation) as a follow-up — see
# 10-SEPT-2026-PRODUCTION-DEPLOYMENT.md §12 #3.

# --- legacy fmcg Postgres container: REMOVED 2026-09-14 ---
# The container (fmcg-simulataor-postgres-1) was decommissioned 2026-09-11
# and confirmed fully gone (no longer exists in any state, `docker ps -a`
# returns nothing for it) as of the 2026-09-14 infrastructure audit — this
# block had been failing (harmlessly, but noisily) on every run since. The
# real fmcg data has been on the authoritative instance since 2026-09-11
# and is already covered by the loop above (`authoritative_fmcg.dump`).

# --- MacroLab SQLite volume: legacy safety-net copy, not the source of truth ---
# MacroLab migrated OFF this SQLite volume onto a `macrolab` database on the
# authoritative instance on 2026-09-12 (already covered by the loop above as
# `authoritative_macrolab.dump`) — this tar is now a best-effort archival
# copy of the old volume, not live data. Its failure must NOT fail the whole
# nightly backup (unlike a real DB dump failure above): if/when this volume
# is eventually deleted as part of the SQLite-era cleanup, this step should
# start failing and that is expected, not an incident.
if docker run --rm -v macrolab_macrolab_sqlite_data:/d:ro -v "$OUT":/b alpine \
     tar czf /b/macrolab_sqlite_volume.tgz -C /d . 2>>"$LOG"; then
  log "macrolab sqlite volume (legacy) OK"
else
  log "macrolab sqlite volume (legacy) FAILED — non-critical, real data is in the authoritative 'macrolab' DB above"
fi

# --- checksums + retention ---
( cd "$OUT" && sha256sum * > SHA256SUMS 2>/dev/null || true )
find /opt/backups/dumps -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>>"$LOG" || true

TOTAL="$(du -sh "$OUT" | cut -f1)"
if [ "$ok" = 1 ]; then log "=== backup ${TS} OK (${TOTAL}) ==="; else log "=== backup ${TS} COMPLETED WITH ERRORS (${TOTAL}) ==="; fi
[ "$ok" = 1 ]
