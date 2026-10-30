#requires -Version 7.4
<#
    Offline unit tests for client/TfPlanReview.psm1. No Azure calls: the REST tests mock
    Invoke-WebRequest and the token helper.
    Run: Invoke-Pester -Path tests/unit -Output Detailed
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module (Join-Path $RepoRoot 'client' 'TfPlanReview.psm1') -Force
    $script:Fixtures = Join-Path $RepoRoot 'tests' 'fixtures'

    # Shaped like `terraform show -json` output, with secrets in all the usual places.
    $script:PlanJson = @'
{
  "format_version": "1.2",
  "terraform_version": "1.14.9",
  "timestamp": "2026-10-30T17:00:00Z",
  "applyable": true,
  "complete": true,
  "errored": false,
  "variables": {
    "admin_password": { "value": "VAR-SECRET" },
    "location": { "value": "uksouth" }
  },
  "resource_changes": [
    {
      "address": "azurerm_storage_account.sa", "mode": "managed", "type": "azurerm_storage_account", "name": "sa",
      "change": {
        "actions": ["update"],
        "before": { "name": "stdemo", "primary_access_key": "KEY-BEFORE", "primary_connection_string": "CS-BEFORE",
                    "public_network_access_enabled": false, "network_rules": [{ "ip_rules": ["1.2.3.4"] }],
                    "tags": { "environment": "lab", "owner": "joao" } },
        "after": { "name": "stdemo", "primary_access_key": "KEY-AFTER", "primary_connection_string": "CS-AFTER",
                   "public_network_access_enabled": false, "network_rules": [{ "ip_rules": ["1.2.3.4"] }],
                   "tags": { "environment": "lab", "owner": "joao" } },
        "after_unknown": {},
        "before_sensitive": { "primary_access_key": true, "primary_connection_string": true },
        "after_sensitive": { "primary_access_key": true, "primary_connection_string": true }
      }
    },
    {
      "address": "azurerm_linux_web_app.app", "mode": "managed", "type": "azurerm_linux_web_app", "name": "app",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": { "name": "app-demo", "app_settings": { "API_TOKEN": "APP-SETTING-SECRET", "MODE": "prod" },
                   "connection_string": [{ "name": "db", "type": "SQLAzure", "value": "CONN-VALUE" }] },
        "after_unknown": { "id": true },
        "before_sensitive": false,
        "after_sensitive": { "app_settings": true, "connection_string": [{ "value": true }] }
      }
    },
    {
      "address": "azurerm_key_vault_secret.db", "mode": "managed", "type": "azurerm_key_vault_secret", "name": "db",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": { "name": "db-password", "value": "KV-SECRET-VALUE",
                   "key_vault_id": "/subscriptions/0000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv" },
        "after_unknown": { "id": true },
        "before_sensitive": false,
        "after_sensitive": { "value": true }
      }
    },
    {
      "address": "azurerm_mssql_server.sql", "mode": "managed", "type": "azurerm_mssql_server", "name": "sql",
      "change": {
        "actions": ["create"],
        "before": null,
        "after": { "name": "sql-demo", "administrator_login": "sqladmin", "administrator_login_password": "UNFLAGGED-PASSWORD" },
        "after_unknown": {},
        "before_sensitive": false,
        "after_sensitive": {}
      }
    }
  ],
  "resource_drift": [
    {
      "address": "azurerm_storage_account.sa", "mode": "managed", "type": "azurerm_storage_account", "name": "sa",
      "change": {
        "actions": ["update"],
        "before": { "primary_access_key": "DRIFT-KEY" },
        "after": { "primary_access_key": "DRIFT-KEY" },
        "before_sensitive": { "primary_access_key": true },
        "after_sensitive": { "primary_access_key": true }
      }
    }
  ],
  "output_changes": {
    "db_password": { "actions": ["create"], "before": null, "after": "OUTPUT-SECRET", "after_unknown": false,
                     "before_sensitive": false, "after_sensitive": true },
    "endpoint": { "actions": ["create"], "before": null, "after": "https://app-demo.azurewebsites.net", "after_unknown": false,
                  "before_sensitive": false, "after_sensitive": false }
  },
  "prior_state": { "values": { "root_module": { "resources": [{ "values": { "primary_access_key": "KEY-BEFORE" } }] } } },
  "planned_values": { "root_module": { "resources": [{ "values": { "primary_access_key": "KEY-AFTER" } }] } },
  "configuration": { "root_module": { "variables": { "admin_password": { "sensitive": true }, "location": { "default": "uksouth" } } } },
  "relevant_attributes": [{ "resource": "azurerm_storage_account.sa", "attribute": ["primary_access_key"] }],
  "checks": []
}
'@
    $script:Secrets = 'KEY-BEFORE', 'KEY-AFTER', 'CS-BEFORE', 'CS-AFTER', 'APP-SETTING-SECRET', 'CONN-VALUE',
    'KV-SECRET-VALUE', 'UNFLAGGED-PASSWORD', 'OUTPUT-SECRET', 'VAR-SECRET', 'DRIFT-KEY'

    function New-TestPlan { $PlanJson | ConvertFrom-Json -AsHashtable }

    function New-HttpResponse([int] $StatusCode, [object] $Body) {
        [pscustomobject]@{ StatusCode = $StatusCode; Content = ($Body | ConvertTo-Json -Depth 20 -Compress) }
    }
}

