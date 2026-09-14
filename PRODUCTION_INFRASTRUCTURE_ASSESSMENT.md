# Production Infrastructure Assessment: Current Architecture & Server Capacity

**Document Version:** 1.0  
**Date:** September 11, 2026  
**Primary Source of Truth:** Terraform Configuration (`c:\Simulators\Production Infrastructure`)  
**Verified Live State:** Hetzner Cloud API & Host Runtime Reconciliation (`10-SEPT-2026-PRODUCTION-DEPLOYMENT.md`)

---

## 1. Executive Summary & Infrastructure Overview

This assessment establishes the baseline infrastructure state of our production environment. The current production infrastructure is hosted on **Hetzner Cloud (HetzCloud)** and managed via Terraform. It hosts the **StratagemEngine Simulation Platform** ecosystem, consisting of a central Next.js platform, a marketing apex/www website with an integrated contact API, nine interactive simulation web applications, an authoritative PostgreSQL 18 instance, and the Coolify/Traefik control plane.

| Attribute | Specification | Source of Truth |
| :--- | :--- | :--- |
| **Cloud Provider** | Hetzner Cloud (`hcloud`) | `providers.tf`, `terraform.tfstate` |
| **Server Name** | `coolify-server` (Hetzner ID `163952663`) | `main.tf`, `terraform.tfstate` |
| **Server Type** | `cx43` (Cost-optimized shared AMD x86_64) | `variables.tf`, `terraform.tfstate` |
| **vCPU** | 8 vCPUs | Hetzner Server Catalog / API |
| **System RAM** | 16 GB Physical RAM + 4 GB Swap (`/swapfile`) | Live Host Inspection / `cloud-init.sh.tpl` |
| **Storage / Disk** | 160 GB NVMe SSD (Local Storage) | Hetzner Cloud Server Specification |
| **Data Center Location** | `fsn1` (Falkenstein DC Park 1, Germany, EU) | `variables.tf`, `terraform.tfstate` |
| **Operating System** | Ubuntu 24.04.4 LTS (Kernel `6.8.0-137-generic`) | `main.tf`, Live Server Inspection |
| **Public Networking** | IPv4: `46.224.15.73` \| IPv6: `2a01:4f8:c014:6336::1` (/64) | `terraform.tfstate` |
| **Private Networking** | None configured (`private_net = []`) | `terraform.tfstate` |
| **Attached Volumes** | None (`hcloud_volume` not used) | Hetzner API / `terraform.tfstate` |
| **Firewall** | `coolify-server-fw` (Hetzner ID `11539288`) | `main.tf`, `terraform.tfstate` |
| **Inbound Firewall Rules** | TCP 22 (SSH), TCP 80 (HTTP), TCP 443 (HTTPS) | `main.tf`, `terraform.tfstate` |
| **Container Engine** | Docker Engine `29.7.2` & Docker Compose v2 (`5.5.0`) | Live Host Inspection |
| **Reverse Proxy / Ingress** | Traefik v3.6 (`coolify-proxy` container) | Live Host Inspection |
| **TLS Certificate Issuer** | Let's Encrypt (Automated ACME HTTP-01 via Traefik) | `/data/coolify/proxy/acme.json` |
| **Authoritative Database** | PostgreSQL 18 (`om3fwlitdodg2ckjxbwhorn6`) | Live Host Inspection / Docker |
| **Terraform Version** | `1.15.7` (State Serial `12`, Provider `hcloud ~> 1.45`) | `providers.tf`, `terraform.tfstate` |

---

## 2. Reconstructed Production Architecture

The production architecture is a single-host, containerized multi-application ecosystem fronted by Traefik v3.6. 

