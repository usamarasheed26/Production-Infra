# Generate a fresh ed25519 key pair locally via the system's ssh-keygen binary.
# The private key is written straight to disk by ssh-keygen and never passes
# through Terraform state -- only the public key (read back via data.local_file)
# is sent to Hetzner Cloud. Guarded so it only generates once: if the key
# files already exist, ssh-keygen is skipped.
resource "null_resource" "ssh_key" {
  triggers = {
    key_name = var.ssh_key_name
  }

  provisioner "local-exec" {
    interpreter = ["C:/Program Files/Git/bin/bash.exe", "-c"]
    command     = <<-EOT
      set -euo pipefail
      mkdir -p "${path.module}/ssh"
      key_path="${path.module}/ssh/${var.ssh_key_name}"
      if [ ! -f "$key_path" ]; then
        ssh-keygen -t ed25519 -f "$key_path" -N "" -C "${var.ssh_key_name}"
      fi
    EOT
  }
}

data "local_file" "public_key" {
  filename   = "${path.module}/ssh/${var.ssh_key_name}.pub"
  depends_on = [null_resource.ssh_key]
}

# Uploads the generated public key to the Hetzner Cloud account.
resource "hcloud_ssh_key" "generated" {
  name       = var.ssh_key_name
  public_key = data.local_file.public_key.content
}

# Cloud firewall: inbound 22 (SSH), 80 (HTTP), 443 (HTTPS) only.
#
# Port 8000 (Coolify dashboard) was removed 2026-09-11 (P0 #2). Nothing depends
# on inbound 8000 — Coolify manages 0 applications, has no FQDN and no webhooks,
# so it was only ever a human opening the UI. Reach the dashboard through an SSH
# tunnel instead:
#     ssh -i ./ssh/production-infra-key -L 8000:localhost:8000 root@<server_ipv4>
#     then open http://localhost:8000
# The container still binds 0.0.0.0:8000 on the host; this firewall is what keeps
# it off the internet. See 10-SEPT-2026-PRODUCTION-DEPLOYMENT.md §13.
resource "hcloud_firewall" "coolify_fw" {
  name = "${var.server_name}-fw"

  # This firewall is the only ingress control in front of a single-host
  # production box running ~11 apps, Coolify, Traefik and the production
  # Postgres. Never let Terraform delete/recreate it.
  lifecycle {
    prevent_destroy = true
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "80"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "443"
    source_ips = [
      "0.0.0.0/0",
      "::/0"
    ]
  }
}

# Provision Hetzner Cloud Server
resource "hcloud_server" "coolify" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.server_image
  location    = var.location
  ssh_keys    = [hcloud_ssh_key.generated.id]

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  firewall_ids = [hcloud_firewall.coolify_fw.id]

  user_data = file("${path.module}/templates/cloud-init.sh.tpl")

  # This server IS production. It carries all application containers, the
  # Coolify control plane, the Traefik proxy, every app's data volume and the
  # authoritative production Postgres (container om3fwlitdodg2ckjxbwhorn6,
  # volume postgres-data-om3fwlitdodg2ckjxbwhorn6) — none of which live in
  # Terraform state. A destroy/replace wipes all of it. Changing user_data,
  # server_type, image or location forces replacement, so guard against it.
  # Resizing must be done via the Hetzner console/API, not Terraform, until
  # the app layer is captured in IaC. See 10-SEPT-2026-PRODUCTION-DEPLOYMENT.md.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [user_data]
  }
}
