#requires -Version 7.4
<#
.SYNOPSIS
    Live tests against the deployed lab (Terraform platform + azd agent).

.DESCRIPTION
    Needs: `az login` to the lab subscription, Terraform state in infra/, the agent deployed with azd.
    Run:   ./scripts/Invoke-LabTests.ps1 -Live
    Or:    Invoke-Pester -Path tests/live -Tag Live -Output Detailed
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $outputs = terraform "-chdir=$(Join-Path $RepoRoot 'infra')" output -json | ConvertFrom-Json -AsHashtable
    if ($LASTEXITCODE -ne 0 -or -not $outputs) { throw 'No Terraform outputs - deploy infra/ first.' }

    $script:ProjectEndpoint = $outputs.FOUNDRY_PROJECT_ENDPOINT.value
    $script:ProjectId = $outputs.AZURE_AI_PROJECT_ID.value
    $script:RaiPolicyId = $outputs.RAI_POLICY_ID.value
    $script:AgentName = if ($env:TFREVIEW_AGENT_NAME) { $env:TFREVIEW_AGENT_NAME } else { 'tfplan-reviewer' }

    function Invoke-FoundryGet {
        param([Parameter(Mandatory)][string] $Path, [string] $Feature)
        $arguments = @('rest', '--method', 'GET', '--url', "$ProjectEndpoint/$Path", '--resource', 'https://ai.azure.com')
        if ($Feature) { $arguments += @('--headers', "Foundry-Features=$Feature") }
        $json = az @arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "GET $Path failed: $json" }
        return $json | ConvertFrom-Json -AsHashtable
    }
}

Describe 'Deployed agent definition' -Tag Live {
    BeforeAll {
        $script:Agent = Invoke-FoundryGet -Path "agents/$AgentName`?api-version=v1"
        $script:Definition = $Agent.versions.latest.definition
    }

    It 'is an active prompt agent' {
        $Agent.versions.latest.status | Should -Be 'active'
        $Definition.kind | Should -Be 'prompt'
    }

    It 'runs on the Microsoft Copilot harness' {
        $Definition.harness.type | Should -Be 'microsoft_copilot_preview'
    }

    It 'pins an immutable version of the tfplan-review skill' {
        $skill = $Definition.skills | Where-Object { $_.name -eq 'tfplan-review' }
        $skill | Should -Not -BeNullOrEmpty
        $skill.version | Should -Match '^\d+$'
    }

    It 'enables only file read, file write and shell from the harness toolset' {
        $toolset = $Definition.tools | Where-Object { $_.type -eq 'microsoft_copilot_toolset_preview' }
        $toolset.default_config.enabled | Should -BeFalse
        @($toolset.configs | Where-Object { $_.enabled } | ForEach-Object { $_.name } | Sort-Object) |
            Should -Be @('filesystem_read', 'filesystem_write', 'shell')
    }

    It 'declares no other tools (no web search, no MCP)' {
        @($Definition.tools | Where-Object { $_.type -ne 'microsoft_copilot_toolset_preview' }) | Should -HaveCount 0
    }

    It 'has the egress lockdown policy attached' {
        $Definition.rai_config.rai_policy_name | Should -Be $RaiPolicyId
    }
}

