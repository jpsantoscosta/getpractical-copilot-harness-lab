# Upper-case names on purpose: scripts/Sync-AzdEnv.ps1 copies them 1:1 into the azd environment.

output "FOUNDRY_PROJECT_ENDPOINT" {
  description = "Foundry project endpoint used by azd and the PowerShell client."
  value       = "https://${azurerm_cognitive_account.foundry.custom_subdomain_name}.services.ai.azure.com/api/projects/${azurerm_cognitive_account_project.lab.name}"
}

output "AZURE_AI_PROJECT_ID" {
  description = "Project resource ID (scope for the agent identity's role assignment)."
  value       = azurerm_cognitive_account_project.lab.id
}

output "MODEL_DEPLOYMENT_NAME" {
  value = azurerm_cognitive_deployment.model.name
}

output "RAI_POLICY_ID" {
  description = "Egress guardrail attached to the agent in azure.yaml."
  value       = azapi_resource.egress_policy.id
}

output "FOUNDRY_ACCOUNT_NAME" {
  value = azurerm_cognitive_account.foundry.name
}

output "AZURE_RESOURCE_GROUP" {
  value = azurerm_resource_group.lab.name
}

output "AZURE_LOCATION" {
  value = azurerm_resource_group.lab.location
}

output "AZURE_SUBSCRIPTION_ID" {
  value = var.subscription_id
}
