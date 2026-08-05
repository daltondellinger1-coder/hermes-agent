[CmdletBinding()]
param([switch]$RequireRegressionField)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot
Import-Module (Join-Path $Root "HermesHealthContract.psm1") -Force
$FixtureText = Get-Content -LiteralPath (Join-Path $Root "fixtures/health-detailed.json") -Raw
$Fixture = $FixtureText | ConvertFrom-Json

if ($RequireRegressionField -and
    @($Fixture.PSObject.Properties.Match("required_field_that_does_not_exist")).Count -eq 0) {
    throw "Simulated contract drift: required_field_that_does_not_exist is missing."
}

$Result = Test-HermesHealthPayload -Content $FixtureText
if (-not $Result.Healthy) { throw "Captured real health fixture failed: $($Result.Detail)" }

foreach ($Platform in @("telegram", "discord", "api_server", "webhook")) {
    foreach ($FailureState in @("disconnected", "error")) {
        $Payload = $FixtureText | ConvertFrom-Json
        $Payload.platforms.$Platform.state = $FailureState
        $Result = Test-HermesHealthPayload -Content ($Payload | ConvertTo-Json -Depth 10)
        if ($Result.Healthy -or $Result.Detail -notmatch [regex]::Escape($Platform)) {
            throw "Required platform $Platform=$FailureState was not rejected with a named detail."
        }
    }
    $Payload = $FixtureText | ConvertFrom-Json
    $Payload.platforms.PSObject.Properties.Remove($Platform)
    $Result = Test-HermesHealthPayload -Content ($Payload | ConvertTo-Json -Depth 10)
    if ($Result.Healthy -or $Result.Detail -notmatch [regex]::Escape($Platform)) {
        throw "Missing required platform $Platform was not rejected with a named detail."
    }
}

$Payload = $FixtureText | ConvertFrom-Json
$Payload.gateway_state = "stopped"
$Result = Test-HermesHealthPayload -Content ($Payload | ConvertTo-Json -Depth 10)
if ($Result.Healthy -or $Result.Detail -ne "gateway_state=stopped") {
    throw "Stopped gateway was not rejected."
}

$Payload = $FixtureText | ConvertFrom-Json
$Payload.platforms.feishu.state = "error"
$Result = Test-HermesHealthPayload -Content ($Payload | ConvertTo-Json -Depth 10)
if (-not $Result.Healthy) { throw "Optional feishu degradation failed health: $($Result.Detail)" }

foreach ($InvalidContent in @("{not-json", "")) {
    $Result = Test-HermesHealthPayload -Content $InvalidContent
    if ($Result.Healthy) { throw "Malformed or empty payload was accepted." }
}

# Regression guard for the original failure class: requiring a field absent
# from the captured payload must be observable, never silently assumed.
if (@($Fixture.PSObject.Properties.Match("required_field_that_does_not_exist")).Count -ne 0) {
    throw "Original-defect regression fixture unexpectedly contains the fake field."
}

Write-Output "Hermes health contract tests passed."