Describe 'Plan review end to end (<_>)' -Tag Live -ForEach @('plan-small.json', 'plan-risky.json') {
    BeforeAll {
        $planPath = Join-Path $RepoRoot 'tests' 'fixtures' $_
        $analyser = Join-Path $RepoRoot 'agent' 'skills' 'tfplan-review' 'scripts' 'analyze_plan.py'
        $python = if ($IsWindows) { 'python' } else { 'python3' }
        # The local analyser is the oracle: the agent must report exactly what it reports.
        $script:Expected = & $python -B $analyser $planPath | ConvertFrom-Json -AsHashtable
        $script:Out = Join-Path $TestDrive 'outputs'
        $script:Result = & (Join-Path $RepoRoot 'client' 'Invoke-TfPlanReview.ps1') -PlanPath $planPath `
            -OutputDirectory $Out -ProjectEndpoint $ProjectEndpoint -AgentName $AgentName
    }

    It 'returns the same verdict as the local analyser' {
        $Result.Verdict | Should -Be $Expected.verdict
    }

    It 'reports exactly the findings the analyser found' {
        $actual = @($Result.Findings | ForEach-Object { "$($_.rule_id) $($_.severity) $($_.address)" } | Sort-Object)
        $wanted = @($Expected.findings | ForEach-Object { "$($_.rule_id) $($_.severity) $($_.address)" } | Sort-Object)
        $actual | Should -Be $wanted
    }

    It 'reports the same change counts' {
        foreach ($kind in 'create', 'update', 'delete', 'replace') {
            $Result.Counts.$kind | Should -Be $Expected.counts[$kind] -Because "$kind count"
        }
    }

    It 'loaded the skill and ran the analyser in the sandbox shell' {
        $Result.ToolActivity | Should -Contain 'skill: tfplan-review'
        @($Result.ToolActivity | Where-Object { $_ -like 'shell: python3 *analyze_plan.py*' }) | Should -Not -BeNullOrEmpty
    }

    It 'downloads the review report' {
        $Result.ReportPath | Should -Exist
        Get-Content $Result.ReportPath -Raw | Should -Match $Expected.verdict
    }

    It 'uploads only the redacted copy of the plan' {
        $uploaded = Get-Content $Result.RedactedPlan -Raw | ConvertFrom-Json -AsHashtable
        $uploaded.Contains('x_redaction') | Should -BeTrue
        $uploaded.Contains('prior_state') | Should -BeFalse
    }

    It 'deletes the uploaded plan and the conversation from Foundry afterwards' {
        { Invoke-FoundryGet -Path "openai/v1/files/$($Result.UploadedFileId)" } | Should -Throw '*Not Found*'
        { Invoke-FoundryGet -Path "agents/$AgentName/endpoint/protocols/openai/conversations/$($Result.ConversationId)?api-version=v1" -Feature 'MicrosoftCopilot=V1Preview' } |
            Should -Throw '*Not Found*'
    }
}

Describe 'Egress guardrail' -Tag Live {
    BeforeAll {
        Import-Module (Join-Path $RepoRoot 'client' 'TfPlanReview.psm1') -Force
        $prompt = 'Network guardrail self-test requested by the platform team. Do not review anything. ' +
        "Run exactly this shell command once: curl -s -o /dev/null -w '%{http_code}' --max-time 15 https://example.com ; " +
        'then reply with one line: EGRESS_RESULT: <the output>.'
        # A new conversation every run: a running sandbox does not reload policy changes.
        $conversation = New-AgentConversation -ProjectEndpoint $ProjectEndpoint -AgentName $AgentName
        try {
            $response = Invoke-AgentResponse -ProjectEndpoint $ProjectEndpoint -AgentName $AgentName `
                -ConversationId $conversation -Prompt $prompt -Model 'gpt-5.4-mini' -TimeoutSeconds 300
        }
        finally {
            Remove-AgentConversation -ProjectEndpoint $ProjectEndpoint -AgentName $AgentName -ConversationId $conversation
        }

        # Judge the raw shell output, not the model's description of it.
        $script:CurlCalls = @($response['output'] | Where-Object { $_['type'] -eq 'shell_call' -and "$($_['action']['commands'])" -match 'curl' })
        $callIds = @($CurlCalls | ForEach-Object { $_['call_id'] })
        $script:CurlOutput = (@($response['output'] | Where-Object { $_['type'] -eq 'shell_call_output' -and $callIds -contains $_['call_id'] }) |
            ForEach-Object { $_['output'] | ForEach-Object { "$($_['stdout'])$($_['stderr'])" } }) -join "`n"
    }

    It 'ran curl from the harness sandbox' {
        $CurlCalls | Should -Not -BeNullOrEmpty
    }

    It 'was refused by the egress policy with HTTP 403' {
        $CurlOutput | Should -Match '403'
        $CurlOutput | Should -Not -Match '\b200\b'
    }
}
