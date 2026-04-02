variable "azure_subscription_id" {
  description = "Azure subscription ID"
  type        = string
  default     = "394058e8-419b-4eb4-bc98-58f37c4a0c48"
}

variable "azure_tenant_id" {
  description = "Azure AD tenant ID (used in azure.json for CSI drivers)"
  type        = string
  default     = "930f9de9-dca2-467e-85f9-ce76cb1551fa"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "francecentral"
}

variable "resource_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "mf-scraper"
}

variable "vm_sku" {
  description = "VMSS instance size (Standard_D4s_v3 = 4 vCPU, 16GB RAM, ~8-10 browser workers)"
  type        = string
  default     = "Standard_D4s_v3"
}

variable "instance_count" {
  description = "Number of VMSS instances"
  type        = number
  default     = 12
}

variable "use_spot" {
  description = "Use Spot instances for cost savings (may be evicted)"
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "Max price for Spot instances (-1 = on-demand price cap)"
  type        = number
  default     = -1
}

variable "admin_username" {
  description = "SSH admin user on VMSS nodes"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for VMSS admin access"
  type        = string
  default     = "~/.ssh/id_ed25519_wsl2_windows.pub"
}

variable "k3s_version" {
  description = "k3s version to install on agents (must match server)"
  type        = string
  default     = "v1.31.12+k3s1"
}

variable "k3s_master_tailscale_ip" {
  description = "Tailscale IP of the k3s server node"
  type        = string
}

variable "k3s_token" {
  description = "k3s node token for agent join (from /var/lib/rancher/k3s/server/node-token)"
  type        = string
  sensitive   = true
}

variable "tailscale_api_key" {
  description = "Tailscale API key for generating pre-auth keys"
  type        = string
  sensitive   = true
}

variable "tailscale_tailnet" {
  description = "Tailscale tailnet name (e.g. your-org.ts.net or user@gmail.com)"
  type        = string
}

variable "tags" {
  description = "Tags applied to all Azure resources"
  type        = map(string)
  default = {
    project     = "mindflayer"
    environment = "dev"
    managed_by  = "terraform"
  }
}
