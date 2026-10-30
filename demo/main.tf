# A tiny workload to produce real Terraform plans for the reviewer.
#   terraform apply                                  # baseline: private, tagged, locked
#   terraform plan -var scenario=risky -out tfplan   # the bad change - never apply it
#   terraform show -json tfplan > plan.json

data "azurerm_client_config" "current" {}

locals {
  risky     = var.scenario == "risky"
  name_stem = "tfreviewdemo-lab-uks"

  tags = {
    workload    = "tfreviewdemo"
    environment = "lab"
    owner       = var.owner
    managed-by  = "terraform"
  }
}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "demo" {
  name     = "rg-${local.name_stem}-01"
  location = var.location
  # Risky: an extra tag. Harmless on its own, it shows up as an ordinary update.
  tags = local.risky ? merge(local.tags, { reviewed = "false" }) : local.tags
}

resource "azurerm_network_security_group" "demo" {
  name                = "nsg-${local.name_stem}-01"
  location            = azurerm_resource_group.demo.location
  resource_group_name = azurerm_resource_group.demo.name
  tags                = local.tags
}

resource "azurerm_network_security_rule" "allow_https_from_vnet" {
  name                        = "allow-https-from-vnet"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "443"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.demo.name
  network_security_group_name = azurerm_network_security_group.demo.name
}

# Risky: "temporary" RDP from anywhere for troubleshooting.
resource "azurerm_network_security_rule" "allow_rdp" {
  count = local.risky ? 1 : 0

  name                        = "allow-rdp-temp"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = "Internet"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.demo.name
  network_security_group_name = azurerm_network_security_group.demo.name
}

resource "azurerm_storage_account" "demo" {
  # Risky: a "tidy-up" rename. Storage account names cannot change in place, so Azure destroys
  # the account (and its data) and creates a new one.
  name                     = local.risky ? "sttfrdemo${random_string.suffix.result}v2" : "sttfrdemo${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.demo.name
  location                 = azurerm_resource_group.demo.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  # Risky: opened to the internet with anonymous blob access, and the owner tag dropped.
  public_network_access_enabled   = local.risky
  allow_nested_items_to_be_public = local.risky
  tags                            = local.risky ? { workload = "tfreviewdemo", environment = "lab" } : local.tags
}

# Risky: the delete lock goes, "just for this change".
resource "azurerm_management_lock" "storage" {
  count = local.risky ? 0 : 1

  name       = "lock-${local.name_stem}-storage"
  scope      = azurerm_storage_account.demo.id
  lock_level = "CanNotDelete"
  notes      = "Protects the demo storage account from deletion."
}

# Risky: a "quick fix" that grants Owner on the resource group.
resource "azurerm_role_assignment" "owner" {
  count = local.risky ? 1 : 0

  scope                = azurerm_resource_group.demo.id
  role_definition_name = "Owner"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Puts a sensitive value in the plan without creating anything in Azure.
resource "terraform_data" "app_settings" {
  input = {
    api_key = var.demo_api_key
    region  = var.location
  }
}

output "storage_connection_string" {
  value     = azurerm_storage_account.demo.primary_connection_string
  sensitive = true
}
