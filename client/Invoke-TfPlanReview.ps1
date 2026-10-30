#requires -Version 7.4
<#
.SYNOPSIS
    Reviews a Terraform plan with the tfplan-reviewer agent (Microsoft Copilot harness in Foundry).

.DESCRIPTION
    1. Reads the JSON plan (terraform show -json tfplan > plan.json).
    2. Redacts it locally and saves the redacted copy in the output directory, so you can see exactly
       what leaves your machine.
    3. Uploads the redacted copy to Foundry Files and asks the agent to review it.
    4. Downloads the agent's report and parses the verdict.
    5. Deletes the uploaded plan, the generated report and the conversation from Foundry, unless you
       pass -KeepRemoteData.

.EXAMPLE
    terraform show -json tfplan > plan.json
    ./client/Invoke-TfPlanReview.ps1 -PlanPath ./plan.json

.EXAMPLE
    ./client/Invoke-TfPlanReview.ps1 -PlanPath ./plan.json -RequiredTags environment, owner, cost-centre
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanPath,
    [string] $ProjectEndpoint,
    [string] $AgentName = 'tfplan-reviewer',
    [string] $Model = 'gpt-5.4-mini',
    [string] $OutputDirectory = (Join-Path (Get-Location) 'outputs'),
    [string[]] $RequiredTags,
    [int] $TimeoutSeconds = 900,
    [switch] $KeepRemoteData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'TfPlanReview.psm1') -Force

if (-not $ProjectEndpoint) { $ProjectEndpoint = $env:FOUNDRY_PROJECT_ENDPOINT }
if (-not $ProjectEndpoint) {
    $ProjectEndpoint = terraform "-chdir=$(Join-Path $PSScriptRoot '..' 'infra')" output -raw FOUNDRY_PROJECT_ENDPOINT 2>$null
}
if (-not $ProjectEndpoint) {
    throw 'No Foundry project endpoint. Pass -ProjectEndpoint, set FOUNDRY_PROJECT_ENDPOINT, or deploy infra/ first.'
}

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($PlanPath)

$safePlan = Protect-TfPlanJson -Plan (ConvertFrom-TfPlanFile -Path $PlanPath)
$safePath = Join-Path $OutputDirectory "$baseName.redacted.json"
$safePlan | ConvertTo-Json -Depth 100 | Set-Content -Path $safePath -Encoding utf8NoBOM
Write-Host "Redacted $($safePlan.x_redaction.redacted_values) sensitive value(s) and dropped $($safePlan.x_redaction.dropped_sections.Count) plan section(s). Uploading $safePath"

$prompt = 'Review the attached Terraform plan with the tfplan-review skill.'
if ($RequiredTags) { $prompt += " Required tags: $($RequiredTags -join ',')." }

$uploadedFileId = Send-FoundryFile -ProjectEndpoint $ProjectEndpoint -Path $safePath
$conversationId = $null
$reportFiles = @()
try {
    $conversationId = New-AgentConversation -ProjectEndpoint $ProjectEndpoint -AgentName $AgentName
    $response = Invoke-AgentResponse -ProjectEndpoint $ProjectEndpoint -AgentName $AgentName -ConversationId $conversationId `
        -Prompt $prompt -FileId $uploadedFileId -Model $Model -TimeoutSeconds $TimeoutSeconds
    $response | ConvertTo-Json -Depth 50 | Set-Content -Path (Join-Path $OutputDirectory "$baseName.response.json") -Encoding utf8NoBOM

    $text = Get-AgentOutputText -Response $response
    $summary = ConvertFrom-ReviewSummary -Text $text

    $reportPath = $null
    $reportFiles = @(Get-AgentOutputFile -Response $response -ExcludeFileId $uploadedFileId)
    foreach ($file in $reportFiles) {
        # The agent chooses the name: keep only the leaf so it cannot write outside the output directory.
        $destination = Join-Path $OutputDirectory ([System.IO.Path]::GetFileName($file.Filename))
        Save-FoundryFile -ProjectEndpoint $ProjectEndpoint -FileId $file.FileId -Destination $destination
        if (-not $reportPath) { $reportPath = $destination }
    }
    if (-not $reportFiles) {
        Write-Warning "The agent returned no report file. On a fresh deployment the agent identity's Foundry User role can take up to 5 minutes to apply."
    }
}
finally {
    if (-not $KeepRemoteData) {
        foreach ($id in @($uploadedFileId) + @($reportFiles | ForEach-Object { $_.FileId })) {
            try { Remove-FoundryFile -ProjectEndpoint $ProjectEndpoint -FileId $id }
            catch { Write-Warning "Could not delete Foundry file ${id}: $($_.Exception.Message)" }
        }
        if ($conversationId) {
            try { Remove-AgentConversation -ProjectEndpoint $ProjectEndpoint -AgentName $AgentName -ConversationId $conversationId }
            catch { Write-Warning "Could not delete conversation ${conversationId}: $($_.Exception.Message)" }
        }
    }
}

$usage = $response['usage']
$findings = @($summary['findings'] | ForEach-Object { [pscustomobject]$_ })
Write-Host ''
Write-Host "Verdict: $($summary['verdict'])  ($($findings.Count) finding(s), $([math]::Round($stopwatch.Elapsed.TotalSeconds))s)"
$findings | ForEach-Object { Write-Host ("  {0,-8} {1}  {2}" -f $_.severity, $_.rule_id, $_.address) }
if ($reportPath) { Write-Host "Report: $reportPath" }

[pscustomobject]@{
    Verdict        = $summary['verdict']
    Counts         = [pscustomobject]$summary['counts']
    Findings       = $findings
    ReportPath     = $reportPath
    RedactedPlan   = $safePath
    RedactedValues = $safePlan.x_redaction.redacted_values
    ToolActivity   = @(Get-AgentToolActivity -Response $response)
    Text           = $text
    ResponseId     = $response['id']
    ConversationId = $conversationId
    UploadedFileId = $uploadedFileId
    InputTokens    = if ($usage) { $usage['input_tokens'] } else { $null }
    OutputTokens   = if ($usage) { $usage['output_tokens'] } else { $null }
    ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds)
}
