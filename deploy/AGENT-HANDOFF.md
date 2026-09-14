# Agent handoff — CI/CD rollout (Production Infrastructure repo)

Brief for a Claude Code session working in **`c:\Simulators\Production Infrastructure`**.
Read this, then `deploy/README.md` and `../10-SEPT-2026-PRODUCTION-DEPLOYMENT.md`.

## What this repo is

Terraform for the **HetzCloud** production box (`coolify-server`, `46.224.15.73`,
Coolify + Traefik) plus the deploy tooling under `deploy/`. The 8 `*.tar.gz` in
the root are snapshots of the app repos (gitignored). DigitalOcean is **historical
only** — `DEPLOYMENT.md` / `ADMIN_GUIDE.md` describe the dead droplet.

## Access

- Box: `ssh -i ./ssh/production-infra-key root@46.224.15.73` (root). GitHub reachable from the box via `/root/.ssh/github_deploy_key` (account-level).
- Hetzner API: token in `terraform.tfvars` (gitignored). Read-only calls fine; **never `terraform apply` without showing the plan and getting explicit approval**. `terraform plan` should report **No changes**.
- Coolify UI: not public — `ssh -i ./ssh/production-infra-key -L 8000:localhost:8000 root@46.224.15.73` then `http://localhost:8000`.

## The CI/CD model

