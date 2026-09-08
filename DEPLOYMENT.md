# StratagemEngine Production Deployment — Reference Guide

This document is the ground-truth reference for what's actually running on the
production Droplet. The Terraform files in this directory (`main.tf`,
`variables.tf`, etc.) provision the **base infrastructure only** (the Droplet,
firewall, SSH key). Everything else — Docker, systemd services, app deployments,
and the real Nginx routing — was set up by hand directly on the server and is
**not** reflected in Terraform state. This file is the record of that manual
work.

**Do not edit `terraform.tfvars`'s `apps` variable and re-run `terraform apply`.**
Changing it regenerates the Droplet's `user_data`, which DigitalOcean treats as
a forced replacement (destroy + recreate). That would wipe every app documented
below — Docker containers/volumes, systemd services, and all hand-written Nginx
configs — none of which live in Terraform state.

---

## 1. Infrastructure

| Item | Value |
|---|---|
| Droplet name | `web-01` |
| Region | `nyc3` |
| Size | `s-2vcpu-4gb` (2 vCPU / 4GB RAM) |
| IPv4 | `165.227.101.246` |
| IPv6 | `2604:a880:800:14:0:3:33d1:5000` |
| OS | Ubuntu 24.04 |
| Firewall | DO Cloud Firewall: inbound 22/80/443 only; UFW mirrors this on the host |
| SSH key | `./ssh/production-infra-key` (private, local to this repo, gitignored) |
| Swap | 4GB swapfile at `/swapfile`, `vm.swappiness=10` — added after a real OOM incident (see §6) |
| Docker | Docker Engine 29.x + Compose v2 plugin, installed via apt |
| Node.js | v20.20.2 (NodeSource), installed system-wide for building static frontends |
| Python | python3-venv, used for ZeroToPMF's native backend |

**Connect:**
```
ssh -i "./ssh/production-infra-key" root@165.227.101.246
```

---

## 2. Apps — routing table

All apps sit behind host Nginx on ports 80/443. Nginx configs live at
`/etc/nginx/sites-available/<domain>` on the Droplet (symlinked into
`sites-enabled/`).

| Domain | Repo | Backend port(s) | Run method | Frontend |
|---|---|---|---|---|
| www.stratagemengine.com | `usamarasheed26.github.io` | — | static files | served directly by Nginx from `/opt/apps/www` |
| leadership.stratagemengine.com | `leadership-sim` | 8082 | Docker (`docker compose`) | served by Flask itself (same container) |
| autorevive.stratagemengine.com | `autorevive-dynamics` | 8081 | Docker (`docker compose -f docker-compose.prod.yml`) | served by the app's own internal Nginx container |
| aitransformer.stratagemengine.com | `AIEnterpriseTransformation` | 8000 (api), 3000 (frontend) | Docker (`docker compose -f infra/docker-compose.prod.yml`) | Next.js, proxied separately from `/api/` |
| fmcg.stratagemengine.com | `FMCG-Simulataor` | 8088 | Docker (`docker compose`) | static Vite build, Nginx-served, `/api/` and `/ws/` proxied |
| macrolab.stratagemengine.com | `Macrolab` | 3001 | Docker (`docker compose`) | static Vite build, Nginx-served, `/api/` proxied |
| zerotopmf.stratagemengine.com | `ZeroToPMF` | 8090 | systemd (`zerotopmf.service`), native Python venv | static Vite build, Nginx-served, `/api/` and `/ws/` proxied |
| professorstudio.stratagemengine.com | `SimulationStudio` | 3002 | systemd (`simulationstudio.service`), native `next start` | Next.js serves both pages and its own `/api/*` routes |

All app source lives on the Droplet at `/opt/apps/<RepoName>`, cloned via a
GitHub deploy key (`/root/.ssh/github_deploy_key`, added at the **account**
level in GitHub Settings → SSH and GPG keys — this key can pull any repo on
the account, current or future).

---

## 3. Per-app operational notes

### leadership-sim (Docker)
- Path: `/opt/apps/leadership`
- Env file: `backend/.env` — needs real `ANTHROPIC_API_KEY`, `SUPABASE_URL`, `SUPABASE_KEY`
- Faculty dashboard (`/dashboard.html`) password is in that same `.env` (`FACULTY_PASSWORD`)
- Restart: `cd /opt/apps/leadership && docker compose restart`

