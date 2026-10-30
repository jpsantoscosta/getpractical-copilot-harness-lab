#requires -Version 7.4
<#
    TfPlanReview: redact a Terraform JSON plan on your machine, send it to the tfplan-reviewer
    agent (Microsoft Copilot harness in Foundry Agent Service), and collect the verdict and report.

    Uses the az CLI login for Entra ID tokens. No keys, no SDK.
#>
Set-StrictMode -Version Latest

$script:Placeholder = '(redacted)'
# String values under names built from these words are redacted even if the provider forgot to mark
# them. Names are split into words, so snake_case, kebab-case and camelCase (azapi bodies) all match.
$script:SecretWords = 'password', 'passwd', 'passphrase', 'secret', 'token', 'sas'
$script:SecretWordPairs = 'access key', 'account key', 'shared key', 'primary key', 'secondary key', 'private key', 'connection string'
# Everything else in a plan (state, planned values, configuration) is not needed for a review.
$script:KeptSections = 'format_version', 'terraform_version', 'timestamp', 'applyable', 'complete', 'errored',
'variables', 'resource_changes', 'resource_drift', 'output_changes'
$script:MinSpreadLength = 8
$script:CopilotPreview = 'MicrosoftCopilot=V1Preview'
$script:TokenCache = $null

function ConvertFrom-JsonText {
    param([Parameter(Mandatory)][string] $Text)
    $options = @{ AsHashtable = $true; Depth = 1024; ErrorAction = 'Stop' }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $options.DateKind = 'String' }
    return $Text | ConvertFrom-Json @options
}

function ConvertFrom-TfPlanFile {
    <#
    .SYNOPSIS
        Reads the output of `terraform show -json <planfile>` into an ordered hashtable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath)
    # Windows PowerShell 5.1 writes UTF-16 when you redirect with '>'.
    $text = if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    else {
        [System.Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
    }

    try { $plan = ConvertFrom-JsonText -Text $text }
    catch { throw "$Path is not a Terraform JSON plan: $($_.Exception.Message)" }
    if ($plan -isnot [System.Collections.IDictionary] -or -not $plan.Contains('format_version')) {
        throw "$Path is not a Terraform JSON plan (no format_version). Create one with: terraform show -json <planfile> > plan.json"
    }
    return $plan
}

function Protect-BySensitivity {
    # Replaces, in place, every value that a Terraform *_sensitive marker flags.
    param($Value, $Sensitivity, [hashtable] $Counter)

    if ($Value -is [System.Collections.IDictionary] -and $Sensitivity -is [System.Collections.IDictionary]) {
        foreach ($key in @($Sensitivity.Keys)) {
            if (-not $Value.Contains($key)) { continue }
            $marker = $Sensitivity[$key]
            if ($marker -is [bool]) {
                if ($marker -and $null -ne $Value[$key]) {
                    Add-KnownSecret -Value $Value[$key] -Counter $Counter
                    $Value[$key] = $script:Placeholder
                    $Counter.Count++
                }
            }
            else { Protect-BySensitivity -Value $Value[$key] -Sensitivity $marker -Counter $Counter }
        }
    }
    elseif ($Value -is [System.Collections.IList] -and $Sensitivity -is [System.Collections.IList]) {
        for ($i = 0; $i -lt [Math]::Min($Value.Count, $Sensitivity.Count); $i++) {
            $marker = $Sensitivity[$i]
            if ($marker -is [bool]) {
                if ($marker -and $null -ne $Value[$i]) {
                    Add-KnownSecret -Value $Value[$i] -Counter $Counter
                    $Value[$i] = $script:Placeholder
                    $Counter.Count++
                }
            }
            else { Protect-BySensitivity -Value $Value[$i] -Sensitivity $marker -Counter $Counter }
        }
    }
}

function Add-KnownSecret {
    # Remembers redacted strings so later copies of them can be found. Short strings are skipped:
    # spreading "prod" from a sensitive map would wipe out every "prod" tag in the plan.
    param($Value, [hashtable] $Counter)

    if ($Value -is [string]) {
        if ($Value.Length -ge $script:MinSpreadLength -and $Value -ne $script:Placeholder) { $null = $Counter.Secrets.Add($Value) }
    }
    elseif ($Value -is [System.Collections.IDictionary]) {
        foreach ($item in @($Value.Values)) { Add-KnownSecret -Value $item -Counter $Counter }
    }
    elseif ($Value -is [System.Collections.IList]) {
        foreach ($item in $Value) { Add-KnownSecret -Value $item -Counter $Counter }
    }
}

