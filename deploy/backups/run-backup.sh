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

# --- authoritative instance: globals + every non-template DB ---
if docker exec om3fwlitdodg2ckjxbwhorn6 pg_dumpall -U postgres --globals-only 2>>"$LOG" | gzip > "$OUT/authoritative_globals.sql.gz"; then
  log "authoritative globals OK"
else log "authoritative globals FAILED"; ok=0; fi

for db in $(docker exec om3fwlitdodg2ckjxbwhorn6 psql -U postgres -tAc "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres'"); do
  if docker exec om3fwlitdodg2ckjxbwhorn6 pg_dump -U postgres -Fc "$db" > "$OUT/authoritative_${db}.dump" 2>>"$LOG"; then
    log "authoritative/${db} OK ($(du -h "$OUT/authoritative_${db}.dump" | cut -f1))"
  else log "authoritative/${db} FAILED"; ok=0; fi
done

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

# --- legacy fmcg Postgres: container removed 2026-09-11 (confirmed unused: 0
#     connections in the preceding 72h, app already on the authoritative `fmcg`
#     DB). Data volume fmcg-simulataor_fmcg_pgdata kept as a safety net. This
#     block is expected to fail (non-critical) until deleted outright after a
#     short confidence period — see 10-SEPT-2026-PRODUCTION-DEPLOYMENT.md §12 #4. ---
if docker exec fmcg-simulataor-postgres-1 pg_dump -U postgres -Fc fmcg > "$OUT/fmcg_legacy_local.dump" 2>>"$LOG"; then
  log "fmcg legacy-local OK"; else log "fmcg legacy-local FAILED (non-critical, container decommissioned 2026-09-11)"; fi

# --- MacroLab SQLite volume (whole volume, whatever state it is in) ---
if docker run --rm -v macrolab_macrolab_sqlite_data:/d:ro -v "$OUT":/b alpine \
     tar czf /b/macrolab_sqlite_volume.tgz -C /d . 2>>"$LOG"; then
  log "macrolab sqlite volume OK"; else log "macrolab sqlite volume FAILED"; ok=0; fi

# --- checksums + retention ---
( cd "$OUT" && sha256sum * > SHA256SUMS 2>/dev/null || true )
find /opt/backups/dumps -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} + 2>>"$LOG" || true

TOTAL="$(du -sh "$OUT" | cut -f1)"
if [ "$ok" = 1 ]; then log "=== backup ${TS} OK (${TOTAL}) ==="; else log "=== backup ${TS} COMPLETED WITH ERRORS (${TOTAL}) ==="; fi
[ "$ok" = 1 ]