Describe 'ConvertFrom-TfPlanFile' {
    It 'reads a plan into an ordered dictionary' {
        $path = Join-Path $TestDrive 'plan.json'
        Set-Content -Path $path -Value $PlanJson -Encoding utf8NoBOM
        $plan = ConvertFrom-TfPlanFile -Path $path
        $plan | Should -BeOfType [System.Collections.IDictionary]
        @($plan.Keys)[0..2] | Should -Be @('format_version', 'terraform_version', 'timestamp') -Because 'key order is kept'
        $plan.resource_changes | Should -HaveCount 4
    }

    It 'keeps timestamps as strings' -Skip:(-not (Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $path = Join-Path $TestDrive 'plan.json'
        Set-Content -Path $path -Value $PlanJson -Encoding utf8NoBOM
        (ConvertFrom-TfPlanFile -Path $path).timestamp | Should -BeExactly '2026-10-30T17:00:00Z'
    }

    It 'reads UTF-16 files written by Windows PowerShell 5.1 redirection' {
        $path = Join-Path $TestDrive 'plan-utf16.json'
        Set-Content -Path $path -Value $PlanJson -Encoding Unicode
        (ConvertFrom-TfPlanFile -Path $path).terraform_version | Should -Be '1.14.9'
    }

    It 'rejects JSON that is not a Terraform plan' {
        $path = Join-Path $TestDrive 'not-a-plan.json'
        Set-Content -Path $path -Value '{"hello": 1}'
        { ConvertFrom-TfPlanFile -Path $path } | Should -Throw '*is not a Terraform JSON plan*'
    }

    It 'rejects text that is not JSON at all' {
        $path = Join-Path $TestDrive 'plan.txt'
        Set-Content -Path $path -Value 'Plan: 1 to add, 0 to change, 0 to destroy.'
        { ConvertFrom-TfPlanFile -Path $path } | Should -Throw '*is not a Terraform JSON plan*'
    }
}

Describe 'Protect-TfPlanJson' {
    BeforeAll {
        $script:Plan = New-TestPlan
        $script:Safe = Protect-TfPlanJson -Plan $Plan
    }

    It 'removes every secret value from the copy that gets uploaded' {
        $json = $Safe | ConvertTo-Json -Depth 100
        foreach ($secret in $Secrets) { $json | Should -Not -Match ([regex]::Escape($secret)) -Because "$secret must not leave the machine" }
    }

    It 'redacts values flagged by before_sensitive and after_sensitive' {
        $change = $Safe.resource_changes[0].change
        $change.before.primary_access_key | Should -Be '(redacted)'
        $change.after.primary_connection_string | Should -Be '(redacted)'
    }

    It 'follows sensitivity markers into lists of blocks' {
        $block = $Safe.resource_changes[1].change.after.connection_string[0]
        $block.value | Should -Be '(redacted)'
        $block.name | Should -Be 'db'
        $block.type | Should -Be 'SQLAzure'
    }

    It 'redacts a whole map when its marker is true' {
        $Safe.resource_changes[1].change.after.app_settings | Should -Be '(redacted)'
    }

    It 'redacts sensitive outputs and keeps the others' {
        $Safe.output_changes.db_password.after | Should -Be '(redacted)'
        $Safe.output_changes.endpoint.after | Should -Be 'https://app-demo.azurewebsites.net'
    }

    It 'redacts variables declared sensitive in the configuration' {
        $Safe.variables.admin_password.value | Should -Be '(redacted)'
        $Safe.variables.location.value | Should -Be 'uksouth'
    }

    It 'catches secret-named attributes the provider did not flag' {
        $after = $Safe.resource_changes[3].change.after
        $after.administrator_login_password | Should -Be '(redacted)'
        $after.administrator_login | Should -Be 'sqladmin'
    }

    It 'catches camelCase secret names, as used in azapi request bodies' {
        $body = @{ properties = @{
                administratorLoginPassword = 'CAMEL-PASSWORD-1'; clientSecret = 'CAMEL-SECRET-2'; connectionString = 'CAMEL-CONN-3'
                storageAccessKey = 'CAMEL-KEY-4'; SASToken = 'CAMEL-SAS-5'
                keyVaultId = '/subscriptions/0000/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv'; publicNetworkAccess = 'Enabled'
            }
        }
        $plan = @{ format_version = '1.2'; resource_changes = @(@{ address = 'azapi_resource.sql'; type = 'azapi_resource'; change = @{
                    actions = @('create'); before = $null; after = @{ body = $body }; before_sensitive = $false; after_sensitive = @{} } })
        }
        $json = Protect-TfPlanJson -Plan $plan | ConvertTo-Json -Depth 20
        $json | Should -Not -Match 'CAMEL-'
        $json | Should -Match '/vaults/kv' -Because 'keyVaultId is not a secret'
        $json | Should -Match '"publicNetworkAccess": "Enabled"'
    }

    It 'keeps the values the analyser needs' {
        $Safe.resource_changes[0].change.after.public_network_access_enabled | Should -BeFalse
        $Safe.resource_changes[0].change.after.network_rules[0].ip_rules | Should -Be @('1.2.3.4')
        $Safe.resource_changes[0].change.after.tags.owner | Should -Be 'joao'
        $Safe.resource_changes[2].change.after.key_vault_id | Should -BeLike '*/vaults/kv'
        $Safe.resource_changes[0].change.actions | Should -Be @('update')
    }

    It 'drops state, planned values and configuration' {
        foreach ($section in 'prior_state', 'planned_values', 'configuration', 'relevant_attributes', 'checks') {
            $Safe.Contains($section) | Should -BeFalse -Because "$section is not needed for a review"
        }
        $Safe.x_redaction.dropped_sections | Should -Be @('checks', 'configuration', 'planned_values', 'prior_state', 'relevant_attributes')
    }

    It 'keeps the plan metadata' {
        $Safe.format_version | Should -Be '1.2'
        $Safe.terraform_version | Should -Be '1.14.9'
        $Safe.resource_drift | Should -HaveCount 1
    }

    It 'counts every value it redacted' {
        $Safe.x_redaction.redacted_values | Should -Be 12
    }

    It 'redacts copies of a secret that Terraform did not mark (terraform_data output)' {
        # Real Terraform behaviour: terraform_data marks input.api_key but not output.api_key.
        $values = @{ input = @{ api_key = 'COPIED-SECRET-123' }; output = @{ api_key = 'COPIED-SECRET-123' } }
        $markers = @{ input = @{ api_key = $true }; output = @{} }
        $plan = @{ format_version = '1.2'; resource_changes = @(@{ address = 'terraform_data.app'; type = 'terraform_data'; change = @{
                    actions = @('no-op'); before = $values; after = $values; before_sensitive = $markers; after_sensitive = $markers } })
        }
        Protect-TfPlanJson -Plan $plan | ConvertTo-Json -Depth 20 | Should -Not -Match 'COPIED-SECRET-123'
    }

    It 'redacts strings that embed a known secret' {
        $plan = @{ format_version = '1.2'; resource_changes = @(@{ address = 'azurerm_linux_web_app.app'; type = 'azurerm_linux_web_app'; change = @{
                    actions = @('create'); before = $null
                    after = @{ storage_key = 'EMBEDDED-SECRET-99'; app_settings_note = 'DefaultEndpointsProtocol=https;AccountKey=EMBEDDED-SECRET-99;' }
                    before_sensitive = $false; after_sensitive = @{ storage_key = $true } } })
        }
        Protect-TfPlanJson -Plan $plan | ConvertTo-Json -Depth 20 | Should -Not -Match 'EMBEDDED-SECRET-99'
    }

    It 'does not spread short values from a sensitive map to unrelated attributes' {
        $plan = @{ format_version = '1.2'; resource_changes = @(@{ address = 'azurerm_linux_web_app.app'; type = 'azurerm_linux_web_app'; change = @{
                    actions = @('create'); before = $null
                    after = @{ app_settings = @{ MODE = 'prod' }; tags = @{ environment = 'prod' } }
                    before_sensitive = $false; after_sensitive = @{ app_settings = $true } } })
        }
        (Protect-TfPlanJson -Plan $plan).resource_changes[0].change.after.tags.environment | Should -Be 'prod'
    }

    It 'redacts every sensitive value in a real azurerm plan' {
        $real = ConvertFrom-TfPlanFile -Path (Join-Path $Fixtures 'plan-risky.json')
        ($real | ConvertTo-Json -Depth 100) | Should -Match 'FAKE-STORAGE-KEY' -Because 'the fixture carries stand-in secrets'
        $json = Protect-TfPlanJson -Plan $real | ConvertTo-Json -Depth 100
        $json | Should -Not -Match 'FAKE-STORAGE-KEY|FAKE-SENSITIVE-VALUE'
        $json | Should -Match '"public_network_access_enabled": true' -Because 'the reviewer still needs the risky settings'
    }

    It 'does not change the plan it was given' {
        $before = $Plan | ConvertTo-Json -Depth 100
        $null = Protect-TfPlanJson -Plan $Plan
        ($Plan | ConvertTo-Json -Depth 100) | Should -BeExactly $before
        $Plan.resource_changes[0].change.after.primary_access_key | Should -Be 'KEY-AFTER'
    }
}

Describe 'ConvertFrom-ReviewSummary' {
    BeforeAll {
        $script:Block = '```tfplan-review-summary' + "`n" +
        '{"verdict": "BLOCK", "counts": {"create": 1, "delete": 1}, "findings": [{"rule_id": "TFR004", "severity": "critical", "address": "azurerm_network_security_rule.rdp"}]}' +
        "`n" + '```'
    }

    It 'parses the closing summary block' {
        $summary = ConvertFrom-ReviewSummary -Text "Some review text.`n`n$Block`n"
        $summary.verdict | Should -Be 'BLOCK'
        $summary.counts.create | Should -Be 1
        $summary.findings[0].rule_id | Should -Be 'TFR004'
    }

    It 'uses the last block when the reply contains more than one' {
        $early = $Block -replace 'BLOCK', 'PASS'
        (ConvertFrom-ReviewSummary -Text "$early`nmore text`n$Block").verdict | Should -Be 'BLOCK'
    }

    It 'fails clearly when the block is missing' {
        { ConvertFrom-ReviewSummary -Text 'Looks fine to me.' } | Should -Throw '*no tfplan-review-summary block*'
    }

    It 'fails clearly when the block is not JSON' {
        { ConvertFrom-ReviewSummary -Text ('```tfplan-review-summary' + "`nverdict: BLOCK`n" + '```') } | Should -Throw '*not valid JSON*'
    }

    It 'fails clearly when a required field is missing' {
        { ConvertFrom-ReviewSummary -Text ('```tfplan-review-summary' + "`n" + '{"verdict": "PASS"}' + "`n" + '```') } |
            Should -Throw "*missing 'counts'*"
    }
}

Describe 'Response parsing (recorded harness response)' {
    BeforeAll {
        $script:Response = Get-Content (Join-Path $Fixtures 'response-review.json') -Raw | ConvertFrom-Json -AsHashtable
    }

    It 'joins the assistant messages into one text' {
        $text = Get-AgentOutputText -Response $Response
        $text | Should -Match 'tfplan-review-summary'
        $text | Should -Match 'BLOCK'
        $text | Should -Match 'The agent generated the following files'
    }

    It 'returns the cited report file' {
        $files = @(Get-AgentOutputFile -Response $Response)
        $files | Should -HaveCount 1
        $files[0].FileId | Should -Be 'assistant-RwP6ajRZ9gXW46urNrctfh'
        $files[0].Filename | Should -Be 'tfplan-review-report.md'
    }

    It 'skips excluded file IDs such as the uploaded plan' {
        @(Get-AgentOutputFile -Response $Response -ExcludeFileId 'assistant-RwP6ajRZ9gXW46urNrctfh') | Should -HaveCount 0
    }

    It 'falls back to File and Download ID labels when there is no citation' {
        $labelled = @{ output = @(@{ type = 'message'; role = 'assistant'; content = @(@{
                            type = 'output_text'; annotations = @()
                            text = "Report ready.`n`nFile: report.md  `nDownload ID: ``assistant-abc123```n" })
                })
        }
        $files = @(Get-AgentOutputFile -Response $labelled)
        $files[0].FileId | Should -Be 'assistant-abc123'
        $files[0].Filename | Should -Be 'report.md'
    }

    It 'returns nothing, without throwing, when no file came back' {
        $plain = @{ output = @(@{ type = 'message'; role = 'assistant'; content = @(@{ type = 'output_text'; text = 'No file.'; annotations = @() }) }) }
        @(Get-AgentOutputFile -Response $plain) | Should -HaveCount 0
    }

    It 'lists the tool calls the harness made, in order' {
        $activity = @(Get-AgentToolActivity -Response $Response)
        $activity | Should -HaveCount 6
        $activity[0] | Should -Be 'skill: tfplan-review'
        $activity[1..3] | ForEach-Object { $_ | Should -BeLike 'shell: python3 /home/session/.harness/skills/tfplan-review/scripts/analyze_plan.py *' }
        $activity[3] | Should -BeLike '*--format summary'
        $activity[4] | Should -Be 'tool: apply_patch'
        $activity[5] | Should -Be 'tool: upload_file_from_workspace_to_foundry_project'
    }
}

Describe 'Foundry REST helpers' {
    BeforeAll {
        $script:Endpoint = 'https://aif-x.services.ai.azure.com/api/projects/proj-x'
    }

    BeforeEach {
        Mock Get-FoundryAccessToken -ModuleName TfPlanReview { 'test-token' }
        Mock Start-Sleep -ModuleName TfPlanReview { }
    }

    It 'creates conversations on the agent endpoint with the preview header' {
        Mock Invoke-WebRequest -ModuleName TfPlanReview { New-HttpResponse 200 @{ id = 'conv_1' } }
        New-AgentConversation -ProjectEndpoint $Endpoint -AgentName 'tfplan-reviewer' | Should -Be 'conv_1'
        Should -Invoke Invoke-WebRequest -ModuleName TfPlanReview -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and
            $Uri -eq "$Endpoint/agents/tfplan-reviewer/endpoint/protocols/openai/conversations?api-version=v1" -and
            $Headers['Foundry-Features'] -eq 'MicrosoftCopilot=V1Preview' -and
            $Headers['Authorization'] -eq 'Bearer test-token'
        }
    }

    It 'polls a background response until it completes' {
        $script:Polls = 0
        Mock Invoke-WebRequest -ModuleName TfPlanReview -ParameterFilter { $Method -eq 'Post' } {
            New-HttpResponse 200 @{ id = 'resp_1'; status = 'queued' }
        }
        Mock Invoke-WebRequest -ModuleName TfPlanReview -ParameterFilter { $Method -eq 'Get' } {
            $script:Polls++
            New-HttpResponse 200 @{ id = 'resp_1'; status = $(if ($script:Polls -lt 2) { 'in_progress' } else { 'completed' }); output = @() }
        }

        $result = Invoke-AgentResponse -ProjectEndpoint $Endpoint -AgentName 'tfplan-reviewer' -ConversationId 'conv_1' `
            -Prompt 'Review the attached Terraform plan.' -FileId 'assistant-plan' -Model 'gpt-5.4-mini'

        $result.status | Should -Be 'completed'
        Should -Invoke Invoke-WebRequest -ModuleName TfPlanReview -Times 2 -Exactly -ParameterFilter {
            $Method -eq 'Get' -and $Uri -eq "$Endpoint/agents/tfplan-reviewer/endpoint/protocols/openai/responses/resp_1?api-version=v1"
        }
        Should -Invoke Invoke-WebRequest -ModuleName TfPlanReview -Times 1 -Exactly -ParameterFilter {
            if ($Method -ne 'Post') { return $false }
            $sent = $Body | ConvertFrom-Json -AsHashtable
            $sent.background -eq $true -and $sent.conversation.id -eq 'conv_1' -and
            $sent.model -eq 'gpt-5.4-mini' -and
            $sent.input[0].content[0].text -eq 'Review the attached Terraform plan.' -and
            $sent.input[0].content[1].type -eq 'input_file' -and $sent.input[0].content[1].file_id -eq 'assistant-plan' -and
            -not $sent.Contains('store') -and -not $sent.Contains('previous_response_id') -and -not $sent.Contains('max_output_tokens')
        }
    }

    It 'fails with the service error when the response fails' {
        Mock Invoke-WebRequest -ModuleName TfPlanReview {
            New-HttpResponse 200 @{ id = 'resp_2'; status = 'failed'; error = @{ code = 'server_error'; message = 'sandbox crashed' } }
        }
        { Invoke-AgentResponse -ProjectEndpoint $Endpoint -AgentName 'a' -ConversationId 'c' -Prompt 'p' } |
            Should -Throw '*failed*sandbox crashed*'
    }

    It 'gives up when the response is still running after the timeout' {
        Mock Invoke-WebRequest -ModuleName TfPlanReview { New-HttpResponse 200 @{ id = 'resp_3'; status = 'in_progress' } }
        { Invoke-AgentResponse -ProjectEndpoint $Endpoint -AgentName 'a' -ConversationId 'c' -Prompt 'p' -TimeoutSeconds 0 } |
            Should -Throw '*still in_progress*'
    }

    It 'surfaces HTTP errors with the status code and service message' {
        Mock Invoke-WebRequest -ModuleName TfPlanReview { New-HttpResponse 403 @{ error = @{ code = 'PermissionDenied'; message = 'Principal lacks Foundry User' } } }
        { New-AgentConversation -ProjectEndpoint $Endpoint -AgentName 'a' } | Should -Throw '*403*PermissionDenied*Principal lacks Foundry User*'
    }

    It 'uploads plans to the project Files API with purpose assistants' {
        $path = Join-Path $TestDrive 'safe-plan.json'
        Set-Content -Path $path -Value '{}'
        Mock Invoke-WebRequest -ModuleName TfPlanReview { New-HttpResponse 200 @{ id = 'assistant-plan'; object = 'file' } }
        Send-FoundryFile -ProjectEndpoint $Endpoint -Path $path | Should -Be 'assistant-plan'
        Should -Invoke Invoke-WebRequest -ModuleName TfPlanReview -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Post' -and $Uri -eq "$Endpoint/openai/v1/files" -and $Form.purpose -eq 'assistants' -and $Form.file.Name -eq 'safe-plan.json'
        }
    }

    It 'deletes uploaded files' {
        Mock Invoke-WebRequest -ModuleName TfPlanReview { New-HttpResponse 200 @{ id = 'assistant-plan'; deleted = $true } }
        Remove-FoundryFile -ProjectEndpoint $Endpoint -FileId 'assistant-plan'
        Should -Invoke Invoke-WebRequest -ModuleName TfPlanReview -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Delete' -and $Uri -eq "$Endpoint/openai/v1/files/assistant-plan"
        }
    }
}