function Test-KnownSecret {
    param([string] $Text, [hashtable] $Counter)
    if ($Text -eq $script:Placeholder) { return $false }
    foreach ($secret in $Counter.Secrets) { if ($Text.Contains($secret)) { return $true } }
    return $false
}

function Protect-KnownValue {
    # Replaces, in place, any string that contains a value already known to be secret.
    param($Value, [hashtable] $Counter)

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $item = $Value[$key]
            if ($item -is [string]) {
                if (Test-KnownSecret -Text $item -Counter $Counter) { $Value[$key] = $script:Placeholder; $Counter.Count++ }
            }
            else { Protect-KnownValue -Value $item -Counter $Counter }
        }
    }
    elseif ($Value -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $Value.Count; $i++) {
            $item = $Value[$i]
            if ($item -is [string]) {
                if (Test-KnownSecret -Text $item -Counter $Counter) { $Value[$i] = $script:Placeholder; $Counter.Count++ }
            }
            else { Protect-KnownValue -Value $item -Counter $Counter }
        }
    }
}

function Test-SecretName {
    param([string] $Name)

    $spaced = $Name -creplace '(?<=[a-z0-9])(?=[A-Z])', '_' -creplace '(?<=[A-Z])(?=[A-Z][a-z])', '_'
    $words = @($spaced -split '[^A-Za-z0-9]+' | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    foreach ($word in $words) {
        if ($script:SecretWords -contains $word) { return $true }
    }
    for ($i = 0; $i -lt $words.Count - 1; $i++) {
        if ($script:SecretWordPairs -contains "$($words[$i]) $($words[$i + 1])") { return $true }
    }
    return $false
}

function Protect-SecretKey {
    # Replaces, in place, string values stored under secret-looking attribute names.
    param($Value, [hashtable] $Counter)

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            $item = $Value[$key]
            if ($item -is [System.Collections.IDictionary] -or $item -is [System.Collections.IList]) {
                Protect-SecretKey -Value $item -Counter $Counter
            }
            elseif ($item -is [string] -and $item -ne '' -and $item -ne $script:Placeholder -and (Test-SecretName ([string]$key))) {
                Add-KnownSecret -Value $item -Counter $Counter
                $Value[$key] = $script:Placeholder
                $Counter.Count++
            }
        }
    }
    elseif ($Value -is [System.Collections.IList]) {
        foreach ($item in $Value) { Protect-SecretKey -Value $item -Counter $Counter }
    }
}

function Protect-Change {
    param([System.Collections.IDictionary] $Change, [hashtable] $Counter)

    foreach ($side in 'before', 'after') {
        $marker = $Change["${side}_sensitive"]
        if ($marker -is [bool]) {
            if ($marker -and $null -ne $Change[$side]) {
                Add-KnownSecret -Value $Change[$side] -Counter $Counter
                $Change[$side] = $script:Placeholder
                $Counter.Count++
            }
        }
        else { Protect-BySensitivity -Value $Change[$side] -Sensitivity $marker -Counter $Counter }
        Protect-SecretKey -Value $Change[$side] -Counter $Counter
    }
}

function Protect-KnownValueInChange {
    param([System.Collections.IDictionary] $Change, [hashtable] $Counter)

    foreach ($side in 'before', 'after') {
        if ($Change[$side] -is [string]) {
            if (Test-KnownSecret -Text $Change[$side] -Counter $Counter) { $Change[$side] = $script:Placeholder; $Counter.Count++ }
        }
        else { Protect-KnownValue -Value $Change[$side] -Counter $Counter }
    }
}

function Get-PlanChange {
    # Every change object in a plan: resource changes, drift and output changes.
    param([System.Collections.IDictionary] $Plan)

    foreach ($section in 'resource_changes', 'resource_drift') {
        foreach ($resourceChange in @($Plan[$section])) {
            if ($resourceChange -is [System.Collections.IDictionary] -and $resourceChange['change'] -is [System.Collections.IDictionary]) {
                $resourceChange['change']
            }
        }
    }
    if ($Plan['output_changes'] -is [System.Collections.IDictionary]) {
        foreach ($outputChange in @($Plan['output_changes'].Values)) {
            if ($outputChange -is [System.Collections.IDictionary]) { $outputChange }
        }
    }
}