```
                                      INTERNET
                                         │
                 ┌───────────────────────┴───────────────────────┐
                 │                                               │
                 ▼                                               ▼
         DNS Query (A / AAAA)                           Direct Web Traffic
                 │                                               │
                 ▼                                               ▼
     Namecheap Nameservers                      Hetzner Cloud Edge Network
  (*.stratagemengine.com -> 46.224.15.73)                        │
  (apex & www -> 46.224.15.73)                                   ▼
                                                   ┌───────────────────────────┐
                                                   │ Hetzner Cloud Firewall    │
                                                   │ (coolify-server-fw)       │
                                                   │ Inbound: 22, 80, 443      │
                                                   └─────────────┬─────────────┘
                                                                 │
                                                                 ▼
                                                  ┌────────────────────────────┐
                                                  │ Host OS: Ubuntu 24.04      │
                                                  │ (UFW: 22, 80, 443 only)    │
                                                  └──────────────┬─────────────┘
                                                                 │
                                                                 ▼
                                                  ┌────────────────────────────┐
                                                  │ Docker Engine (v29.7.2)    │
                                                  │ Container: coolify-proxy   │
                                                  │ (Traefik v3.6 Reverse Pxy) │
                                                  │ Binds: Host 80, 443, 8080  │
                                                  └──────────────┬─────────────┘
                                                                 │
                        ┌────────────────────────────────────────┴────────────────────────────────────────┐
                        │ Docker Network: `coolify` (Bridge: 172.x, Internal DNS, No Host Ports)           │
                        │                                                                                 │
       ┌────────────────┴────────────────┬───────────────────────────────┬────────────────────────────────┴────────────────┐
       ▼                                 ▼                               ▼                                                 ▼
┌────────────────────────┐    ┌────────────────────────┐    ┌────────────────────────┐                          ┌────────────────────────┐
│ Main Platform Stack    │    │ Marketing / Apex Stack │    │ 9 Simulation Stacks    │                          │ Control Plane Stack    │
│                        │    │                        │    │                        │                          │                        │
│ • app_platform         │    │ • app_www              │    │ • leadership (Flask)   │                          │ • coolify (4.3.18)     │
│   (Next.js 14, :3000)  │    │   (Nginx static, :80)  │    │ • autorevive (6 cont.) │                          │ • coolify-db (PG 15)   │
│ • supabase-rest        │    │ • app_api              │    │ • aitransformer (Fast) │                          │ • coolify-redis        │
│   (PostgREST, :3000)   │    │   (Node 22 API, :3000) │    │ • fmcg (FastAPI+Vite)  │                          │ • coolify-realtime     │
│ • supabase-storage     │    │ • contacts-db-coolify  │    │ • macrolab (Node/Vite) │                          │ • coolify-sentinel     │
│   (Storage API, :5000) │    │   (PG 16 dedicated)    │    │ • zerotopmf (FastAPI)  │                          └────────────────────────┘
│ • supabase-realtime    │    └────────────────────────┘    │ • simulationstudio     │                                     │
│   (Realtime, :4000)    │                                  │ • airevenueleakage     │                                     │
└──────────────┬─────────┘                                  └────────────┬───────────┘                                     │
               │                                                         │                                                 │
               └─────────────────────────┬───────────────────────────────┘                                                 │
                                         │                                                                                 │
                                         ▼                                                                                 ▼
                        ┌────────────────────────────────────────┐                                        ┌────────────────────────┐
                        │ Authoritative Database Instance        │                                        │ Off-Instance Databases │
                        │ Container: om3fwlitdodg2ckjxbwhorn6    │                                        │ (Drift / Convergence)  │
                        │ Engine: PostgreSQL 18 (Alpine)         │                                        │                        │
                        │ Logical DBs:                           │                                        │ • app_aitransformer_db │
                        │ • stratagem_platform                   │                                        │   (PG 16 - aets)       │
                        │ • leadership_db                        │                                        │ • db_airevenueleakage  │
                        │ • autorevive                           │                                        │   (PG 15 - airl)       │
                        │ • zerotopmf                            │                                        │ • macrolab SQLite      │
                        │ • simulationstudio_db                  │                                        │   (Local volume)       │
                        │ • fmcg                                 │                                        │ • contacts-db-coolify  │
                        │ • venturefund                          │                                        │   (PG 16 - contacts)   │
                        │ Volume: postgres-data-om3fwlitdodg...  │                                        └────────────────────────┘
                        └────────────────────────────────────────┘
```

---

## 3. Infrastructure Capacity & Resource Utilization

### 3.1 Server Capacity Matrix

| Metric | Server Limit (cx43) | Current Production Allocation / Consumption | Remaining Headroom | Status |
| :--- | :--- | :--- | :--- | :--- |
| **vCPU** | 8 vCPU (Shared AMD) | Average Load: `~1.1` (14% system-wide utilization) | `~6.9` vCPU capacity | **Abundant** |
| **RAM** | 16.0 GB Physical | `3.9 GB` currently used by all 11 applications + DBs | `12.1 GB` available | **Abundant** |
| **Swap** | 4.0 GB (`/swapfile`) | `0 MB` used (idle, `swappiness = 10`) | `4.0 GB` | **Optimal** |
| **NVMe Disk** | 160.0 GB Total | `33.0 GB` used (OS, Docker images, volumes, logs) | `117.0 GB` available | **Abundant** |
| **Bandwidth** | 20 TB / month | Minimal (educational simulations & marketing) | `> 19.5 TB` | **Abundant** |
| **Open Ports** | 3 TCP Ports | 22 (SSH), 80 (HTTP), 443 (HTTPS) | Fully utilized | **Locked** |

