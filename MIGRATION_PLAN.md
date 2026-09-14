# Production Migration Plan: Safe Implementation & Rollback Sequence

**Document Version:** 1.0  
**Date:** September 11, 2026  
**Subject:** Zero-Downtime Deployment Sequence for Hosting Second Website (`smartagentx.ai`) on Production Server `coolify-server`

---

## 1. Migration Strategy Overview

This migration plan follows a **zero-downtime, staged rollout strategy**. Because the existing production infrastructure is fronted by Traefik v3.6, the new website will be deployed, containerized, and locally validated **before** public DNS traffic is routed to the server. At no point during this procedure is a server reboot, Docker daemon restart, or reverse proxy restart required.

---

## 2. Eight-Phase Migration Sequence

```
Phase 1: Infra Prep & Ad-hoc Backup ──> Phase 2: Terraform State Verification
                                                      │
                                                      ▼
Phase 4: Container Deployment <────────── Phase 3: App Packaging & Traefik Config
       │
       ▼
Phase 5: Pre-Cutover Local Testing ────> Phase 6: DNS Cutover & Automated TLS
                                                      │
                                                      ▼
Phase 8: Rollback Plan (If Needed) <───── Phase 7: Full Production Health Sweep
```

---

### Phase 1 — Infrastructure Preparation & Baseline Snapshot

* **Action:** Capture an ad-hoc pre-migration snapshot of all production databases and record baseline server metrics.
* **Owner:** Lead DevOps Engineer.
* **Dependencies:** SSH access via `./ssh/production-infra-key`.
* **Production Impact:** Zero (read-only snapshot commands).
* **Execution Commands:**
  ```bash
  ssh -i ./ssh/production-infra-key root@46.224.15.73

  # 1. Check system load, memory, and disk headroom
  uptime && free -h && df -h /

  # 2. Run ad-hoc backup of all databases
  /opt/backups/run-backup.sh

  # 3. Record baseline health of all 11 existing applications
  for h in platform leadership autorevive aitransformer fmcg macrolab zerotopmf \
           professorstudio casestudio airevenueleakage; do
    echo -n "$h -> "; curl -s -o /dev/null -w '%{http_code}\n' \
      --resolve $h.stratagemengine.com:443:127.0.0.1 https://$h.stratagemengine.com/
  done
  curl -s -o /dev/null -w 'stratagemengine.com (apex) -> %{http_code}\n' https://stratagemengine.com/
  ```
* **Rollback:** Not applicable (read-only).

---

### Phase 2 — Terraform State Verification

* **Action:** Run `terraform plan` locally to guarantee that Terraform state is synchronized and that no pending infrastructure drift exists.
* **Owner:** DevOps Engineer.
* **Dependencies:** Hetzner API token (`terraform.tfvars`).
* **Production Impact:** Zero (read-only plan).
* **Execution Commands:**
  ```powershell
  cd "c:\Simulators\Production Infrastructure"
  terraform plan
  ```
* **Expected Result:** `No changes. Your infrastructure matches the configuration.`
* **Rollback:** If any plan diff appears, stop immediately. Do NOT run `terraform apply`.

---

### Phase 3 — Application Configuration & Compose Authoring

* **Action:** Prepare the second application's production assets and create a production `docker-compose.yml` configured strictly for Traefik routing on the `coolify` network.
* **Owner:** Full-Stack Engineer / DevOps.
* **Dependencies:** Clean git repository of the second website (`smartagentx-site-main`).
* **Production Impact:** Zero (local configuration authoring).
* **Key Configuration Rules:**
  1. Internal container port `80` exposed to Docker network only.
  2. **NO** host port mappings (`ports: ["80:80"]` forbidden).
  3. Network specified as `coolify` (external).
  4. Unique Traefik router names: `smartagentx-http`, `smartagentx-https`.
  5. ACME TLS resolver specified as `letsencrypt`.

---

### Phase 4 — Container Deployment on Production Host

* **Action:** Provision the application directory on the production server, pull the repository, and start the container in isolated mode.
* **Owner:** DevOps Engineer.
* **Dependencies:** Phase 1 and Phase 3 complete.
* **Production Impact:** Zero. New container runs alongside existing workloads without port binding conflicts.
* **Execution Commands:**
  ```bash
  ssh -i ./ssh/production-infra-key root@46.224.15.73

  # 1. Create dedicated app directory
  mkdir -p /opt/apps/smartagentx

  # 2. Clone application repository (or copy code tree)
  cd /opt/apps/smartagentx
  git clone https://github.com/<org>/smartagentx-site.git .

  # 3. Deploy container via Docker Compose
  docker compose -f docker-compose.yml up -d --build

  # 4. Verify container is running and healthy on internal network
  docker ps --filter "name=app_smartagentx_web"
  docker inspect app_smartagentx_web --format '{{json .State.Health.Status}}'
  ```