function Protect-TfPlanJson {
    <#
    .SYNOPSIS
        Returns a copy of a Terraform JSON plan that is safe to upload for review.
    .DESCRIPTION
        Keeps only the sections a review needs, replaces every value Terraform marks as sensitive
        (plus sensitive variables and secret-named attributes) with '(redacted)', and records what it
        did under x_redaction. The plan you pass in is not modified.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Plan)

    $copy = ConvertFrom-JsonText -Text ($Plan | ConvertTo-Json -Depth 100 -Compress)
    $counter = @{ Count = 0; Secrets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal) }
    $changes = @(Get-PlanChange -Plan $copy)

    foreach ($change in $changes) { Protect-Change -Change $change -Counter $counter }

    $declared = $null
    if ($copy['configuration'] -is [System.Collections.IDictionary] -and $copy['configuration']['root_module'] -is [System.Collections.IDictionary]) {
        $declared = $copy['configuration']['root_module']['variables']
    }
    if ($copy['variables'] -is [System.Collections.IDictionary]) {
        foreach ($name in @($copy['variables'].Keys)) {
            $variable = $copy['variables'][$name]
            $isSensitive = $declared -is [System.Collections.IDictionary] -and $declared[$name] -is [System.Collections.IDictionary] -and $declared[$name]['sensitive'] -eq $true
            if (($isSensitive -or (Test-SecretName $name)) -and $variable -is [System.Collections.IDictionary] -and $null -ne $variable['value']) {
                Add-KnownSecret -Value $variable['value'] -Counter $counter
                $variable['value'] = $script:Placeholder
                $counter.Count++
            }
        }
        Protect-SecretKey -Value $copy['variables'] -Counter $counter
    }

    # Terraform does not mark every copy of a secret (terraform_data echoes its sensitive input into
    # an unmarked output), so redact anything that still contains a value already known to be secret.
    if ($counter.Secrets.Count -gt 0) {
        foreach ($change in $changes) { Protect-KnownValueInChange -Change $change -Counter $counter }
        Protect-KnownValue -Value $copy['variables'] -Counter $counter
    }

    $safe = [ordered]@{}
    foreach ($key in $copy.Keys) {
        if ($script:KeptSections -contains $key) { $safe[$key] = $copy[$key] }
    }
    $safe['x_redaction'] = [ordered]@{
        redacted_values  = $counter.Count
        dropped_sections = @($copy.Keys | Where-Object { $script:KeptSections -notcontains $_ } | Sort-Object)
    }
    return $safe
}

function ConvertFrom-ReviewSummary {
    <#
    .SYNOPSIS
        Parses the tfplan-review-summary block that ends every review.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text)

    $blocks = [regex]::Matches($Text, '```tfplan-review-summary[ \t]*\r?\n(?<json>.*?)\r?\n[ \t]*```', 'Singleline')
    if ($blocks.Count -eq 0) { throw 'Agent reply has no tfplan-review-summary block.' }
    try { $summary = ConvertFrom-JsonText -Text $blocks[$blocks.Count - 1].Groups['json'].Value }
    catch { throw "The tfplan-review-summary block is not valid JSON: $($_.Exception.Message)" }
    foreach ($key in 'verdict', 'counts', 'findings') {
        if ($summary -isnot [System.Collections.IDictionary] -or -not $summary.Contains($key)) {
            throw "The tfplan-review-summary block is missing '$key'."
        }
    }
    return $summary
}

function Get-AgentOutputText {
    <#
    .SYNOPSIS
        Joins the text of every assistant message in a Responses API result.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Response)

    $parts = foreach ($item in @($Response['output'])) {
        if ($item -isnot [System.Collections.IDictionary] -or $item['type'] -ne 'message') { continue }
        foreach ($content in @($item['content'])) {
            if ($content -is [System.Collections.IDictionary] -and $content['type'] -eq 'output_text' -and $content['text']) { $content['text'] }
        }
    }
    return (@($parts) -join "`n`n")
}

