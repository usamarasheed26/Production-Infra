# Second Application Requirements: Infrastructure, Runtime & Resource Profile

**Document Version:** 1.0  
**Date:** September 11, 2026  
**Subject:** Feasibility Analysis for Hosting a Second Website with a Different Domain on Production Server `coolify-server`

---

## 1. Application Discovery & Identification

Based on codebase discovery across active project workspaces and the recent migration engineering trajectory, the second application target is:

* **Primary Application Identified:** **`SmartAgentX.ai`** (`smartagentx-site-main`)
* **Target Production Domains:** `smartagentx.ai` (Apex) and `www.smartagentx.ai` (Subdomain)
* **Current Hosting Baseline:** Previously hosted on Vercel (`vercel.json`), recently containerized for VPS migration with `nginx:1.27-alpine`.
* **Nature of Application:** Multi-page high-performance commercial AI product and advisory website.
* **Secondary / Extended Application Consideration:** To ensure exhaustive analysis, this document also evaluates the requirements of a **Dynamic Full-Stack Web Application** (e.g., Next.js / FastAPI with database and background workers) should the user subsequently deploy dynamic product components (such as an AI auditor portal or backend API).

---

## 2. Primary Candidate: SmartAgentX.ai Specification

### 2.1 Technology Stack & Runtime

| Component | Specification | Details |
| :--- | :--- | :--- |
| **Framework / Architecture** | Multi-Page Application (MPA) | Semantic HTML5, CSS3 custom properties, ES6+ vanilla JavaScript |
| **Web Server / Runtime** | Nginx `1.27-alpine` | High-performance reverse-proxy friendly static file server |
| **Clean URL Routing** | Nginx `try_files` | Maps `/revenue-leakage` -> `/revenue-leakage.html`, `/shopify-ai-readiness` -> `.html`, `/agentic-build-sprint` -> `.html`, `/about`, `/contact` |
| **Asset Directory** | `Public/` | Contains all HTML pages, scripts, styles, SVGs, robots.txt, sitemap.xml |
| **Build Process** | Static Asset Verification | `npm run build` runs verification script asserting all 9 core assets exist |
| **Test Suite** | Node.js Test Harness | `npm test` runs syntax/HTML validation (`validate-syntax.js`) and HTTP 200 route smoke tests (`smoke-test.js`) across 15 routes |

### 2.2 Containerization & Docker Specification

* **Base Docker Image:** `nginx:1.27-alpine` (~23 MB image size).
* **Container Role:** Internal HTTP static web server listening on container port `80`.
* **Healthcheck:**
  ```dockerfile
  HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://localhost/healthz || exit 1
  ```
* **Required Internal Ports:** Port `80` (TCP, container internal).
* **Host Port Bindings:** **NONE**. Must **NOT** publish `80:80` or `443:443` on the host interface.
* **Network Requirement:** Must attach to the external Docker network `coolify` to allow Traefik to discover and route to it.

### 2.3 Persistence & Database Requirements

* **Primary Website:** **100% Stateless.**
  - No database required for the core website.
  - No Redis / cache container required.
  - No persistent volume storage required for website content (content is baked into the Docker image or mounted read-only from Git repository).