### autorevive-dynamics (Docker, 7 containers)
- Path: `/opt/apps/autorevive`
- Compose file: `docker-compose.prod.yml` (not the default `docker-compose.yml`)
- Env file: `.env.prod` — DB/Redis/JWT secrets were auto-generated; needs real `ANTHROPIC_API_KEY`
- Services: `db`, `redis`, `api`, `celery-worker`, `celery-beat`, `frontend`, `nginx` (their own internal reverse proxy on 8081)
- Restart: `cd /opt/apps/autorevive && docker compose -f docker-compose.prod.yml --env-file .env.prod up -d`

### AIEnterpriseTransformation (Docker, 4 containers)
- Path: `/opt/apps/AIEnterpriseTransformation`
- Compose file: `infra/docker-compose.prod.yml`
- Env file: `.env` (repo root) — DB/JWT secrets auto-generated; needs real `ANTHROPIC_API_KEY`
- **Bugs fixed directly in this repo's source** (server-only, not pushed to GitHub):
  - `app/instructor/sessions/[id]/page.tsx` — type cast fix for a real TS error
  - `next.config.mjs` — added `typescript.ignoreBuildErrors: true` (a `typedRoutes` false positive) and `output: "standalone"` (required by their own Dockerfile but never set)
  - `app/onboarding/readiness/page.tsx` and `app/simulation/new/page.tsx` — wrapped in `<Suspense>` (Next.js hard-requires this for `useSearchParams()`)
  - Created empty `frontend/public/` directory (Dockerfile expected it; didn't exist)
- Restart: `cd /opt/apps/AIEnterpriseTransformation && docker compose -f infra/docker-compose.prod.yml --env-file .env up -d`

### FMCG-Simulataor (Docker + static frontend)
- Path: `/opt/apps/FMCG-Simulataor`
- Backend uses the repo's own dev-mode defaults (hardcoded Postgres user/pass, `ANTHROPIC_API_KEY` optional — empty means it runs in deterministic/no-AI mode, which is fine)
- Frontend built with `VITE_API_URL=https://fmcg.stratagemengine.com/api`, output at `frontend/dist`
- Restart backend: `cd /opt/apps/FMCG-Simulataor && docker compose up -d`
- Rebuild frontend: `cd /opt/apps/FMCG-Simulataor/frontend && npm run build`

### Macrolab (Docker API, SQLite + static frontend)
- Path: `/opt/apps/Macrolab`
- **This repo had the most bugs of any app deployed** — all fixed directly in its source on the server:
  1. Root `package.json` had a self-referential `"install": "npm install"` script causing runaway recursive installs — **this is almost certainly what caused the original multi-day outage** (see §6). Removed.
  2. `Dockerfile` never actually ran `tsc` to build the API before copying `dist/` — added the build step.
  3. `api/tsconfig.json` combined `resolveJsonModule` with implicit classic module resolution (invalid) — added explicit `moduleResolution`.
  4. `Dockerfile` copied a nonexistent `/app/api/node_modules` (npm workspaces hoist everything to root `/app/node_modules`) — removed that copy line.
  5. `Dockerfile`'s `CMD` pointed at `dist/src/server.js`; actual output (per `rootDir: "./src"`) is `dist/server.js` — fixed.
  6. Both `engine` and `api` were `"type": "module"` (ESM) but the compiled output used bare `require()`-style resolution incompatible with strict ESM — switched both workspaces to CommonJS (`module: "CommonJS"` in both tsconfigs, removed `"type": "module"` from both `package.json`s). The `engine` package's `exports` field now lists both `"import"` and `"require"` conditions pointing at the same CJS output, since the **web frontend** (bundled via Vite/Rollup) still needs the `import` condition — the API needs `require`.
  7. Prisma's bundled query/migration engines need `libssl.so.1.1`, not present on modern Alpine (OpenSSL 3.x only) — added `binaryTargets = ["native", "linux-musl-openssl-3.0.x"]` to `prisma/schema.prisma` and `RUN apk add --no-cache openssl` to the Dockerfile's final stage.
  8. `prisma/schema.prisma` declared `provider = "sqlite"`, but `docker-compose.yml` was wired up with a **Postgres** container and a `postgresql://` `DATABASE_URL` — a real mismatch. The app was always meant to use SQLite (confirmed via `.env.example`). Switched `DATABASE_URL` to `file:/app/data/macrolab.db` (persisted via a named Docker volume) and stopped/detached the now-unused Postgres container.
  9. `prisma` CLI was a devDependency, but the container needs it at runtime for `prisma migrate deploy` on startup — moved to regular `dependencies`.
  10. Web frontend: `tsc && vite build` fails on ~15 real type errors in the app code — built via `vite build` directly (esbuild doesn't type-check, so this still produces a working bundle).
  11. Rollup's CommonJS interop plugin couldn't statically detect `engine`'s `Object.defineProperty`-based named exports — fixed via `build.commonjsOptions.include` in `web/vite.config.ts`.
- Runtime command override lives in `docker-compose.override.yml` (not the tracked `docker-compose.yml`)
- Restart: `cd /opt/apps/Macrolab && docker compose up -d`
- Rebuild frontend: `cd /opt/apps/Macrolab/web && /opt/apps/Macrolab/node_modules/.bin/vite build`

### ZeroToPMF (systemd + static frontend)
- Path: `/opt/apps/ZeroToPMF`
- No Dockerfile in this repo for the backend — runs natively via a Python venv at `backend/venv`
- No Alembic migrations needed — tables are created automatically via SQLAlchemy on startup
- Postgres/Redis still run in Docker (`docker compose up -d` in the repo root) — backend connects to them via `localhost:5434` / `localhost:6382` (their compose file's custom host ports)
- Env file: `backend/.env` — needs real `ANTHROPIC_API_KEY`
- Service: `systemctl status/restart/stop zerotopmf`
- Logs: `journalctl -u zerotopmf -f`
- Rebuild frontend: `cd /opt/apps/ZeroToPMF/frontend && npm run build`

### SimulationStudio (systemd, no Docker)
- Path: `/opt/apps/SimulationStudio`
- Pure Next.js app; its own `/api/*` routes are the backend. Uses external Supabase (no local DB)
- `npm ci` needed `--legacy-peer-deps` once (repo has a real `eslint@^8` vs `eslint-config-next` `eslint@>=9` peer conflict) — not needed again unless `node_modules` is wiped
- Env file: `.env.production` — needs real Supabase URL/anon key/service role key and `ANTHROPIC_API_KEY`. **Note:** `NEXT_PUBLIC_*` vars are baked in at build time — after changing them, you must `npm run build` again before restarting the service
- Service: `systemctl status/restart/stop simulationstudio`
- Logs: `journalctl -u simulationstudio -f`

---

## 4. Still needed from you

1. **DNS** — point A records (and AAAA for IPv6) for all 8 domains at `165.227.101.246` / `2604:a880:800:14:0:3:33d1:5000`.
2. **API keys** — SSH in and replace the `REPLACE_WITH_YOUR_...` placeholders in each app's env file (listed per-app above), then restart that app.
3. **TLS** — once DNS resolves, run `certbot --nginx -d <domain>` for each of the 8 domains (or one combined run listing all `-d` flags, but separate is safer since they're unrelated apps).

---

## 5. Resource constraints — read before running any build

The Droplet is 2 vCPU / 4GB RAM with a 4GB swapfile. Steady-state idle load for
all 8 apps is roughly ~1.2–1.5GB, leaving headroom — but a single heavy build
(Next.js, npm installs) can transiently spike 1–2GB+. **Never run more than one
heavy build (`docker compose build`, `npm run build`, `npm ci` on a large repo)
at a time.** If you need to rebuild something substantial, consider stopping
other containers first:
```
cd /opt/apps/<other-app> && docker compose stop
# ... do the build ...
docker compose up -d   # bring it back after
```

## 6. Incident history

A Macrolab build (root cause: the recursive `npm install` script, see §3)
froze the entire Droplet — SSH became unresponsive at the protocol level for
an extended period (multiple days of real time elapsed before it was caught
and fixed). Recovery required a hard power cycle via the DigitalOcean API.
**All Docker containers without an explicit `restart` policy will not come
back automatically after a reboot** — check `docker ps -a` after any
power-cycle/reboot and manually `docker compose up -d` anything that shows
`Exited` with an old timestamp. (`autorevive-dynamics`, `AIEnterpriseTransformation`,
and `leadership-sim` all have proper restart policies and self-recovered;
`FMCG-Simulataor` and `Macrolab` do not and needed a manual restart.)

## 7. Deploy key

A single ed25519 key was generated on the Droplet (`/root/.ssh/github_deploy_key`)
and added to the GitHub **account** (not per-repo) under Settings → SSH and
GPG keys. This means the Droplet can `git pull` any repo on that account,
current or future — a broader blast radius than repo-scoped deploy keys, a
tradeoff made deliberately for convenience. To pull updates for any app:
```
cd /opt/apps/<RepoName>
export GIT_SSH_COMMAND="ssh -i /root/.ssh/github_deploy_key -o StrictHostKeyChecking=accept-new"
git pull
# then rebuild/restart per the instructions in §3 for that app
```
