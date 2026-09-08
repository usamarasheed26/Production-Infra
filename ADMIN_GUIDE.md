# Administrator Guide — StratagemEngine Deployment

`DEPLOYMENT.md` is the **reference**: what's running, where, and why (per-app
paths, env files, and the specific bugs fixed in each repo). This file is the
**playbook**: the repeatable procedures for operating the system day-to-day.
When a procedure below needs app-specific detail (a path, a port, an env file
name), it points at the relevant `DEPLOYMENT.md` section rather than repeating
it — so if that reference ever drifts, only one place needs updating.

---

## 1. Quick reference

**Connect:**
```
cd "c:\Simulators\Production Infrastructure"
ssh -i "./ssh/production-infra-key" root@165.227.101.246
```

**What's Docker vs systemd** (see `DEPLOYMENT.md` §2 for the full table):
- Docker Compose (`/opt/apps/<name>`, `docker compose ...`): leadership-sim, autorevive-dynamics, AIEnterpriseTransformation, FMCG-Simulataor, Macrolab
- systemd (`systemctl ... <service>`): `zerotopmf`, `simulationstudio`
- Static only, no process: www.stratagemengine.com

**One-line health sweep** (run after any reboot, before/after a deploy, or whenever something feels off):
```bash
for host in www leadership autorevive aitransformer fmcg macrolab zerotopmf professorstudio; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: ${host}.stratagemengine.com" http://127.0.0.1/)
  echo "${host}.stratagemengine.com -> HTTP ${code}"
done
```
200 or a 3xx redirect (autorevive and professorstudio redirect by design) means the app responded. Anything else — connection refused, 502, 504 — means the backend process/container isn't up; check §3 and §6.2.

---

## 2. Routine operations

### 2.1 Restart an app

**Docker apps:**
```bash
cd /opt/apps/<name>
docker compose up -d               # or: docker compose -f <compose-file> --env-file <envfile> up -d
```
Use the exact compose file / env-file flags from `DEPLOYMENT.md` §3 for that app — several use a non-default compose filename (`docker-compose.prod.yml`, `infra/docker-compose.prod.yml`) or need `--env-file` explicitly.

**systemd apps:**
```bash
systemctl restart zerotopmf        # or: simulationstudio
```

### 2.2 Tail logs

```bash
docker logs -f <container-name>              # Docker apps — container names in DEPLOYMENT.md §3
journalctl -u zerotopmf -f                   # or simulationstudio
```

### 2.3 Pull latest code and redeploy

The Droplet can `git pull` any repo on the GitHub account via the deploy key (see §5):
```bash
cd /opt/apps/<RepoName>
export GIT_SSH_COMMAND="ssh -i /root/.ssh/github_deploy_key -o StrictHostKeyChecking=accept-new"
git pull
```
Then rebuild/restart per that app's method:
- Docker: `docker compose build && docker compose up -d`
- systemd + Next.js/Vite: rebuild the frontend (`npm run build`) if the frontend changed, then `systemctl restart <service>`

**Before rebuilding anything non-trivial, read §6.3 (one build at a time) — this Droplet has caused a multi-day outage from exactly this.**

### 2.4 Rotate a secret / API key

1. Edit the relevant env file (paths listed per-app in `DEPLOYMENT.md` §3 — e.g. `backend/.env`, `.env.prod`, `.env`, `.env.production`)
2. Restart:
   - Docker apps: `docker compose restart` (or `up -d` if the env file path/name changed)
   - systemd apps: `systemctl restart <service>`
3. **Exception — SimulationStudio:** `NEXT_PUBLIC_*` variables are baked into the JS bundle at *build* time, not read at runtime. Changing `NEXT_PUBLIC_SUPABASE_URL` etc. requires `npm run build` again before `systemctl restart simulationstudio` — a plain restart will keep serving the old values.

### 2.5 Renew TLS

Certbot installs its own systemd timer (`certbot.timer`) that auto-renews certs before expiry — no cron setup needed. Verify it's active:
```bash
systemctl list-timers | grep certbot
certbot certificates          # shows all certs and their expiry dates
certbot renew --dry-run       # test the renewal path without actually renewing
```
If a *new* domain is added (see §2.6) and doesn't have a cert yet, issue one manually:
```bash
certbot --nginx -d <domain>
```

