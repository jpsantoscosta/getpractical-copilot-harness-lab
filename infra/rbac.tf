# Foundry roles are mid-rename (Azure AI User -> Foundry User), so assign by role definition GUID.
locals {
  foundry_user_role_id = "53ca6127-db72-4b80-b1b0-d745d6d5456d"
}

# The identity running Terraform also runs azd and the client: it needs data-plane rights on the
# project to publish the skill, create the agent and invoke it. Subscription Owner is not enough -
# Owner has no data actions.
resource "azurerm_role_assignment" "deployer_foundry_user" {
  scope              = azurerm_cognitive_account_project.lab.id
  role_definition_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.foundry_user_role_id}"
  principal_id       = data.azurerm_client_config.current.object_id
  description        = "Lab deployer can publish skills, create agents and invoke them in this project."
}
