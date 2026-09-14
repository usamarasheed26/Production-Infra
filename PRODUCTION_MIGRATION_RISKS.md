# Production Migration Risks: Risk Register & Availability Impact Assessment

**Document Version:** 1.0  
**Date:** September 11, 2026  
**Subject:** Risk Matrix, Availability Impact Analysis, and Mitigation Safeguards for Multi-Tenant Production Infrastructure

---

## 1. Production Availability Impact Assessment

A paramount requirement for this infrastructure migration is ensuring that the **11 existing production applications and authoritative databases experience ZERO downtime and ZERO degradation**.

The table below evaluates every potential production-impacting operation:

| Potential Operation | Required for Migration? | Can Cause Downtime? | Analysis & Safety Safeguard |
| :--- | :--- | :--- | :--- |
| **Server Restart / Reboot** | **NO** | YES (if done) | Completely unnecessary. Linux kernel, network stack, and Docker daemon continue running without reboot. |
| **Docker Daemon Restart** | **NO** | YES (if done) | Completely unnecessary. Docker dynamically registers new containers without daemon restart. |
| **Reverse Proxy (Traefik) Restart** | **NO** | YES (if done) | Traefik v3.6 watches `/var/run/docker.sock`. It discovers new container labels and creates routes **in-memory with zero proxy restarts**. |
| **Firewall Modification** | **NO** | NO | Inbound ports 80 and 443 are already open. No firewall reload or ruleset change is needed. |
| **Terraform Apply** | **NO** | CATASTROPHIC (if run incorrectly) | **Do NOT run `terraform apply`.** Hosting the second site is purely an application-layer change. Terraform state remains untouched. |
| **Server Resizing** | **NO** | YES (if done) | Sizing at `cx43` has 12 GB free RAM and 86% free CPU capacity. No resize required. |
| **Database Modification** | **NO** | NO | The existing PostgreSQL 18 instance is not touched. The new static website requires no database. |
| **SSL / TLS Certificate Issuance** | **YES** | NO | Traefik issues individual certificates per domain via SNI. The issuance process for `smartagentx.ai` cannot invalidate or interrupt existing certs for `stratagemengine.com`. |

---

## 2. Comprehensive Risk Register

| Risk ID | Risk Description | Severity (Pre-Mitigation) | Probability | Mitigation Strategy & Controls | Residual Risk |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **RSK-01** | **Host Port Collision**<br>New compose file binds `80:80` or `443:443`, conflicting with Traefik or crashing ingress. | **CRITICAL** | Medium | Mandate that `ports:` is omitted from the new compose file. Container must use `expose: ["80"]` and connect strictly to the `coolify` Docker network. | **Negligible** |
| **RSK-02** | **Accidental Server Recreation via Terraform**<br>Inadvertent execution of `terraform apply` after modifying `main.tf` destroys the server and all production volumes. | **CATASTROPHIC** | Low | Active `lifecycle { prevent_destroy = true }` and `ignore_changes = [user_data]` in `main.tf` block destruction. Policy forbids running `terraform apply` for app deployments. | **Negligible** |
| **RSK-03** | **Let's Encrypt Rate Limiting & ACME Failures**<br>Misconfigured domain or CAA records trigger Let's Encrypt failure loops, hitting weekly issuance limits. | **HIGH** | Low | Pre-verify DNS A records using `dig` or `nslookup` before sending the first HTTPS request. Ensure no conflicting CAA records exist at registrar. | **Low** |
| **RSK-04** | **Host Memory Pressure During Image Build**<br>Running resource-heavy Node builds (`next build`) triggers Linux Out-Of-Memory (OOM) killer, killing DB or apps. | **HIGH** | Very Low | `SmartAgentX` uses static Alpine Nginx. The Docker build simply copies pre-built static files (< 20 MB RAM, 1 second). Enforce Docker deploy resource limits (`limits: memory: 256M`). | **Negligible** |
| **RSK-05** | **Apex DNS Conflict (The "Outlook CNAME" Pitfall)**<br>An illegal apex CNAME at the registrar shadows the A record, causing ACME HTTP-01 challenges to fail. | **HIGH** | Medium | Audit registrar records prior to cutover. Ensure `@` is strictly an `A` record pointing to `46.224.15.73` (not a CNAME to Vercel, Microsoft, or third-party). | **Low** |
| **RSK-06** | **Traefik Router Name Collision**<br>Duplicate router names in container labels overwrite existing StratagemEngine routes. | **HIGH** | Very Low | Enforce strict naming conventions (`traefik.http.routers.smartagentx-*`). Router names must be unique across all containers. | **Negligible** |
| **RSK-07** | **Inadvertent Public Exposure of Private Services**<br>Developer mistakenly exposes database or internal container port to `0.0.0.0` on the host. | **HIGH** | Low | Hetzner Cloud Firewall (`coolify-server-fw`) and host UFW block all inbound ports except 22, 80, and 443. Any port bound on host remains unreachable from internet. | **Negligible** |
| **RSK-08** | **Single Point of Failure (SPOF)**<br>Both distinct websites reside on the same physical VPS; a host hardware failure brings down both domains. | **MEDIUM** | Low | Documented architectural trade-off. Mitigated by daily automated database backups (`/opt/backups/run-backup.sh`) and local retention. Future recommendation: enable Hetzner automated snapshots. | **Low** |

---

## 3. Operational Safeguards & Emergency Protocols

1. **Deployment Lock:**
   All automated deployments must route through `/opt/apps/deploy.sh` to leverage the global lockfile (`/tmp/deploy.lock`), preventing simultaneous concurrent builds.
2. **Pre-Deployment Backup Verification:**
   Before introducing any new application container or modifying Docker network attachments, verify that the daily backup at `/opt/backups/dumps/` is fresh and non-empty.
3. **Emergency Disconnect:**
   If the new application exhibits abnormal behavior or excessive resource consumption:
   ```bash
   cd /opt/apps/smartagentx
   docker compose down
   ```
   This immediately halts the container and purges the Traefik route within seconds, restoring the host to its baseline state without touching existing services.
