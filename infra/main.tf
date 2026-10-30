data "azurerm_client_config" "current" {}

locals {
  # CAF: <type>-<workload>-<environment>-<region>-<instance>
  workload    = "tfreview"
  environment = "lab"
  region_short = {
    australiaeast      = "aue"
    canadacentral      = "cac"
    centralus          = "cus"
    germanywestcentral = "gwc"
    japaneast          = "jpe"
    swedencentral      = "sdc"
    uksouth            = "uks"
    westeurope         = "weu"
    westus             = "wus"
  }[var.location]
  name_stem = "${local.workload}-${local.environment}-${local.region_short}"

  tags = {
    workload    = local.workload
    environment = local.environment
    owner       = var.owner
    managed-by  = "terraform"
    source      = "getpractical.co.uk"
  }
}

# Foundry account names double as the Entra custom subdomain, so they must be globally unique.
resource "random_string" "suffix" {
  length  = 4
  upper   = false
  special = false
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-${local.name_stem}-01"
  location = var.location
  tags     = local.tags
}

resource "azurerm_cognitive_account" "foundry" {
  name                       = "aif-${local.name_stem}-${random_string.suffix.result}"
  location                   = azurerm_resource_group.lab.location
  resource_group_name        = azurerm_resource_group.lab.name
  kind                       = "AIServices"
  sku_name                   = "S0"
  custom_subdomain_name      = "aif-${local.name_stem}-${random_string.suffix.result}"
  project_management_enabled = true
  local_auth_enabled         = false
  tags                       = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_cognitive_account_project" "lab" {
  name                 = "proj-${local.name_stem}-01"
  cognitive_account_id = azurerm_cognitive_account.foundry.id
  location             = azurerm_resource_group.lab.location
  display_name         = "Terraform plan reviewer lab"
  description          = "Microsoft Copilot harness lab - reviews Terraform plans for risky Azure changes."
  tags                 = local.tags

  identity {
    type = "SystemAssigned"
  }
}

# The account rejects concurrent child operations, so the deployment waits for the project.
resource "azurerm_cognitive_deployment" "model" {
  name                 = "gpt-5.4-mini"
  cognitive_account_id = azurerm_cognitive_account.foundry.id

  model {
    format  = "OpenAI"
    name    = "gpt-5.4-mini"
    version = "2026-03-17"
  }

  sku {
    name     = "GlobalStandard"
    capacity = var.model_capacity
  }

  depends_on = [azurerm_cognitive_account_project.lab]
}