* **Optional Future Contact API / Ingest Backend:**
  - If a dynamic contact-form API or lead ingest is added (mirroring `stratagemengine.com`'s `app_api` + `contacts-db-coolify`), it will require:
    - Node.js or Python backend container.
    - An isolated PostgreSQL logical database (e.g. `smartagentx_contacts` on the authoritative PostgreSQL 18 instance or a dedicated lightweight Coolify-managed container).
    - In-memory rate limiting or shared Redis.

### 2.4 External Dependencies & Integrations

* **Calendly:** Embedded client-side booking widget (`https://calendly.com/smartagentx`).
* **External Links:** LinkedIn, GitHub, industry research citations (McKinsey QuantumBlack, BCG).
* **Font CDN:** Google Fonts (`Outfit`, `DM Mono`, `Plus Jakarta Sans`).
* **Outbound Network Traffic:** Only client-side browser requests; the container itself requires zero outbound internet connectivity at runtime (except package updates during image build).

---

## 3. Resource Consumption Profile

### 3.1 Estimated Utilization (SmartAgentX.ai Static Container)

| Resource | Minimum Reservation | Normal Operational Load | Peak Build / Spike Load | Current Host Headroom | Sizing Assessment |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **CPU** | 0.05 vCPU | 0.10 vCPU | 0.50 vCPU (under heavy load) | ~6.9 vCPU free | **negligible (< 2%)** |
| **RAM** | 32 MB | 64 MB | 128 MB | 12,100 MB free | **negligible (< 1%)** |
| **NVMe Disk** | 50 MB | 150 MB (image + logs) | 500 MB | 117,000 MB free | **negligible (< 0.5%)** |
| **Bandwidth**| Minimal | ~5–10 GB / month | ~50 GB / month | 20,000 GB / month | **negligible (< 0.2%)** |

### 3.2 Extended Scenario: Dynamic Full-Stack Web Application

If the second application includes a dynamic backend (e.g. Next.js SSR / Node.js API + PostgreSQL + Redis worker):

| Resource | Typical Requirement | Capacity on `cx43` Host | Feasibility Verdict |
| :--- | :--- | :--- | :--- |
| **vCPU** | 0.5 – 1.5 vCPU | 8 vCPU available, current load 1.1 | **Fully Capable** |
| **RAM** | 512 MB – 1.5 GB | 12.1 GB available | **Fully Capable** |
| **Disk** | 2 – 5 GB (dependencies, DB volume) | 117 GB available | **Fully Capable** |
| **Database** | Logical DB on PostgreSQL 18 | `om3fwlitdodg2ckjxbwhorn6` has minimal load | **Fully Capable** |

---

## 4. Domain, DNS & TLS Requirements

| Parameter | Second Application Requirement | How Production Environment Handles It |
| :--- | :--- | :--- |
| **Apex Domain** | `smartagentx.ai` | External DNS A record pointing to `46.224.15.73` |
| **Subdomain** | `www.smartagentx.ai` | External DNS A record (or CNAME) pointing to `46.224.15.73` |
| **DNS Management** | Managed at Domain Registrar (e.g., Namecheap, Cloudflare, GoDaddy) | Unmanaged by Terraform. Configured directly in registrar DNS dashboard. |
| **TLS / HTTPS** | Valid X.509 Certificate with SNI | Handled automatically by Traefik (`coolify-proxy`) using Let's Encrypt HTTP-01 resolver. Traefik auto-generates certificates for any domain declared in container labels. |
| **HTTP Redirect** | 301 Permanent Redirect HTTP -> HTTPS | Handled by Traefik middleware (`redirectscheme`). |

---

## 5. Missing Information & Pre-Implementation Verification Checklist

Before initiating deployment of the second application onto production infrastructure, the following operational details must be confirmed:

1. **Exact Repository & Branch to Deploy:**
   - Confirm git repository URL (e.g. `https://github.com/<org>/smartagentx-site`) and canonical production branch (`main`).
2. **DNS Authority & Access:**
   - Identify domain registrar / DNS provider for `smartagentx.ai`.
   - Confirm whether DNS A records for `@` and `www` can be updated to point to `46.224.15.73`.
   - Verify if any CAA (Certificate Authority Authorization) records exist that would restrict Let's Encrypt from issuing certificates.
3. **Contact / Form Ingest Strategy:**
   - Confirm whether the website form submits to an external endpoint (e.g. Formspree, Google Apps Script, HubSpot) or requires an internal server-side API (`app_api`) backed by Postgres.
4. **Subdomain Architecture:**
   - Confirm if any other subdomains exist (e.g. `pulse.smartagentx.ai` or `app.smartagentx.ai`) and whether they are hosted elsewhere or also migrating to this server.
