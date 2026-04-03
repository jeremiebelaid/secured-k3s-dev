locals {
  rg_name  = "${var.resource_prefix}-rg"
  vmss_name = "${var.resource_prefix}-vmss"
  vnet_name = "${var.resource_prefix}-vnet"
  nsg_name  = "${var.resource_prefix}-nsg"
}

# ---------------------------------------------------------------------------
# Tailscale pre-auth key (reusable, ephemeral, auto-approved)
# ---------------------------------------------------------------------------
resource "tailscale_tailnet_key" "vmss" {
  reusable      = true
  ephemeral     = true
  preauthorized = true
  expiry        = 86400
  description   = "mindflayer VMSS scraper nodes"
  tags          = ["tag:k3s-agent"]
}

# ---------------------------------------------------------------------------
# Resource Group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "this" {
  name     = local.rg_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "this" {
  name                = local.vnet_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.100.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "vmss" {
  name                 = "vmss-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.100.1.0/24"]
}

resource "azurerm_network_security_group" "vmss" {
  name                = local.nsg_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  security_rule {
    name                       = "AllowTailscaleUDP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "41641"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowOutboundAll"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vmss" {
  subnet_id                 = azurerm_subnet.vmss.id
  network_security_group_id = azurerm_network_security_group.vmss.id
}

# ---------------------------------------------------------------------------
# NAT Gateway (replaces per-instance public IPs for outbound SNAT)
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  name                = "${var.resource_prefix}-nat-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "${var.resource_prefix}-natgw"
  location                = azurerm_resource_group.this.location
  resource_group_name     = azurerm_resource_group.this.name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "vmss" {
  subnet_id      = azurerm_subnet.vmss.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# ---------------------------------------------------------------------------
# VMSS
# ---------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine_scale_set" "scraper" {
  name                = local.vmss_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = var.vm_sku
  instances           = var.instance_count

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(var.ssh_public_key_path)
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  os_disk {
    storage_account_type = "StandardSSD_LRS"
    caching              = "ReadWrite"
    disk_size_gb         = 64
  }

  network_interface {
    name    = "vmss-nic"
    primary = true

    ip_configuration {
      name      = "internal"
      primary   = true
      subnet_id = azurerm_subnet.vmss.id
    }
  }

  identity {
    type = "SystemAssigned"
  }

  priority        = var.use_spot ? "Spot" : "Regular"
  eviction_policy = var.use_spot ? "Delete" : null
  max_bid_price   = var.use_spot ? var.spot_max_price : null

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    tailscale_auth_key      = tailscale_tailnet_key.vmss.key
    k3s_version             = var.k3s_version
    k3s_url                 = "https://${var.k3s_master_tailscale_ip}:6443"
    k3s_token               = var.k3s_token
    k3s_node_labels         = "node-role=scraper"
    azure_tenant_id         = var.azure_tenant_id
    azure_subscription_id   = var.azure_subscription_id
    azure_resource_group    = azurerm_resource_group.this.name
    azure_location          = var.location
    azure_vmss_name         = local.vmss_name
  }))

  overprovision        = false
  single_placement_group = false
  upgrade_mode         = "Manual"

  tags = merge(var.tags, {
    role = "k3s-agent-scraper"
  })
}

# ---------------------------------------------------------------------------
# Cleanup: remove Tailscale devices and k3s nodes on VMSS destroy
# ---------------------------------------------------------------------------
resource "terraform_data" "vmss_cleanup" {
  triggers_replace = [
    azurerm_linux_virtual_machine_scale_set.scraper.id,
  ]

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Cleaning up offline Tailscale devices matching mf-scraper-..."
      tailscale status --json 2>/dev/null | python3 -c "
      import json, sys, urllib.request, os
      data = json.load(sys.stdin)
      api_key = os.environ.get('TF_VAR_tailscale_api_key', '')
      for pid, p in data.get('Peer', {}).items():
          name = p.get('HostName', '')
          nid = p.get('ID', '')
          if name.startswith('mf-scraper-') and nid:
              print(f'Removing Tailscale device: {name}')
              req = urllib.request.Request(f'https://api.tailscale.com/api/v2/device/{nid}', method='DELETE')
              req.add_header('Authorization', f'Bearer {api_key}')
              try: urllib.request.urlopen(req)
              except: pass
      " || true

      echo "Cleaning up k3s nodes matching mf-scraper-..."
      for node in $(kubectl get nodes -l node-role=scraper --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
        echo "Deleting k3s node: $node"
        kubectl delete node "$node" 2>/dev/null || true
      done
    EOT
  }
}

# ---------------------------------------------------------------------------
# RBAC: grant VMSS managed identity Contributor on the resource group
# (required for Azure Disk CSI driver to create/attach/detach managed disks)
# ---------------------------------------------------------------------------
resource "azurerm_role_assignment" "vmss_disk_contributor" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_linux_virtual_machine_scale_set.scraper.identity[0].principal_id
}
