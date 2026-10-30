#requires -Version 7.4
<#
.SYNOPSIS
    Copies the Terraform platform outputs into the azd environment used by agent/.

.DESCRIPTION
    Terraform owns the platform (infra/), azd owns the agent layer (agent/). This script is the
    hand-off: every upper-case Terraform output becomes an azd environment value of the same name,
    so azure.yaml can reference ${FOUNDRY_PROJECT_ENDPOINT}, ${MODEL_DEPLOYMENT_NAME} and
    ${RAI_POLICY_ID}. Safe to re-run.

.EXAMPLE
    ./scripts/Sync-AzdEnv.ps1
#>
[CmdletBinding()]
param(
    [string] $InfraPath = (Join-Path $PSScriptRoot '..' 'infra'),
    [string] $AgentPath = (Join-Path $PSScriptRoot '..' 'agent'),
    [string] $EnvironmentName = 'tfreview-lab'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$outputs = terraform "-chdir=$InfraPath" output -json | ConvertFrom-Json -AsHashtable
if ($LASTEXITCODE -ne 0 -or -not $outputs -or $outputs.Count -eq 0) {
    throw "No Terraform outputs found in $InfraPath. Run 'terraform apply' there first."
}

Push-Location $AgentPath
try {
    $existing = @(azd env list --output json | ConvertFrom-Json) | Where-Object { $_.Name -eq $EnvironmentName }
    if (-not $existing) {
        azd env new $EnvironmentName --subscription $outputs.AZURE_SUBSCRIPTION_ID.value --location $outputs.AZURE_LOCATION.value --no-prompt
    }
    else {
        azd env select $EnvironmentName
    }
    if ($LASTEXITCODE -ne 0) { throw "Could not create or select azd environment $EnvironmentName." }

    foreach ($name in ($outputs.Keys | Sort-Object)) {
        azd env set $name ([string]$outputs[$name].value) --environment $EnvironmentName
        if ($LASTEXITCODE -ne 0) { throw "azd env set $name failed." }
        Write-Host "  $name"
    }
    Write-Host "azd environment '$EnvironmentName' now mirrors the Terraform outputs."
}
finally {
    Pop-Location
}