### 2.6 Add a new app / subdomain

This is the generalized version of the procedure used 8 times to build the current deployment.

1. **Clone the repo:**
   ```bash
   cd /opt/apps
   export GIT_SSH_COMMAND="ssh -i /root/.ssh/github_deploy_key -o StrictHostKeyChecking=accept-new"
   git clone git@github.com:<owner>/<repo>.git
   ```
2. **Inspect the stack** — look for `Dockerfile`/`docker-compose.yml` (Docker path) vs plain `requirements.txt`/`package.json` with no Dockerfile (native/systemd path, see §2.6a). Check for a Vite/Next frontend that needs its own static build vs a backend that serves everything itself.
3. **Pick a free local port** — currently used: 8081, 8082, 8088, 8090, 3000, 3001, 3002, 8000. Anything else in the high range is fine; keep it bound to `127.0.0.1` only (never publish Docker ports to `0.0.0.0` for anything that doesn't need to be Nginx-fronted).
4. **Write the env file** — generate any internal secrets (DB passwords, JWT secrets) with `openssl rand -hex 32`, directly on the server, never through chat. Leave external API keys (Anthropic, Supabase, etc.) as clearly-labeled placeholders for manual follow-up.
5. **Build and start it** (Docker: `docker compose build && up -d`; native: venv + `pip install` or `npm ci` + build, per §2.6a).
6. **Write the Nginx server block** at `/etc/nginx/sites-available/<subdomain>.stratagemengine.com`. Three patterns already in use, pick whichever fits:
   - **Pure static** (no backend): `root /opt/apps/<name>; location / { try_files $uri $uri/ /index.html; }` — see `www` or `fmcg` frontend config as a template.
   - **Pure proxy** (single process serves everything, e.g. Flask/Next.js apps): `location / { proxy_pass http://127.0.0.1:<port>; ... }` — see `leadership`/`professorstudio` configs.
   - **Split routing** (static frontend + separate API backend): static `root` + `location / { try_files ... }` for the frontend, plus `location /api/ { proxy_pass http://127.0.0.1:<port>; }` (add trailing slash on `proxy_pass` target to strip the `/api` prefix if the backend doesn't expect it itself — check whether backend routes are already prefixed with `/api` before deciding) and `location /ws/ { proxy_pass ...; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection $connection_upgrade; }` if there's a websocket endpoint. See `macrolab`/`zerotopmf`/`fmcg`/`aitransformer` configs for real examples of each variant.
   - Always include `limit_req zone=ratelimit burst=20 nodelay;` and `limit_conn connlimit 10;` inside the `server {}` block (defined globally in `/etc/nginx/nginx.conf`, already set up).
7. **Enable and reload:**
   ```bash
   ln -sf /etc/nginx/sites-available/<domain> /etc/nginx/sites-enabled/<domain>
   nginx -t && systemctl reload nginx
   ```
8. **DNS** — add an A record (and AAAA for IPv6) at your DNS provider pointing the new subdomain at the Droplet's IPs (`DEPLOYMENT.md` §1).
9. **TLS** — once DNS resolves: `certbot --nginx -d <domain>`.
10. Run the health sweep (§1) to confirm, and add the new app to `DEPLOYMENT.md` §2/§3 for future reference.

**2.6a — Native (systemd) path**, when there's no Dockerfile:
- Python: `python3 -m venv venv && ./venv/bin/pip install -r requirements.txt`, then a systemd unit with `ExecStart=<path>/venv/bin/uvicorn app.main:app --host 0.0.0.0 --port <port>` and `EnvironmentFile=<path>/.env`.
- Node/Next.js: `npm ci` (add `--legacy-peer-deps` if you hit an ERESOLVE peer conflict — a real, fairly common issue, not a sign anything's broken) then `npm run build`, then a systemd unit with `ExecStart=<path>/node_modules/.bin/next start -p <port>`.
- Both: `Restart=always`, `RestartSec=5`, `WantedBy=multi-user.target`, then `systemctl daemon-reload && systemctl enable --now <name>`.

### 2.7 Decommission an app

```bash
# Docker:
cd /opt/apps/<name> && docker compose down
# systemd:
systemctl disable --now <service> && rm /etc/systemd/system/<service>.service && systemctl daemon-reload

rm /etc/nginx/sites-enabled/<domain>
nginx -t && systemctl reload nginx
```
Leave `/opt/apps/<name>` and `sites-available/<domain>` in place unless you're sure you want to delete the data too (Docker volumes especially — `docker compose down -v` is destructive, plain `down` is not).

---

## 3. Health checks

There is **no automated monitoring or alerting** on this Droplet — this is a known gap, not an oversight (see §5 framing below). Until that's addressed, check health manually:

1. Run the health sweep from §1.
2. `docker ps -a --format "table {{.Names}}\t{{.Status}}"` — anything showing `Exited` that should be running needs a manual restart (see §6.2 for why this happens after reboots).
3. `systemctl status zerotopmf simulationstudio nginx docker` — confirm all `active (running)`.
4. `free -h` and `df -h /` — watch for memory/disk pressure building up over time (Docker image layers and unused volumes accumulate; `docker system prune` periodically if disk gets tight, but review what it'll remove first).

Do this after every reboot/power-cycle, and as a sanity check before/after any deploy.

---

## 4. Backup & disaster recovery

**Current state: no automated backups.** This is a real gap — treat it as one, not as "fine for a demo forever."

What actually needs backing up:
- **Macrolab's SQLite data** — Docker named volume `macrolab_macrolab_data`
- **Postgres data** for autorevive-dynamics, AIEnterpriseTransformation, and FMCG-Simulataor — their respective `postgres_data`/`ar_pg_data`/`fmcg_pgdata` named volumes
- **All env files** containing secrets (`DEPLOYMENT.md` §3 lists them per app) — losing these means regenerating secrets and re-entering API keys, not losing user data, but still worth keeping a copy somewhere safe (not committed to git)

Manual backup pattern (run on-demand, not scheduled):
```bash
# Docker named volume -> tarball
docker run --rm -v <volume-name>:/data -v $(pwd):/backup alpine \
  tar czf /backup/<volume-name>-$(date +%Y%m%d).tar.gz -C /data .

# Postgres -> logical dump (more portable than a raw volume copy)
docker exec <postgres-container> pg_dump -U <user> <dbname> > <dbname>-$(date +%Y%m%d).sql
```
Copy the resulting files off the Droplet (e.g. `scp` back to this local machine) — a backup that only lives on the same disk as the thing it's backing up isn't a real backup.

---

## 5. Security & access

- **SSH access**: a single ed25519 key at `./ssh/production-infra-key` in this repo (gitignored), generated locally and never stored in Terraform state. Whoever has this file has root on the Droplet — treat it like a production credential.
- **GitHub deploy key**: `/root/.ssh/github_deploy_key` on the Droplet, added at the **GitHub account level** (Settings → SSH and GPG keys), not scoped to individual repos. This was a deliberate convenience tradeoff (see `DEPLOYMENT.md` §7) — it means anyone who compromises this Droplet gets git pull access to *every* repo on that GitHub account, current and future, not just the 8 currently deployed. Worth revisiting if the account's repo list grows to include anything more sensitive than these demo apps.
- **DigitalOcean API token**: lives only in local `terraform.tfvars` (gitignored), never passed through chat or committed anywhere. Full-access scope — treat it like root-equivalent for the whole DO account.
- **Recommended periodic reviews** (no fixed schedule enforced today — do this manually, ideally every few months):
  - Rotate the DO API token in the control panel, update `terraform.tfvars`
  - Rotate `production-infra-key` (regenerate, re-add as the Droplet's authorized key, remove the old one)
  - Rotate `github_deploy_key` and review exactly which repos it can reach (`https://github.com/settings/keys`)
  - Review internal secrets (DB passwords, JWT secrets) per app if any app becomes more than a demo

---

## 6. Incident response

### 6.1 Worked example: the Macrolab outage
A `docker compose build` for Macrolab triggered a real bug in that repo — a root `package.json` with `"install": "npm install"` as a custom script, which caused npm to recursively re-invoke itself. Combined with everything else already running, this thrashed the Droplet's memory/swap so badly that **SSH itself stopped responding at the protocol level** (TCP connections succeeded, but the SSH banner exchange timed out) for an extended period — this went unnoticed for multiple days before being caught. See `DEPLOYMENT.md` §3 (Macrolab) for the actual fix, and §6.3 below for the standing rule this incident produced.

### 6.2 After any reboot or power-cycle
Docker's `restart: unless-stopped`/`restart: always` policies bring most containers back automatically — but not all. Check `docker ps -a` and manually `docker compose up -d` anything `Exited` with an old timestamp. Per `DEPLOYMENT.md` §6: autorevive-dynamics, AIEnterpriseTransformation, and leadership-sim have proper restart policies and self-recover; **FMCG-Simulataor and Macrolab do not** and need a manual restart every time.

### 6.3 The one-build-at-a-time rule
This is a 2 vCPU / 4GB Droplet with a 4GB swapfile (`DEPLOYMENT.md` §5). Steady-state load for all 8 apps is modest, but a single heavy build (`docker compose build`, `npm ci`/`npm run build` on a large repo) can transiently spike 1–2GB+. **Never run two heavy builds concurrently.** If you need to rebuild something substantial, stop other containers first to free headroom:
```bash
cd /opt/apps/<other-app> && docker compose stop
# ... do the build ...
docker compose up -d   # bring it back after — don't forget this step
```

### 6.4 If SSH becomes unresponsive
1. Confirm the Droplet is actually up (not fully crashed) before assuming the worst:
   ```bash
   timeout 10 bash -c 'cat < /dev/null > /dev/tcp/165.227.101.246/22' && echo "PORT 22 OPEN"
   ```
   If the port is open but SSH banner exchange still times out even with a generous `ConnectTimeout` (30–45s), it's thrashing, not down.
2. Power-cycle via the DigitalOcean API (the DO web console's "Power Cycle" button does the same thing, if preferred):
   ```bash
   DO_TOKEN=$(grep '^do_token' terraform.tfvars | sed -E 's/do_token\s*=\s*"([^"]+)"/\1/')
   DROPLET_ID=$(curl -s -H "Authorization: Bearer ${DO_TOKEN}" \
     "https://api.digitalocean.com/v2/droplets?name=web-01" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*')
   curl -s -X POST -H "Authorization: Bearer ${DO_TOKEN}" -H "Content-Type: application/json" \
     -d '{"type":"power_cycle"}' "https://api.digitalocean.com/v2/droplets/${DROPLET_ID}/actions"
   ```
3. Wait ~30–60s for boot, reconnect, then immediately do §6.2 (check what didn't auto-restart) and §3 (full health sweep).

---

## 7. Resizing the Droplet

If sustained memory pressure becomes a real pattern (not just a one-off build spike — check `free -h` over time, not just during a build), resize rather than fighting it indefinitely:

1. Edit `droplet_size` in `terraform.tfvars` (e.g. `s-2vcpu-4gb` → `s-4vcpu-8gb`)
2. `terraform plan` — confirm it shows an **in-place update** (`~ update in-place` on `digitalocean_droplet.web`, specifically just the `size` field changing), **not** a replacement. If `user_data` has changed since the last apply for any reason, it'll show as a destructive replace instead — stop and reconcile that first, since a replace wipes everything documented in `DEPLOYMENT.md`.
3. `terraform apply` — this causes a brief (~30–60s) power-off/power-on cycle while DO resizes, but keeps the same IP, disk contents, and all deployed apps intact.
4. After it comes back: §6.2 (check what didn't auto-restart) and §3 (health sweep), same as any reboot.

Note disk size increases that come with some size tiers are one-way (can't shrink back later without a rebuild) — factor that into the size choice, not just CPU/RAM.
