# Terraform Change Plan: Infrastructure-as-Code Impact Assessment

**Document Version:** 1.0  
**Date:** September 11, 2026  
**Subject:** Terraform Code Impact Analysis for Hosting a Second Website on Current Production Infrastructure  
**Baseline State:** Local state `terraform.tfstate` (Serial 12, Terraform v1.15.7, Provider `hcloud ~> 1.45`)

---

## 1. Executive Terraform Verdict

### **Verdict: NO TERRAFORM CHANGES REQUIRED**

Hosting the second website (`smartagentx.ai`) on the existing production server requires **zero modifications to the core Terraform configuration** to achieve full production availability.

### Why No Terraform Changes Are Required:
1. **Firewall Ingress:** In `main.tf`, `hcloud_firewall.coolify_fw` already permits inbound TCP traffic on ports `80` (HTTP) and `443` (HTTPS) from `0.0.0.0/0` and `::/0`. Traefik routes multiple domains over these same standard ports using SNI.
2. **Compute & Network:** The existing `hcloud_server.coolify` resource already possesses a dedicated public IPv4 (`46.224.15.73`) and IPv6 (`2a01:4f8:c014:6336::1`). No extra network interfaces, floating IPs, or server resizes are needed.
3. **Application Layer Boundary:** In this production environment, Docker containers, reverse proxy rules, SSL certificates, and DNS records are provisioned at the runtime/application layer, completely outside Terraform state.

---

## 2. Resource-by-Resource Audit

The current Terraform project contains exactly five resources/data sources. Each is evaluated below:

| File | Terraform Resource / Data Source | Proposed Change | Reason / Impact | Risk Level |
| :--- | :--- | :--- | :--- | :--- |
| `main.tf` | `null_resource.ssh_key` | **NONE** | Generates local ed25519 key pair once. Key exists and is operational. | None |
| `main.tf` | `data.local_file.public_key` | **NONE** | Reads generated public key from `./ssh/production-infra-key.pub`. | None |
| `main.tf` | `hcloud_ssh_key.generated` | **NONE** | Uploads SSH public key to Hetzner Cloud. Key ID `118084486` active. | None |
| `main.tf` | `hcloud_firewall.coolify_fw` | **NONE** | Inbound 22, 80, 443 are already open. Web traffic for both websites enters via 80 and 443. | None |
| `main.tf` | `hcloud_server.coolify` | **NONE** | Sized at `cx43` (8 vCPU, 16 GB RAM, 160 GB NVMe). Capacity is 86% free. Protected by `prevent_destroy = true`. | None |
| `variables.tf` | All variables | **NONE** | Server name, location, and sizing variables remain identical. | None |
| `outputs.tf` | All outputs | **NONE (or Minor Optional)** | Output `server_ipv4` is already `46.224.15.73`. An optional documentation output may be added if desired. | None |
| `providers.tf` | `terraform` & `provider "hcloud"` | **NONE** | Version constraints and API token configuration remain unchanged. | None |

---

## 3. Detailed Categorization of Changes

### 3.1 No Terraform Changes Required
* **`main.tf` (hcloud_server, hcloud_firewall, hcloud_ssh_key):** Unmodified.
* **`variables.tf`:** Unmodified.
* **`providers.tf`:** Unmodified.
* **Current `terraform plan`:** Verified clean (`No changes. Your infrastructure matches the configuration.`).

### 3.2 Existing Terraform Resource Modification Required
* **NONE for migration.**
* *(Optional Future Infrastructure Hardening - Non-Blocking):*
  If desired during a scheduled maintenance window, the operator can enable automated server backups on Hetzner Cloud:
  ```hcl
  # In main.tf (hcloud_server.coolify)
  backups = true
  ```
  *Note:* On Hetzner Cloud, enabling backups via the provider does **not** replace the server (in-place API call), but must be verified with `terraform plan` beforehand.

### 3.3 New Terraform Resources Required
* **NONE.** No additional cloud servers, private networks, block storage volumes, or floating IPs are required.

### 3.4 Existing / New Terraform Modules Required
* **NONE.** The architecture does not use modules.

### 3.5 Out of Terraform Scope (Application & Operational Changes Required)
Because Terraform manages only the base infrastructure primitives, all migration actions occur at the application and edge routing layers:
1. **Domain Registrar DNS Configuration:** Creating A records for `smartagentx.ai` pointing to `46.224.15.73`.
2. **Server Filesystem Provisioning:** Creating directory `/opt/apps/smartagentx/`.
3. **Application Docker Compose:** Authoring `/opt/apps/smartagentx/docker-compose.yml` with Traefik routing labels on the `coolify` network.
4. **CI/CD Manifest Integration:** Adding `deploy/manifests/smartagentx.json` for automated deployments via `deploy.sh`.

---

## 4. Terraform Safety & Recreation Guardrails

Because `coolify-server` hosts the entire production ecosystem (all 11 existing application containers and the authoritative PostgreSQL 18 database with persistent named volumes), accidental recreation or destruction of the server would be **catastrophic**.

The following safeguards in `main.tf` are confirmed active:

1. **`prevent_destroy = true` on `hcloud_server.coolify`:**
   ```hcl
   lifecycle {
     prevent_destroy = true
     ignore_changes  = [user_data]
   }
   ```
   Terraform will explicitly reject and abort any execution plan that attempts to destroy or recreate the server.
2. **`ignore_changes = [user_data]` on `hcloud_server.coolify`:**
   Any changes to `templates/cloud-init.sh.tpl` will **not** trigger server replacement.
3. **`prevent_destroy = true` on `hcloud_firewall.coolify_fw`:**
   Guards the edge firewall from inadvertent destruction.

### Safe Command Policy
* Operators must **NEVER** run `terraform apply` without first inspecting `terraform plan`.
* If `terraform plan` ever shows `forces replacement` or `destroy`, the command must be immediately terminated.
* For the migration of the second website, **running `terraform apply` is completely unnecessary and discouraged**.
