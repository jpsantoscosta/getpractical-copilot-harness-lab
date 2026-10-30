#requires -Version 7.4
<#
.SYNOPSIS
    azd postdeploy hook: grants the agent's own identity Foundry User on the project.

.DESCRIPTION
    The Copilot harness uploads generated files (our review report) to Foundry Files as the agent
    identity, and that identity needs Foundry User at project scope. The identity only exists once
    azd has created the agent, so Terraform cannot grant it - this hook runs after every deploy.
    Idempotent. Role assignments can take up to five minutes to propagate.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Foundry roles are mid-rename (Azure AI User -> Foundry User): use the role definition GUID.
$foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

function Get-AzdValue {
    param([Parameter(Mandatory)][string] $Name, [string] $Default)

    # azd exports the environment's values to hooks; fall back to asking azd directly.
    $value = [Environment]::GetEnvironmentVariable($Name)
    if (-not $value) {
        $value = (azd env get-value $Name 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { $value = $null }
    }
    if (-not $value) { $value = $Default }
    if (-not $value) { throw "azd environment value $Name is not set. Run scripts/Sync-AzdEnv.ps1 first." }
    return $value
}

$projectEndpoint = Get-AzdValue -Name FOUNDRY_PROJECT_ENDPOINT
$projectId = Get-AzdValue -Name AZURE_AI_PROJECT_ID
$agentName = Get-AzdValue -Name AGENT_TFPLAN_REVIEWER_NAME -Default 'tfplan-reviewer'

$principalId = (az rest --method GET --url "$projectEndpoint/agents/$agentName`?api-version=v1" `
        --resource 'https://ai.azure.com' --query 'instance_identity.principal_id' --output tsv | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or -not $principalId) {
    throw "Could not read instance_identity.principal_id for agent '$agentName'."
}

# No parentheses in --query: on Windows az is a .cmd file and cmd.exe chokes on 'length(@)'.
$assignments = az role assignment list --assignee $principalId --role $foundryUserRoleId `
    --scope $projectId --fill-principal-name false --query '[].id' --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not list role assignments for the agent identity.' }

if (@($assignments).Count -eq 0) {
    az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
        --role $foundryUserRoleId --scope $projectId `
        --description 'Agent identity uploads generated review reports to Foundry Files.' --output none
    if ($LASTEXITCODE -ne 0) { throw 'Failed to assign Foundry User to the agent identity.' }
    Write-Host "Assigned Foundry User to agent identity $principalId. Allow up to 5 minutes to propagate."
}
else {
    Write-Host "Agent identity $principalId already has Foundry User on the project."
}