function Get-AgentOutputFile {
    <#
    .SYNOPSIS
        Lists files the agent uploaded to Foundry Files (file citations, else File/Download ID labels).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Response,
        [string[]] $ExcludeFileId = @()
    )

    $files = [ordered]@{}
    foreach ($item in @($Response['output'])) {
        if ($item -isnot [System.Collections.IDictionary] -or $item['type'] -ne 'message') { continue }
        foreach ($content in @($item['content'])) {
            if ($content -isnot [System.Collections.IDictionary]) { continue }
            foreach ($annotation in @($content['annotations'])) {
                if ($annotation -is [System.Collections.IDictionary] -and $annotation['type'] -eq 'file_citation' -and
                    $annotation['file_id'] -and $ExcludeFileId -notcontains $annotation['file_id']) {
                    $files[$annotation['file_id']] = [pscustomobject]@{ FileId = $annotation['file_id']; Filename = $annotation['filename'] }
                }
            }
        }
    }

    if ($files.Count -eq 0) {
        $label = '(?im)^[ \t]*(?:\*\*)?File(?:\*\*)?:(?:\*\*)?[ \t]*`?(?<name>[^`\r\n]+?)`?[ \t]*\r?\n[ \t]*(?:\*\*)?Download ID(?:\*\*)?:(?:\*\*)?[ \t]*`?(?<id>[A-Za-z][\w-]+)`?'
        foreach ($match in [regex]::Matches((Get-AgentOutputText -Response $Response), $label)) {
            $id = $match.Groups['id'].Value
            if ($ExcludeFileId -notcontains $id) {
                $files[$id] = [pscustomobject]@{ FileId = $id; Filename = $match.Groups['name'].Value.Trim() }
            }
        }
    }
    return @($files.Values)
}

function Get-AgentToolActivity {
    <#
    .SYNOPSIS
        Summarises the tool calls the harness made (skill loads, shell commands, file tools), in order.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Response)

    foreach ($item in @($Response['output'])) {
        if ($item -isnot [System.Collections.IDictionary]) { continue }
        $type = [string]$item['type']
        if ($type -eq 'message' -or $type -eq 'reasoning' -or $type.EndsWith('_output')) { continue }
        if ($type -eq 'function_call' -and $item['name'] -eq 'skill') {
            $skill = try { (ConvertFrom-JsonText -Text $item['arguments'])['skill'] } catch { '?' }
            "skill: $skill"
        }
        elseif ($type -eq 'function_call') { "tool: $($item['name'])" }
        elseif ($type -eq 'shell_call') {
            $action = $item['action']
            $commands = if ($action -is [System.Collections.IDictionary]) { @($action['commands']) } else { @() }
            "shell: $($commands -join ' && ')"
        }
        else { $type }
    }
}

function Get-FoundryAccessToken {
    <#
    .SYNOPSIS
        Entra ID token for the Foundry data plane, from the az CLI login. Cached until near expiry.
    #>
    [CmdletBinding()]
    param()

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($script:TokenCache -and $script:TokenCache.ExpiresOn -gt ($now + 300)) { return $script:TokenCache.Token }
    $raw = az account get-access-token --resource 'https://ai.azure.com' --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { throw "Could not get an Entra ID token for https://ai.azure.com. Run 'az login' first." }
    $token = ($raw | Out-String) | ConvertFrom-Json
    $script:TokenCache = @{ Token = $token.accessToken; ExpiresOn = [long]$token.expires_on }
    return $token.accessToken
}

function Invoke-FoundryApi {
    param(
        [Parameter(Mandatory)][ValidateSet('Get', 'Post', 'Delete')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [object] $Body,
        [System.Collections.IDictionary] $Form,
        [string] $Feature,
        [string] $OutFile
    )

    $headers = @{ Authorization = "Bearer $(Get-FoundryAccessToken)" }
    if ($Feature) { $headers['Foundry-Features'] = $Feature }
    $request = @{ Method = $Method; Uri = $Uri; Headers = $headers; SkipHttpErrorCheck = $true }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.Body = $Body | ConvertTo-Json -Depth 50 -Compress
        $request.ContentType = 'application/json'
    }
    if ($Form) { $request.Form = $Form }
    if ($OutFile) { $request.OutFile = $OutFile; $request.PassThru = $true }

    $response = Invoke-WebRequest @request
    if ($response.StatusCode -ge 400) {
        $detail = "$($response.Content)"
        try {
            $parsed = ConvertFrom-JsonText -Text $detail
            if ($parsed -is [System.Collections.IDictionary] -and $parsed['error'] -is [System.Collections.IDictionary]) {
                $detail = "$($parsed['error']['code']): $($parsed['error']['message'])"
            }
        }
        catch { }
        throw "Foundry request $($Method.ToUpper()) $Uri failed with HTTP $($response.StatusCode). $detail"
    }
    if ($OutFile -or -not $response.Content) { return }
    return ConvertFrom-JsonText -Text ([string]$response.Content)
}

function Get-AgentEndpoint {
    param([string] $ProjectEndpoint, [string] $AgentName)
    return "$($ProjectEndpoint.TrimEnd('/'))/agents/$([uri]::EscapeDataString($AgentName))/endpoint/protocols/openai"
}

