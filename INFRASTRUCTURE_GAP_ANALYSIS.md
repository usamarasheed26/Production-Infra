# Infrastructure Gap Analysis: Compatibility, Conflicts & Architectural Boundaries

**Document Version:** 1.0  
**Date:** September 11, 2026  
**Subject:** Comparative Feasibility and Conflict Assessment for Hosting a Second Website on `coolify-server`

---

## 1. Comprehensive Compatibility Matrix

This matrix evaluates whether the existing production infrastructure can support the second application across 15 core architectural dimensions.

| Area | Existing Production Infrastructure | Second Application Requirements (`SmartAgentX.ai`) | Compatible? | Required Infrastructure / Configuration Change | Risk Level |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | 8 vCPU shared AMD (`cx43`), current load `~1.1` (14% utilized) | 0.1 vCPU idle / 0.5 vCPU peak | **YES** | None. Current CPU capacity has 86% headroom. | **Very Low** |
| **RAM** | 16 GB Physical + 4 GB Swap, current usage `3.9 GB` (24% utilized) | 64 MB – 128 MB RAM | **YES** | None. Current host has `12.1 GB` of free unallocated physical RAM. | **Very Low** |
| **Disk** | 160 GB NVMe SSD, `33 GB` used (117 GB free) | ~150 MB (Docker image + access logs) | **YES** | None. Ample disk storage available. | **Very Low** |
| **Docker Engine** | Docker Engine `29.7.2` & Compose v2 (`5.5.0`) | Docker Engine 24+ & Compose v2 | **YES** | None. Host engine natively supports multi-stage builds and Compose v2. | **Very Low** |
| **Network** | External Docker bridge network `coolify` (172.x subnet) | Needs bridge access to reverse proxy | **YES** | Must attach container to `networks: [coolify]`. Must not create colliding bridge subnets. | **Low** |
| **Ports** | Host ports 80 & 443 owned by Traefik (`coolify-proxy`). Port 8000 closed. | Container internal port 80 | **CONDITIONAL** | **CRITICAL:** The second app must **NOT** bind `80:80` or `443:443` on the host. Must route traffic via Traefik. | **High (if misconfigured)** |
| **Reverse Proxy** | Traefik v3.6 (`coolify-proxy`) dynamically routing via Docker labels | Needs routing for `smartagentx.ai` & `www.smartagentx.ai` | **YES** | Add Traefik labels to the second app's `docker-compose.yml`. Traefik automatically discovers new routes. | **Low** |
| **Database** | PostgreSQL 18 (`om3fwlitdodg...`) + `contacts-db-coolify` (PG 16) | None for static site; optional isolated logical DB for contact API | **YES** | If contact API is needed, create isolated logical DB or dedicated container. No change for static site. | **Low** |
| **Redis** | Upstash (platform) + per-sim Redis 7 containers | None required for static site | **YES** | None. No Redis footprint needed. | **Very Low** |
| **Storage / Volumes** | Named Docker volumes & host bind mounts in `/opt/apps/` | Read-only static mount or baked container image | **YES** | Deploy to standard `/opt/apps/smartagentx/` path. | **Very Low** |
| **SSL / TLS** | Traefik v3.6 + Let's Encrypt automated HTTP-01 challenge resolver | Valid HTTPS for `smartagentx.ai` & `www` | **YES** | Configure `traefik.http.routers.<name>.tls.certresolver=letsencrypt`. Traefik auto-provisions certificate. | **Low** |
| **DNS** | External DNS (Namecheap) pointing A records to `46.224.15.73` | Apex `@` and `www` A records -> `46.224.15.73` | **YES** | Add A records at the registrar of `smartagentx.ai`. DNS is external to Terraform. | **Low** |
| **Firewall** | Hetzner Cloud Firewall (`coolify-server-fw`) allows 22, 80, 443 | Uses standard web ports 80 and 443 | **YES** | None. Ports 80 and 443 are already open to the world. | **Very Low** |
| **Backups** | Daily cron `/opt/backups/run-backup.sh` (PG dumps + SQLite tar) | Back up application directory & optional DB | **YES** | If an API database is introduced, add its container/DB name to `/opt/backups/run-backup.sh`. | **Low** |
| **Monitoring** | `coolify-sentinel` host metrics; domain curl sweeps | HTTP 200 endpoint checks | **YES** | Add `smartagentx.ai` to the operator health check script (`/opt/apps/` sweep). | **Low** |

---

## 2. Deep-Dive Conflict Analysis

When collocating multiple independent domains on a single shared production host, potential conflicts must be proactively addressed.

### 2.1 Port Conflicts (CRITICAL)

* **The Conflict:** In a standalone VPS deployment, an Nginx container typically exposes ports directly to the host:
  ```yaml
  # STANDALONE CONFIGURATION - DO NOT USE ON PRODUCTION
  ports:
    - "80:80"
    - "443:443"
  ```
  If applied on `coolify-server`, Docker will immediately fail with:
  `Error response from daemon: driver failed programming external connectivity on endpoint ...: Bind for 0.0.0.0:80 failed: port is already allocated`
  If a developer attempts to stop whatever is on port 80/443 to "fix" this, they will terminate `coolify-proxy` (Traefik), causing an **immediate total outage of all 11 existing production applications**.
* **The Solution:** Remove all host `ports:` bindings from the second application's `docker-compose.yml`. The container must only expose its internal port 80 to the `coolify` Docker network. Traefik will route incoming traffic on host ports 80/443 directly to the container's private Docker IP based on the HTTP `Host` header.

