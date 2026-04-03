output "vmss_id" {
  description = "ID of the VMSS"
  value       = azurerm_linux_virtual_machine_scale_set.scraper.id
}

output "vmss_name" {
  description = "Name of the VMSS"
  value       = azurerm_linux_virtual_machine_scale_set.scraper.name
}

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.this.name
}

output "tailscale_preauth_key_expiry" {
  description = "When the Tailscale pre-auth key expires"
  value       = tailscale_tailnet_key.vmss.expires_at
}

output "agent_join_info" {
  description = "Info for manually joining additional agents"
  sensitive   = true
  value = {
    k3s_url   = "https://${var.k3s_master_tailscale_ip}:6443"
    k3s_token = var.k3s_token
  }
}

output "vmss_identity_principal_id" {
  description = "Principal ID of the VMSS system-assigned managed identity"
  value       = azurerm_linux_virtual_machine_scale_set.scraper.identity[0].principal_id
}

output "nat_gateway_public_ip" {
  description = "Public IP used by all VMSS instances for outbound traffic"
  value       = azurerm_public_ip.nat.ip_address
}