function Send-FoundryFile {
    <#
    .SYNOPSIS
        Uploads a file to the project's Files API and returns its file ID.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectEndpoint, [Parameter(Mandatory)][string] $Path)

    $file = Invoke-FoundryApi -Method Post -Uri "$($ProjectEndpoint.TrimEnd('/'))/openai/v1/files" `
        -Form @{ purpose = 'assistants'; file = Get-Item -LiteralPath $Path }
    return $file['id']
}

function Save-FoundryFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProjectEndpoint,
        [Parameter(Mandatory)][string] $FileId,
        [Parameter(Mandatory)][string] $Destination
    )
    Invoke-FoundryApi -Method Get -Uri "$($ProjectEndpoint.TrimEnd('/'))/openai/v1/files/$FileId/content" -OutFile $Destination
}

function Remove-FoundryFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectEndpoint, [Parameter(Mandatory)][string] $FileId)
    $null = Invoke-FoundryApi -Method Delete -Uri "$($ProjectEndpoint.TrimEnd('/'))/openai/v1/files/$FileId"
}

function New-AgentConversation {
    <#
    .SYNOPSIS
        Starts a conversation. The Copilot harness requires one for every request.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ProjectEndpoint, [Parameter(Mandatory)][string] $AgentName)

    $conversation = Invoke-FoundryApi -Method Post -Uri "$(Get-AgentEndpoint $ProjectEndpoint $AgentName)/conversations?api-version=v1" `
        -Body @{} -Feature $script:CopilotPreview
    return $conversation['id']
}

function Remove-AgentConversation {
    <#
    .SYNOPSIS
        Deletes a conversation. Foundry also cleans up the harness session and workspace behind it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProjectEndpoint,
        [Parameter(Mandatory)][string] $AgentName,
        [Parameter(Mandatory)][string] $ConversationId
    )
    $null = Invoke-FoundryApi -Method Delete -Uri "$(Get-AgentEndpoint $ProjectEndpoint $AgentName)/conversations/$ConversationId`?api-version=v1" `
        -Feature $script:CopilotPreview
}

function Invoke-AgentResponse {
    <#
    .SYNOPSIS
        Sends one message (optionally with an attached file) and waits for the harness to finish.
    .DESCRIPTION
        Runs the request in background mode and polls it. Harness-managed settings such as
        max_output_tokens, truncation, store=false and previous_response_id are deliberately not sent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProjectEndpoint,
        [Parameter(Mandatory)][string] $AgentName,
        [Parameter(Mandatory)][string] $ConversationId,
        [Parameter(Mandatory)][string] $Prompt,
        [string] $FileId,
        [string] $Model,
        [int] $TimeoutSeconds = 900,
        [int] $PollSeconds = 3
    )

    $agentEndpoint = Get-AgentEndpoint $ProjectEndpoint $AgentName
    $content = @(@{ type = 'input_text'; text = $Prompt })
    if ($FileId) { $content += @{ type = 'input_file'; file_id = $FileId } }
    $body = [ordered]@{
        conversation = @{ id = $ConversationId }
        input        = @(@{ role = 'user'; content = $content })
        background   = $true
    }
    if ($Model) { $body.model = $Model }

    $response = Invoke-FoundryApi -Method Post -Uri "$agentEndpoint/responses?api-version=v1" -Body $body -Feature $script:CopilotPreview
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($response['status'] -in 'queued', 'in_progress') {
        if ([DateTime]::UtcNow -ge $deadline) {
            throw "Response $($response['id']) is still $($response['status']) after $TimeoutSeconds seconds."
        }
        Start-Sleep -Seconds $PollSeconds
        $response = Invoke-FoundryApi -Method Get -Uri "$agentEndpoint/responses/$($response['id'])?api-version=v1" -Feature $script:CopilotPreview
    }

    if ($response['status'] -ne 'completed') {
        $reason = if ($response['error'] -is [System.Collections.IDictionary]) { "$($response['error']['code']): $($response['error']['message'])" }
        elseif ($response['incomplete_details']) { $response['incomplete_details'] | ConvertTo-Json -Compress }
        else { 'no error details' }
        throw "Response $($response['id']) $($response['status']): $reason"
    }
    return $response
}

Export-ModuleMember -Function ConvertFrom-TfPlanFile, Protect-TfPlanJson, ConvertFrom-ReviewSummary,
Get-AgentOutputText, Get-AgentOutputFile, Get-AgentToolActivity, Get-FoundryAccessToken,
Send-FoundryFile, Save-FoundryFile, Remove-FoundryFile, New-AgentConversation, Remove-AgentConversation,
Invoke-AgentResponse
