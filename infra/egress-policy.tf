# Network egress control (preview) for the Copilot harness sandbox: a RAI policy whose
# egressPolicy denies direct outbound traffic (shell, curl, pip, the Web harness tool) unless a
# host is allow-listed. Foundry keeps the platform connectivity the harness itself needs.
# azapi because the 2026-05-15-preview egressPolicy shape is not in azurerm yet.
resource "azapi_resource" "egress_policy" {
  type                      = "Microsoft.CognitiveServices/accounts/raiPolicies@2026-05-15-preview"
  name                      = "egress-lockdown"
  parent_id                 = azurerm_cognitive_account.foundry.id
  schema_validation_enabled = false

  body = {
    properties = {
      mode           = "Blocking"
      basePolicyName = "Microsoft.DefaultV2"
      contentFilters = []
      egressPolicy = {
        mode          = var.egress_mode
        defaultAction = "Deny"
        rules = [
          for index, host in var.egress_allowed_hosts : {
            name     = "allow-${index + 1}"
            ruleType = "Fqdn"
            match    = { host = host }
            action   = { actionType = "Allow" }
          }
        ]
      }
    }
  }

  response_export_values = ["id"]

  depends_on = [azurerm_cognitive_deployment.model]
}
