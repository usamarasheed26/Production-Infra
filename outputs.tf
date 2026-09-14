output "server_ipv4" {
  description = "Public IPv4 address of the Hetzner server."
  value       = hcloud_server.coolify.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 address of the Hetzner server."
  value       = hcloud_server.coolify.ipv6_address
}

output "coolify_dashboard_access" {
  description = "Coolify UI is not exposed publicly (firewall). Tunnel in, then open http://localhost:8000"
  value       = "ssh -i ${path.module}/ssh/${var.ssh_key_name} -L 8000:localhost:8000 root@${hcloud_server.coolify.ipv4_address}"
}

output "ssh_private_key_path" {
  description = "Local path to the generated private key. Connect with: ssh -i <this path> root@<server_ipv4>"
  value       = "${path.module}/ssh/${var.ssh_key_name}"
}

output "ssh_connect_command" {
  description = "Ready-to-run SSH command for connecting to the Hetzner server as root."
  value       = "ssh -i ${path.module}/ssh/${var.ssh_key_name} root@${hcloud_server.coolify.ipv4_address}"
}
