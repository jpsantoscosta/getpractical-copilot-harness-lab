# Offline unit tests: every provider is mocked, so nothing is created in Azure.
# Run from infra/:  terraform test

mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      object_id       = "11111111-1111-1111-1111-111111111111"
      tenant_id       = "22222222-2222-2222-2222-222222222222"
      subscription_id = "33333333-3333-3333-3333-333333333333"
    }
  }

  # azurerm validates resource ID formats, so mocked IDs must look real.
  mock_resource "azurerm_resource_group" {
    defaults = {
      id = "/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-tfreview-lab-uks-01"
    }
  }

  mock_resource "azurerm_cognitive_account" {
    defaults = {
      id = "/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-tfreview-lab-uks-01/providers/Microsoft.CognitiveServices/accounts/aif-tfreview-lab-uks-a1b2"
    }
  }

  mock_resource "azurerm_cognitive_account_project" {
    defaults = {
      id = "/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/rg-tfreview-lab-uks-01/providers/Microsoft.CognitiveServices/accounts/aif-tfreview-lab-uks-a1b2/projects/proj-tfreview-lab-uks-01"
    }
  }
}

mock_provider "azapi" {}

mock_provider "random" {
  mock_resource "random_string" {
    defaults = {
      result = "a1b2"
    }
  }
}

variables {
  subscription_id = "33333333-3333-3333-3333-333333333333"
}

run "foundry_account_is_entra_only_aiservices" {
  command = apply

  assert {
    condition     = azurerm_cognitive_account.foundry.kind == "AIServices"
    error_message = "The Foundry account must be kind AIServices."
  }

  assert {
    condition     = azurerm_cognitive_account.foundry.local_auth_enabled == false
    error_message = "Key-based auth must be disabled (Entra ID only)."
  }

  assert {
    condition     = azurerm_cognitive_account.foundry.project_management_enabled == true
    error_message = "Project management must be enabled so the account can host Foundry projects."
  }

  assert {
    condition     = azurerm_cognitive_account.foundry.custom_subdomain_name == azurerm_cognitive_account.foundry.name
    error_message = "The custom subdomain must match the account name."
  }
}

run "names_follow_caf_convention" {
  command = apply

  assert {
    condition     = azurerm_resource_group.lab.name == "rg-tfreview-lab-uks-01"
    error_message = "Unexpected resource group name: ${azurerm_resource_group.lab.name}"
  }

  assert {
    condition     = can(regex("^aif-tfreview-lab-uks-[a-z0-9]{4}$", azurerm_cognitive_account.foundry.name))
    error_message = "Unexpected Foundry account name: ${azurerm_cognitive_account.foundry.name}"
  }

  assert {
    condition     = azurerm_cognitive_account_project.lab.name == "proj-tfreview-lab-uks-01"
    error_message = "Unexpected project name: ${azurerm_cognitive_account_project.lab.name}"
  }

  assert {
    condition     = alltrue([for r in [azurerm_resource_group.lab.location, azurerm_cognitive_account.foundry.location, azurerm_cognitive_account_project.lab.location] : r == "uksouth"])
    error_message = "Everything must land in uksouth by default."
  }
}

run "model_is_gpt_5_4_mini_global_standard" {
  command = apply

  assert {
    condition     = azurerm_cognitive_deployment.model.name == "gpt-5.4-mini"
    error_message = "Deployment name must be gpt-5.4-mini."
  }

  assert {
    condition     = azurerm_cognitive_deployment.model.model[0].name == "gpt-5.4-mini" && azurerm_cognitive_deployment.model.model[0].version == "2026-03-17"
    error_message = "Model must be gpt-5.4-mini 2026-03-17."
  }

  assert {
    condition     = azurerm_cognitive_deployment.model.sku[0].name == "GlobalStandard" && azurerm_cognitive_deployment.model.sku[0].capacity == 100
    error_message = "Deployment must be GlobalStandard with capacity 100."
  }
}

run "deployer_gets_foundry_user_on_the_project" {
  command = apply

  assert {
    condition     = endswith(azurerm_role_assignment.deployer_foundry_user.role_definition_id, "/53ca6127-db72-4b80-b1b0-d745d6d5456d")
    error_message = "Deployer must get the Foundry User role (by GUID)."
  }

  assert {
    condition     = azurerm_role_assignment.deployer_foundry_user.scope == azurerm_cognitive_account_project.lab.id
    error_message = "Foundry User must be scoped to the project, not wider."
  }

  assert {
    condition     = azurerm_role_assignment.deployer_foundry_user.principal_id == "11111111-1111-1111-1111-111111111111"
    error_message = "Foundry User must be granted to the identity running Terraform."
  }
}

run "egress_is_deny_by_default" {
  command = apply

  assert {
    condition     = azapi_resource.egress_policy.body.properties.egressPolicy.defaultAction == "Deny"
    error_message = "Egress must default to Deny."
  }

  assert {
    condition     = azapi_resource.egress_policy.body.properties.egressPolicy.mode == "Enforced"
    error_message = "Egress must be Enforced by default."
  }

  assert {
    condition     = length(azapi_resource.egress_policy.body.properties.egressPolicy.rules) == 0
    error_message = "No allow rules by default."
  }
}

run "allowed_hosts_become_ordered_allow_rules" {
  command = apply

  variables {
    egress_allowed_hosts = ["pypi.org", "*.pythonhosted.org"]
  }

  assert {
    condition = azapi_resource.egress_policy.body.properties.egressPolicy.rules == [
      { name = "allow-1", ruleType = "Fqdn", match = { host = "pypi.org" }, action = { actionType = "Allow" } },
      { name = "allow-2", ruleType = "Fqdn", match = { host = "*.pythonhosted.org" }, action = { actionType = "Allow" } },
    ]
    error_message = "Allowed hosts must map to ordered Fqdn Allow rules."
  }
}

run "rejects_regions_without_the_harness" {
  command = plan

  variables {
    location = "northeurope"
  }

  expect_failures = [var.location]
}

run "outputs_feed_azd" {
  command = apply

  assert {
    condition     = output.FOUNDRY_PROJECT_ENDPOINT == "https://aif-tfreview-lab-uks-a1b2.services.ai.azure.com/api/projects/proj-tfreview-lab-uks-01"
    error_message = "Unexpected project endpoint: ${output.FOUNDRY_PROJECT_ENDPOINT}"
  }

  assert {
    condition     = output.MODEL_DEPLOYMENT_NAME == "gpt-5.4-mini" && output.AZURE_LOCATION == "uksouth" && output.AZURE_RESOURCE_GROUP == "rg-tfreview-lab-uks-01"
    error_message = "azd-facing outputs are wrong."
  }
}