### 3.2 Distinction: Known from Terraform vs Runtime Verification

* **Known from Terraform:**
  - Machine sizing (`cx43`), location (`fsn1`), base OS image (`ubuntu-24.04`), and instance name (`coolify-server`).
  - Network configuration: Public IPv4 and IPv6 enabled, private networking disabled.
  - Ingress security rules: Ports 22, 80, 443 open. Port 8000 closed.
  - Lifecycle settings: `prevent_destroy = true` on server and firewall; `ignore_changes = [user_data]` on server.
* **Requires Runtime / Server Verification (Outside Terraform):**
  - Live memory and CPU consumption (Load ~1.1, 3.9 GB RAM used).
  - Number and health of Docker containers running on the host (11 app compose projects, 27 total containers).
  - Traefik routing rules, active domain names, and Let's Encrypt certificates.
  - Database schema, table counts, connection pools, and query performance.
  - Backup script execution status (`/opt/backups/run-backup.sh`).

---

## 4. Current Deployment & Control Plane Architecture

The host operates on a hybrid deployment model:

1. **Infrastructure Provisioning (Terraform):**
   - Provisions server, cloud firewall, and SSH keys.
   - Bootstraps the machine on first boot via `templates/cloud-init.sh.tpl` (creates swap, applies sysctl TCP hardening, installs UFW, downloads Coolify bootstrap).
   - Terraform does **not** manage application containers, database schemas, DNS, or Traefik routes.
2. **Reverse Proxy & TLS Termination (Traefik v3.6):**
   - The container `coolify-proxy` runs on host ports 80 and 443.
   - It listens for Docker socket events. When containers are labeled with `traefik.enable=true`, Traefik dynamically registers routes, sets up HTTP-to-HTTPS redirects, and automatically requests SSL/TLS certificates from Let's Encrypt using HTTP-01 challenge.
   - All certificates are stored in `/data/coolify/proxy/acme.json`.
3. **Application Layer (Docker Compose):**
   - Each application resides in `/opt/apps/<AppName>/` with its own `docker-compose.yml` or `docker-compose.prod.yml`.
   - All web-facing containers join the external Docker bridge network named `coolify`.
   - Applications do **not** publish ports to the host (no `80:80` or `3000:3000` on the host interface). They expose internal ports to the `coolify` network, and Traefik load balances traffic directly to the container IPs.
4. **Authoritative Database (PostgreSQL 18):**
   - Managed as container `om3fwlitdodg2ckjxbwhorn6` with persistent volume `postgres-data-om3fwlitdodg2ckjxbwhorn6`.
   - Connected strictly to the `coolify` network; port 5432 is **not** exposed to the internet.
   - Logical databases partition tenant data (`stratagem_platform`, `leadership_db`, `autorevive`, `zerotopmf`, etc.).
5. **Backups:**
   - Daily cron job at `02:30 UTC` executes `/opt/backups/run-backup.sh`.
   - Dumps all logical databases via `pg_dump -Fc` and compresses SQLite files to `/opt/backups/dumps/<timestamp>/` with 14-day retention.

---

## 5. IaC Boundary: Terraform Managed vs Unmanaged

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                       TERRAFORM-MANAGED LAYER                           │
│                                                                         │
│  • hcloud_server.coolify (cx43, Falkenstein fsn1, ID: 163952663)        │
│  • hcloud_firewall.coolify_fw (coolify-server-fw, ID: 11539288)          │
│  • hcloud_ssh_key.generated (production-infra-key, ID: 118084486)       │
│  • null_resource.ssh_key & data.local_file.public_key                   │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                   UNMANAGED / RUNTIME APPLICATION LAYER                 │
│                                                                         │
│  • Docker Engine & Compose configuration                                │
│  • Traefik v3.6 reverse proxy & routing rules                           │
│  • Let's Encrypt TLS certificates (acme.json)                           │
│  • DNS Records (Managed at Namecheap / external registrars)             │
│  • 11 Application Compose projects in /opt/apps/                        │
│  • Authoritative PostgreSQL 18 container & logical databases            │
│  • Coolify 4.3.18 control plane & personal access tokens                │
│  • Application environment files (.env.production) & secrets            │
│  • Backup cron jobs (/opt/backups/run-backup.sh)                        │
└─────────────────────────────────────────────────────────────────────────┘
```

This boundary is critical: **Hosting a second website on this server does NOT require modifying the Terraform-managed compute or firewall resources unless new infrastructure primitives (such as dedicated block storage or private networking) are introduced.**
