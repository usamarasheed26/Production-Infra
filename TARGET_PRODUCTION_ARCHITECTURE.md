# Target Production Architecture: Multi-Domain Co-Hosting on Hetzner Cloud

**Document Version:** 1.0  
**Date:** September 11, 2026  
**Subject:** Architectural Blueprint for Hosting `smartagentx.ai` Alongside `stratagemengine.com` on `coolify-server`

---

## 1. Target Architecture Overview

The target architecture establishes a robust, secure, multi-tenant production environment on the single Hetzner Cloud `cx43` server. By leveraging **Traefik v3.6's dynamic reverse proxy capabilities and Server Name Indication (SNI)**, the server can concurrently host multiple unrelated apex domains and subdomains on standard HTTP (80) and HTTPS (443) ports with independent automated Let's Encrypt certificates and total application-layer isolation.

---

## 2. Reconstructed Target Architecture Diagram

```
                                                    THE INTERNET
                                                         │
                     ┌───────────────────────────────────┴───────────────────────────────────┐
                     │                                                                       │
                     ▼                                                                       ▼
             DNS Resolution                                                          DNS Resolution
        (Domain: stratagemengine.com)                                             (Domain: smartagentx.ai)
                     │                                                                       │
                     ▼                                                                       ▼
            Namecheap Nameservers                                                  Domain Registrar DNS
     • stratagemengine.com      -> 46.224.15.73                                  • smartagentx.ai     -> 46.224.15.73
     • *.stratagemengine.com    -> 46.224.15.73                                  • www.smartagentx.ai -> 46.224.15.73
                     │                                                                       │
                     └───────────────────────────────────┬───────────────────────────────────┘
                                                         │
                                                         ▼
                                       ┌───────────────────────────────────┐
                                       │ Hetzner Cloud Edge Network        │
                                       │ Public IPv4: 46.224.15.73         │
                                       │ Public IPv6: 2a01:4f8:c014:6336::1│
                                       └─────────────────┬─────────────────┘
                                                         │
                                                         ▼
                                       ┌───────────────────────────────────┐
                                       │ Hetzner Cloud Firewall            │
                                       │ Resource: coolify-server-fw       │
                                       │ Rules: 22/tcp, 80/tcp, 443/tcp    │
                                       └─────────────────┬─────────────────┘
                                                         │
                                                         ▼
                                       ┌───────────────────────────────────┐
                                       │ Server: coolify-server (cx43)     │
                                       │ OS: Ubuntu 24.04 LTS (UFW active) │
                                       └─────────────────┬─────────────────┘
                                                         │
                                                         ▼
                                       ┌───────────────────────────────────┐
                                       │ Docker Engine (v29.7.2)           │
                                       │ Ingress Container: coolify-proxy  │
                                       │ Engine: Traefik v3.6 Reverse Proxy│
                                       │ Binds: 0.0.0.0:80, 0.0.0.0:443    │
                                       │ TLS Storage: acme.json (SNI auto) │
                                       └─────────────────┬─────────────────┘
                                                         │
                     ┌───────────────────────────────────┴───────────────────────────────────┐
                     │                                                                       │
   [ Host: *.stratagemengine.com ]                                             [ Host: smartagentx.ai / www ]
                     │                                                                       │
                     ▼                                                                       ▼
┌────────────────────────────────────────┐                              ┌────────────────────────────────────────┐
│ ECOSYSTEM 1: STRATAGEMENGINE           │                              │ ECOSYSTEM 2: SMARTAGENTX.AI            │
│ (Existing Platform & Simulations)      │                              │ (New Production Workload)              │
│                                        │                              │                                        │
│ • app_platform (Next.js 14, Clerk)     │                              │ • app_smartagentx_web                  │
│ • app_www (Nginx static marketing)     │                              │   (Nginx 1.27-alpine, :80 internal)    │
│ • app_api (Node 22 Express contact)    │                              │   (Clean URLs, Gzip, Sec Headers)      │
│ • 9 Simulation Containers              │                              │   (Path: /opt/apps/smartagentx)        │
│   (leadership, autorevive, zerotopmf,  │                              │                                        │
│    aitransformer, fmcg, macrolab, etc.)│                              │ [Optional Future Contact API]          │
│ • Supabase REST/Storage/Realtime layer │                              │ • app_smartagentx_api (Node/Python)    │
│ • Authoritative PostgreSQL 18          │                              │ • Dedicated isolated logical DB        │
│   (om3fwlitdodg2ckjxbwhorn6)           │                              │   (smartagentx_db on PG18 or SQLite)   │
└────────────────────────────────────────┘                              └────────────────────────────────────────┘
```

---

## 3. Component State Breakdown

