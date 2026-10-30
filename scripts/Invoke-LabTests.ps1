#requires -Version 7.4
<#
.SYNOPSIS
    Runs the lab's tests: offline checks by default, plus the live suite with -Live.

.DESCRIPTION
    Offline (no Azure calls): Python analyser tests, Pester unit tests, terraform fmt, terraform
    validate for infra/ and demo/, and the mocked terraform test suite for infra/.
    -Live adds tests/live, which talks to the deployed lab (az login and Terraform state required).

.EXAMPLE
    ./scripts/Invoke-LabTests.ps1
.EXAMPLE
    ./scripts/Invoke-LabTests.ps1 -Live
#>
[CmdletBinding()]
param([switch] $Live)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$python = if ($IsWindows) { 'python' } else { 'python3' }
$results = [System.Collections.Generic.List[object]]::new()

function Invoke-Step {
    param([string] $Name, [scriptblock] $Action)

    Write-Host "==> $Name"
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $detail = & $Action
        $passed = $true
    }
    catch {
        $detail = $_.Exception.Message
        $passed = $false
    }
    $results.Add([pscustomobject]@{
            Step    = $Name
            Result  = if ($passed) { 'PASS' } else { 'FAIL' }
            Seconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            Detail  = $detail
        })
}

function Invoke-Native {
    # Runs a native command, returns its last output line, throws on a non-zero exit code.
    param([string] $File, [string[]] $Arguments)
    $output = & $File @Arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw (($output | Select-Object -Last 15) -join "`n") }
    return ($output | Where-Object { $_.Trim() } | Select-Object -Last 1)
}

function Invoke-PesterSuite {
    param([string] $Path, [string[]] $Tag)
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = $Path
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    if ($Tag) { $configuration.Filter.Tag = $Tag }
    $run = Invoke-Pester -Configuration $configuration
    if ($run.FailedCount -gt 0 -or $run.Result -ne 'Passed') {
        throw "$($run.FailedCount) failed, $($run.PassedCount) passed ($($run.Result))"
    }
    return "$($run.PassedCount) passed"
}

Push-Location $repo
try {
    Invoke-Step 'Python analyser tests' { Invoke-Native $python @('-B', '-m', 'unittest', 'discover', '-s', 'tests/python') }
    Invoke-Step 'Pester unit tests' { Invoke-PesterSuite -Path (Join-Path $repo 'tests' 'unit') }
    Invoke-Step 'terraform fmt' { Invoke-Native terraform @('fmt', '-check', '-recursive'); 'formatted' }
    foreach ($folder in 'infra', 'demo') {
        Invoke-Step "terraform validate ($folder)" {
            Invoke-Native terraform @("-chdir=$folder", 'init', '-backend=false', '-input=false', '-no-color') | Out-Null
            Invoke-Native terraform @("-chdir=$folder", 'validate', '-no-color')
        }
    }
    Invoke-Step 'terraform test (infra, mocked)' { Invoke-Native terraform @('-chdir=infra', 'test', '-no-color') }
    if ($Live) {
        Invoke-Step 'Pester live tests' { Invoke-PesterSuite -Path (Join-Path $repo 'tests' 'live') -Tag 'Live' }
    }
}
finally {
    Pop-Location
}

$results | Format-Table -AutoSize -Wrap | Out-Host
if ($results.Result -contains 'FAIL') {
    Write-Error 'One or more test steps failed.'
    exit 1
}
Write-Host "All $($results.Count) steps passed."
