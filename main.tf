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

# Cloud firewall: open 22 (SSH), 80 (HTTP), 443 (HTTPS), 8000 (Coolify UI)
resource "hcloud_firewall" "coolify_fw" {
  name = "${var.server_name}-fw"

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

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "8000"
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
}
