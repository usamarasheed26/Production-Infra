output "server_ipv4" {
  description = "Public IPv4 address of the Hetzner server."
  value       = hcloud_server.coolify.ipv4_address
}

output "server_ipv6" {
  description = "Public IPv6 address of the Hetzner server."
  value       = hcloud_server.coolify.ipv6_address
}

output "coolify_url" {
  description = "URL to access the Coolify Dashboard UI once bootstrapping finishes."
  value       = "http://${hcloud_server.coolify.ipv4_address}:8000"
}

output "ssh_private_key_path" {
  description = "Local path to the generated private key. Connect with: ssh -i <this path> root@<server_ipv4>"
  value       = "${path.module}/ssh/${var.ssh_key_name}"
}

output "ssh_connect_command" {
  description = "Ready-to-run SSH command for connecting to the Hetzner server as root."
  value       = "ssh -i ${path.module}/ssh/${var.ssh_key_name} root@${hcloud_server.coolify.ipv4_address}"
}