### 2.2 Reverse Proxy & Traefik Routing Conflicts

* **The Conflict:** Traefik requires unique router and service names in its label configuration. If two containers use identical router identifiers (e.g. `traefik.http.routers.web.rule`), Traefik will throw configuration errors, causing one or both routes to fail.
* **The Solution:** Use strictly namespaced router identifiers for the second application:
  - HTTP router: `traefik.http.routers.smartagentx-http`
  - HTTPS router: `traefik.http.routers.smartagentx-https`
  - Middleware: `traefik.http.middlewares.smartagentx-redirect`
  - Service: `traefik.http.services.smartagentx-service`

### 2.3 SSL / TLS Certificate Conflicts

* **The Conflict:** The existing website (`stratagemengine.com`) uses a Let's Encrypt certificate managed inside `/data/coolify/proxy/acme.json`. If an engineer tries to run a host-level Certbot instance (`certbot certonly --standalone -d smartagentx.ai`), Certbot will attempt to bind port 80 on the host, which will fail because Traefik owns port 80.
* **The Solution:** Let Traefik manage TLS issuance via SNI (Server Name Indication). When Traefik receives an HTTPS request for `smartagentx.ai`, it matches the router labels, intercepts the Let's Encrypt HTTP-01 challenge path (`/.well-known/acme-challenge/*`), answers the challenge automatically, and adds the new certificate for `smartagentx.ai` alongside `stratagemengine.com` inside `acme.json` with zero interruption to existing certificates.

### 2.4 Docker Namespace & Resource Conflicts

* **Container Naming:** Must not clash with existing containers (`app_www`, `app_platform`, `app_api`, etc.). Recommended container name: `app_smartagentx_web`.
* **Volume Names:** If named volumes are used, prefix them: `smartagentx_data`.
* **Resource Contention:** Concurrent Docker image builds (e.g. `docker compose build`) can consume CPU and RAM. The build for `SmartAgentX` is a static file copy (~1 second, ~20 MB RAM), presenting zero risk to running applications.

### 2.5 Operational & Deployment Script Conflicts

* **The Conflict:** `/opt/apps/deploy.sh` enforces a global execution lock (`/tmp/deploy.lock`) to prevent concurrent deployments.
* **The Solution:** Add a dedicated manifest `deploy/manifests/smartagentx.json`. Deployments of `smartagentx` will cleanly queue through the standard lock without interfering with platform deployments.

---

## 3. Shared vs Isolated Resource Strategy

To ensure reliability, security, and performance, infrastructure components are classified into shared versus isolated resources:

| Infrastructure Component | Recommendation | Architectural Justification |
| :--- | :--- | :--- |
| **Hetzner Cloud Server (`cx43`)** | **SHARED** | Sized with 8 vCPUs and 16 GB RAM. Collocation saves ~€35/month with zero resource contention given the lightweight nature of the second site. |
| **Hetzner Firewall (`coolify_fw`)** | **SHARED** | Edge firewall allows 22, 80, 443. Both applications rely on standard HTTP/HTTPS ingress. No new firewall rules required. |
| **Docker Engine & Daemon** | **SHARED** | Single Docker daemon manages all containers seamlessly. |
| **Docker Network (`coolify`)** | **SHARED** | Required for Traefik to discover and route HTTP packets to the container IP. |
| **Reverse Proxy (Traefik v3.6)** | **SHARED** | Traefik is natively multi-tenant and SNI-aware. It routes traffic for multiple separate apex domains simultaneously without crosstalk. |
| **Application Container** | **ISOLATED** | Runs in its own distinct container (`app_smartagentx_web`) with its own filesystem, process namespace, and resource limits. |
| **Filesystem / Code Path** | **ISOLATED** | Resides in dedicated directory `/opt/apps/smartagentx/`. No shared application files with `stratagemengine.com`. |
| **Database Instance (PostgreSQL)** | **ISOLATED (or NONE)** | For static site: NONE. If dynamic API added: create a dedicated logical database (e.g. `smartagentx_db`) with separate credentials. Never reuse existing platform databases. |
| **Redis / Cache** | **ISOLATED (or NONE)** | None required for static site. If needed in future, spin up an isolated container. |
| **SSL Certificates** | **ISOLATED** | Handled by Traefik via distinct SNI SAN entries in `acme.json`. A certificate failure for `smartagentx.ai` cannot invalidate `stratagemengine.com`. |
| **Logs** | **ISOLATED** | Logs collected per-container via standard Docker logging driver (`docker logs app_smartagentx_web`). |
| **Backups** | **ISOLATED / SHARED** | Shared backup schedule (`run-backup.sh`), but backups produce isolated timestamped tar/dump artifacts. |

---

## 4. Infrastructure-as-Code (IaC) Gap Summary

1. **Base Infrastructure is Governed by Terraform:** The Hetzner VM, firewall, and SSH keys are correctly represented in Terraform and match state (`terraform plan` = clean).
2. **Application & Routing Layer is Outside Terraform:** As documented in `10-SEPT-2026-PRODUCTION-DEPLOYMENT.md` §10.3, all application containers, Traefik routes, DNS records, and databases are managed via Docker Compose and runtime configurations.
3. **Implication:** The addition of the second website is an **application-layer deployment**; it does **not** introduce drift into Terraform state or require modifying `main.tf`.