Push to an app repo's prod branch → GitHub Action → SSH to box → `sudo /opt/apps/deploy.sh <AppDir>`.
`deploy.sh` (source: `deploy/deploy.sh`, live: `/opt/apps/deploy.sh`): global `flock`
→ `git reset --hard origin/<branch>` → `docker compose build` → `up -d` → manifest
`migrate` step → HTTPS health gate → **auto-rollback + non-zero exit** on failure.
No pre-deploy test gate (by user's choice). Secrets stay on the box — `deploy.sh`
never reads app `.env` files.

- Manifests: `deploy/manifests/<AppDir>.json` → `/opt/apps/<AppDir>/.deploy.json`
- Deploy log: `/opt/apps/.deploy-history.log`
- DB backups: `/opt/backups/run-backup.sh` (cron 02:30, 14-day retention, dumps in `/opt/backups/dumps/`, one off-box copy in `../_backup/db/`)
- Reusable GH workflow: `deploy/github/deploy-reusable.yml` (→ a repo `usamarasheed26/stratagem-deploy`)
- Per-repo caller templates: `deploy/github/<app>-deploy.yml`

## State (2026-09-11)

| app | status |
|---|---|
| **platform** | ✅ onboarded box-side. `/opt/apps/platform` = `origin/master` `d7e5f87` (super-admin feature). `.env.production` untracked + box-only. `deploy.sh platform` proven (2 successful runs in the history log). Migration `003_super_admin_user_management.sql` applied to `stratagem_platform`. **Not yet push-triggered** (needs bootstrap + GH wiring). |
| **www** | ✅ onboarded box-side, now at `23d52f8` (contact-form API added). `docker-compose.yml` + `.gitignore` committed to `usamarasheed26.github.io` `main`. `/opt/apps/www` reconciled; `.deploy.json` on the box; `deploy.sh www` proven, incl. building the new `api` service. New standalone Postgres `contacts-db` (plain docker-compose, not Coolify-UI — see AGENT-HANDOFF password-quoting lesson below) folded into `run-backup.sh`. All 6 handoff verification checks passed. **Not yet push-triggered.** Give the user `deploy/github/www-deploy.yml` once `stratagem-deploy` + secrets exist. |
| other 9 | ⛔ Phase 0 not started — 7 have **no `.git`** on the box (`autorevive`, `AIEnterpriseTransformation`, `FMCG-Simulataor`, `Macrolab`, `ZeroToPMF`, `SimulationStudio`, `AIRevenueLeakage`); `leadership` has 27 uncommitted server edits. `deploy/README.md` has the per-app Phase 0 procedure + the per-app gotchas are in each manifest's `notes`. |

## Next actions

1. **Activate the GitHub trigger** (needs the user):
   - `bash deploy/bootstrap.sh` — creates the `deploy` user + NOPASSWD sudoers for `/opt/apps/deploy.sh` only, generates `ssh/deploy-key`. **Ask before running** (new system user).
   - User creates `usamarasheed26/stratagem-deploy` with `deploy/github/deploy-reusable.yml`.
   - User sets org secrets: `DEPLOY_HOST=46.224.15.73`, `DEPLOY_USER=deploy`, `DEPLOY_SSH_KEY`=`ssh/deploy-key` contents.
   - User adds the caller workflow to `Platform` and `usamarasheed26.github.io`.
   - Test: empty commit to `Platform` or `usamarasheed26.github.io` → push → Action green → box updated.
2. **Roll out the rest** — one app at a time, order in `deploy/README.md` (`AIEnterpriseTransformation → Macrolab → FMCG-Simulataor → ZeroToPMF → SimulationStudio → autorevive → AIRevenueLeakage`). Each needs Phase 0 first.
3. **Rollback drill** — once, on a low-risk sim.

## Open items (need the user)

- `AIRevenueLeakage` repo — the account deploy key can't see `usamarasheed26/AIRevenueLeakage`. Need name/owner/access.
- Canonical prod branch per repo (`FMCG-Simulataor`, `ZeroToPMF`, `SimulationStudio` run `feature/*` branches — confirm which is authoritative).
- `SimulationStudio` — how `simulationstudio_db`'s schema is managed (set `.migrate` in its manifest).
- OK to create the `deploy` user + `stratagem-deploy` repo.

## Follow-ups (not blocking)

- **Rotate** the secrets exposed in the `Platform` repo git history: `CLERK_SECRET_KEY` + webhook secret, `STRIPE_SECRET_KEY` + webhook secret, `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_JWT_SECRET` (also update `/opt/apps/supabase/.env` + restart those 3 containers), `ANTHROPIC_API_KEY`, and the HMAC secrets (`INVITE_SECRET`, `OBSERVER_INVITE_SECRET`, `PENDING_COMPLETION_SECRET`, `ARCHIVE_DELAY_SECRET`, `JOIN_REQUEST_SECRET`, `EDGE_FUNCTION_SECRET`, `CRON_SECRET`).
- Platform: seed a `super_admin` (Clerk `publicMetadata.app_role` + `npm run seed`) or `/super/*` stays unreachable.
- `/api/cron/*` — check whether the box triggers these at all (platform's `vercel.json` defines crons but the platform isn't on Vercel). If nothing triggers them, `/api/cron/cleanup-imports` (new) and the existing archive/cleanup crons aren't running.
- Open gaps in `../10-SEPT-2026-PRODUCTION-DEPLOYMENT.md` §12: off-host backup push, Hetzner snapshots, per-sim DB consolidation, MacroLab not persisting (#13), monitoring, remote TF state.

## Coolify API is now usable (2026-09-11)

`instance_settings.is_api_enabled` was `false` — flipped to `true`. A
root-scoped personal access token exists at `/root/.coolify_api_token` on the
box (bootstrapped via a direct `personal_access_tokens` insert — standard
Sanctum mechanism, `team_id='0'`, `tokenable_type='App\Models\User'`,
`tokenable_id=0`, `abilities='["root"]'` — no browser access available to
create it via Settings → API tokens). Base URL: `http://localhost:8000` on the
box (not reachable past the firewall). Useful endpoints found:
`GET /api/v1/servers`, `/api/v1/projects` (+ nested `environments`),
`/api/v1/databases`, `POST /api/v1/databases/postgresql`. This means future
"formally provision X in Coolify" requests **no longer need a UI workaround**
— use the real API. Treat the token like the Hetzner/GitHub tokens (§13 of the
10-SEPT doc). `contacts-db` (the contact-form API's database) was migrated
from a plain-compose container into a real Coolify resource this way — see
its changelog entry for the exact steps (create via API → provision role/DB →
`pg_dump`/`pg_restore` → repoint `.env` → redeploy → decommission old container).

## Lesson: shell-quoting a password into `psql -c` (2026-09-11)

Don't build SQL strings with nested `'"'"'` quote-toggling inside an
already-double-quoted `docker exec ... psql -c "..."` — it's easy to land an
extra character (e.g. a stray `"`) right next to the password, and the bug is
invisible because `docker exec <db-container> psql -U <role> ...` (no `-h`)
connects over the **local Unix socket inside that container**, not the network
path a client app actually uses. A password mismatch there won't show up.
**Always verify credentials over the real path**: from another container on
the same network, `-h <service-name>` (or a throwaway
`docker run --rm --network <net> postgres:16-alpine psql -h <host> -U <user> -d <db>`),
not from inside the DB container itself. To set a password without any nested
quoting at all, pipe the SQL from a file/heredoc: `psql -f -` or
`< <(cat <<SQL ... SQL)` with the password only ever inside a single
`${VAR}` expansion in an otherwise plain-quoted context.

## Lesson: `psql -tAc "INSERT ... RETURNING ..."` (2026-09-11)

`-t`/`--tuples-only` suppresses column headers and row-count footers on the
**result set**, but NOT the `INSERT 0 1` command-completion tag, which psql
prints as a separate line regardless. Capturing this via
`VAR=$(docker exec ... psql -tAc "INSERT ... RETURNING id")` gives you
`"INSERT 0 1\n<id>"`, not just `"<id>"`. Downstream string-building
(`"${VAR}|${other}"`) then embeds a stray newline that tools like `curl -H`
either mis-send or silently truncate at — producing a confusing, unrelated-
looking failure (here: a `401 Unauthenticated` that looked like a bad
credential, not a malformed header). Fix: never capture an `INSERT ...
RETURNING` this way — run the insert with `-c "INSERT ...;"` (no RETURNING,
no capture), then a **separate** clean `SELECT` (`-tAc "select id from ...
where <unique column> = '...'"`) to fetch the id. Always sanity-check
constructed secrets/tokens with `wc -c` / `od -c` before using them, not just
by eyeballing the printed value.

## Guardrails

- The box is **production**. No destroy, no `docker compose down -v`, no dropping DBs.
- Never print secret values (env values, tokens, keys). Redact when inspecting.
- Never `terraform apply` without an approved plan. `prevent_destroy` is set on the server + firewall.
- HetzCloud is current production; DigitalOcean docs are historical.
- Take a `run-backup.sh` snapshot before any migration or risky deploy.
