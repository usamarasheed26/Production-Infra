variable "hcloud_token" {
  description = "Hetzner Cloud API Token. Pass via TF_VAR_hcloud_token or terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Hetzner Cloud data center location slug (e.g. fsn1, nbg1, ash, hel1)."
  type        = string
  default     = "fsn1"
}

variable "server_type" {
  description = "Hetzner Cloud server type slug (e.g. cx43 for 8 vCPU / 16GB RAM, cpx22 for 2 vCPU / 4GB RAM)."
  type        = string
  default     = "cx43"
}

variable "server_image" {
  description = "Operating system image for the Hetzner server."
  type        = string
  default     = "ubuntu-24.04"
}

variable "server_name" {
  description = "Name of the Hetzner Cloud server instance."
  type        = string
  default     = "coolify-server"
}

variable "ssh_key_name" {
  description = "Name for the local SSH key pair and Hetzner uploaded SSH key resource."
  type        = string
  default     = "production-infra-key"
}