| Component | Nature | State | Scope | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **Hetzner Server (`cx43`)** | Infrastructure | **Existing / Unchanged** | Shared | Hosts all containers; ample 12 GB RAM & 117 GB NVMe headroom. |
| **Hetzner Firewall (`coolify-server-fw`)** | Infrastructure | **Existing / Unchanged** | Shared | Ports 22, 80, 443 remain open. Zero firewall edits needed. |
| **Hetzner SSH Key (`production-infra-key`)**| Infrastructure | **Existing / Unchanged** | Shared | Root administrative key. |
| **Traefik Reverse Proxy (`coolify-proxy`)** | Routing / TLS | **Existing / Unchanged** | Shared | Dynamically reads labels from new container via Docker socket. |
| **Docker Network (`coolify`)** | Networking | **Existing / Unchanged** | Shared | Bridge network connecting Traefik to all application containers. |
| **Authoritative PostgreSQL 18** | Persistence | **Existing / Unchanged** | Isolated | Unchanged. No access granted to the second site unless explicitly provisioned. |
| **StratagemEngine Apps (11 projects)** | Applications | **Existing / Unchanged** | Isolated | Completely isolated from the new website. Zero downtime. |
| **New Directory `/opt/apps/smartagentx/`** | Filesystem | **NEW** | Isolated | Dedicated deployment location on production host. |
| **Container `app_smartagentx_web`** | Workload | **NEW** | Isolated | Static Nginx Alpine container serving `smartagentx.ai`. |
| **DNS A Records (`smartagentx.ai`)** | DNS | **NEW** | External | Points `@` and `www` to `46.224.15.73` at domain registrar. |
| **Let's Encrypt Certificate (`smartagentx.ai`)** | Security / TLS | **NEW** | Isolated | Automatically acquired by Traefik on first HTTPS request. |
| **Deploy Manifest (`deploy/manifests/smartagentx.json`)** | Operations | **NEW** | Operations | Integrates into the host deployment automation (`deploy.sh`). |

---

## 4. Production-Grade Container Specification for Second Website

To ensure zero port conflicts and seamless integration with Traefik, the second application must use the following standard `docker-compose.yml` pattern in `/opt/apps/smartagentx/`:

```yaml
version: '3.8'

services:
  smartagentx-web:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: app_smartagentx_web
    restart: always
    # NOTE: NO host port bindings (do NOT use "80:80" or "443:443")
    expose:
      - "80"
    networks:
      - coolify
    environment:
      - TZ=UTC
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 256M
        reservations:
          cpus: '0.1'
          memory: 64M
    labels:
      - "traefik.enable=true"
      
      # --- HTTP Router: Redirect all HTTP to HTTPS ---
      - "traefik.http.routers.smartagentx-http.rule=Host(`smartagentx.ai`) || Host(`www.smartagentx.ai`)"
      - "traefik.http.routers.smartagentx-http.entrypoints=http"
      - "traefik.http.routers.smartagentx-http.middlewares=smartagentx-redirect"
      - "traefik.http.middlewares.smartagentx-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.smartagentx-redirect.redirectscheme.permanent=true"
      
      # --- HTTPS Router: Primary Production Secure Endpoint ---
      - "traefik.http.routers.smartagentx-https.rule=Host(`smartagentx.ai`) || Host(`www.smartagentx.ai`)"
      - "traefik.http.routers.smartagentx-https.entrypoints=https"
      - "traefik.http.routers.smartagentx-https.tls=true"
      - "traefik.http.routers.smartagentx-https.tls.certresolver=letsencrypt"
      - "traefik.http.routers.smartagentx-https.tls.domains[0].main=smartagentx.ai"
      - "traefik.http.routers.smartagentx-https.tls.domains[0].sans=www.smartagentx.ai"
      
      # --- Service Port Mapping (Container Internal Port) ---
      - "traefik.http.services.smartagentx-service.loadbalancer.server.port=80"

networks:
  coolify:
    external: true
```

---

## 5. Ingress & Traffic Flow

1. **Client Request:** A browser requests `https://smartagentx.ai/revenue-leakage`.
2. **DNS:** Resolves `smartagentx.ai` to `46.224.15.73`.
3. **Firewall:** Hetzner Cloud Firewall permits inbound traffic on port 443.
4. **Traefik Ingress:** `coolify-proxy` receives the TLS ClientHello containing the SNI extension for `smartagentx.ai`.
5. **TLS Handshake:** Traefik checks its certificate cache (`acme.json`). If present, it terminates TLS. If first hit, it requests a certificate from Let's Encrypt via HTTP-01 challenge on port 80.
6. **Route Matching:** Traefik evaluates its router rules:
   - `Host(`stratagemengine.com`)` -> routes to `app_www`
   - `Host(`smartagentx.ai`)` -> matches `smartagentx-https` router -> routes to `app_smartagentx_web`
7. **Container Execution:** The request is proxied over the `coolify` Docker network to `app_smartagentx_web:80`. Nginx executes clean URL resolution (`try_files $uri $uri.html /index.html =404`) and returns the HTML payload with Gzip compression and security headers.