* **Rollback:** `docker compose down` removes the new container immediately.

---

### Phase 5 — Pre-Cutover Routing & Verification

* **Action:** Validate that Traefik recognizes the new router and responds correctly over HTTP/HTTPS locally on the host before making public DNS changes.
* **Owner:** DevOps Engineer.
* **Dependencies:** Phase 4 complete.
* **Production Impact:** Zero.
* **Execution Commands:**
  ```bash
  # Test Traefik routing internally using Host header resolution
  curl -I -H "Host: smartagentx.ai" http://127.0.0.1/
  # Expected: HTTP/1.1 301 Moved Permanently (Traefik HTTPS redirect)

  curl -k -I --resolve smartagentx.ai:443:127.0.0.1 https://smartagentx.ai/healthz
  # Expected: HTTP/2 200 OK
  ```
* **Rollback:** If Traefik logs errors, inspect with `docker logs --tail 100 coolify-proxy`.

---

### Phase 6 — DNS Cutover & Automated TLS Issuance

* **Action:** Update the DNS A records for the second domain to route public traffic to the Hetzner server.
* **Owner:** Domain Administrator.
* **Dependencies:** Registrar access for `smartagentx.ai`.
* **Production Impact:** Public traffic for `smartagentx.ai` begins arriving at the production server. Existing StratagemEngine apps remain completely unaffected.
* **Execution Steps:**
  1. Log into the DNS management console for `smartagentx.ai`.
  2. Set **A Record** for `@` (Apex) -> `46.224.15.73` (TTL: 300 seconds / 5 mins).
  3. Set **A Record** for `www` -> `46.224.15.73` (TTL: 300 seconds / 5 mins).
  4. Set **AAAA Record** for `@` and `www` -> `2a01:4f8:c014:6336::1` (Optional, if IPv6 desired).
  5. Wait for DNS propagation (~2 to 10 minutes).
  6. Send initial HTTPS request to trigger ACME HTTP-01 challenge:
     ```bash
     curl -v https://smartagentx.ai/
     ```
  7. Confirm Let's Encrypt certificates are written to `/data/coolify/proxy/acme.json`.

---

### Phase 7 — Production Verification & Monitoring

* **Action:** Comprehensive end-to-end verification of all routes on the new website, followed by a regression health sweep of all existing production applications.
* **Owner:** Full-Stack & DevOps Engineers.
* **Dependencies:** Phase 6 complete.
* **Production Impact:** Zero.
* **Verification Checklist:**
  - [ ] `https://smartagentx.ai/` returns HTTP 200 with valid TLS certificate.
  - [ ] `https://www.smartagentx.ai/` returns HTTP 200 with valid TLS certificate.
  - [ ] `http://smartagentx.ai/` automatically redirects (301) to HTTPS.
  - [ ] Clean URLs resolve properly (`/revenue-leakage`, `/shopify-ai-readiness`, `/about`, `/contact`).
  - [ ] Security headers active (HSTS, Content-Security-Policy, X-Frame-Options, X-Content-Type-Options).
  - [ ] Regression test: Execute Phase 1 sweep; verify all 11 existing applications still return expected 200/307/401 codes.

---

### Phase 8 — Rollback Strategy

If an unexpected issue occurs at any stage, the rollback procedure is immediate and non-destructive:

#### Scenario A: Failure During Pre-Cutover Testing (Phase 4 or 5)
1. Run `docker compose down` in `/opt/apps/smartagentx/`.
2. Traefik automatically removes the dynamic routes from memory.
3. No public traffic was ever directed to the box; existing production applications continue running without interruption.

#### Scenario B: Failure After DNS Cutover (Phase 6 or 7)
1. **Revert DNS:** In the domain registrar DNS console, change the A records for `smartagentx.ai` back to the previous hosting provider (Vercel IP / CNAME).
2. **Stop Container:**
   ```bash
   cd /opt/apps/smartagentx && docker compose down
   ```
3. **Verify Existing Production:** Re-run the health sweep for `stratagemengine.com`. Existing services remain fully intact.
