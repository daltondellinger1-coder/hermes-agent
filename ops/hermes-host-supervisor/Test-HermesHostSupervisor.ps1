[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SupervisorPath = Join-Path $PSScriptRoot "HermesHostSupervisor.ps1"
$AlertModulePath = Join-Path $PSScriptRoot "HermesAlert.psm1"
$TestDirectory = Join-Path $env:TEMP ("HermesSupervisorTest-" + [guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Path $TestDirectory -Force | Out-Null

    Import-Module $AlertModulePath -Force
    $AlertConfigPath = Join-Path $TestDirectory "alert.config.json"
    [pscustomobject]@{ bot_token = "test-token"; chat_id = "123456" } |
        ConvertTo-Json |
        Set-Content -LiteralPath $AlertConfigPath -Encoding UTF8
    $AlertState = [pscustomobject]@{}
    $script:TransportCalls = 0
    $FakeTransport = {
        param($Uri, $Body, $TimeoutSec)
        $script:TransportCalls++
        if ($TimeoutSec -ne 10) { throw "Alert timeout was not bounded to 10 seconds." }
        [pscustomobject]@{ ok = $true }
    }
    1..5 | ForEach-Object {
        $Result = Send-HermesAlert `
            -Condition "rate-limit-test" `
            -Message "test" `
            -State $AlertState `
            -ConfigPath $AlertConfigPath `
            -NowUtc ([datetime]"2026-08-05T02:00:00Z") `
            -Transport $FakeTransport
        if ($_ -eq 1 -and -not $Result.Sent) { throw "First alert was not sent." }
        if ($_ -gt 1 -and -not $Result.RateLimited) { throw "Repeated alert was not rate limited." }
    }
    if ($script:TransportCalls -ne 1) { throw "Five calls produced $script:TransportCalls transports instead of one." }

    $script:Warnings = 0
    $FailedResult = Send-HermesAlert `
        -Condition "transport-failure-test" `
        -Message "test" `
        -State ([pscustomobject]@{}) `
        -ConfigPath $AlertConfigPath `
        -Transport { throw "invalid token" } `
        -WarningSink { param($Text) $script:Warnings++ }
    if ($FailedResult.Sent -or $script:Warnings -ne 1) {
        throw "Alert transport failure did not return normally with one warning."
    }

    & $SupervisorPath -DataDirectory $TestDirectory -NoRemediation
    if ($LASTEXITCODE -ne 0) { throw "Healthy dry run returned exit code $LASTEXITCODE" }
    $State = Get-Content (Join-Path $TestDirectory "state.json") -Raw | ConvertFrom-Json
    if ([int]$State.ConsecutiveFailures -ne 0 -or $State.LastOutcome -ne "healthy") {
        throw "Healthy dry run did not persist a healthy state."
    }

    1..3 | ForEach-Object {
        & $SupervisorPath `
            -HealthUrl "http://127.0.0.1:9/health" `
            -FailureThreshold 3 `
            -DataDirectory $TestDirectory `
            -NoRemediation
        if ($LASTEXITCODE -ne 0) { throw "Failure simulation returned exit code $LASTEXITCODE" }
    }

    $State = Get-Content (Join-Path $TestDirectory "state.json") -Raw | ConvertFrom-Json
    if ([int]$State.ConsecutiveFailures -ne 3 -or $State.LastOutcome -ne "no-remediation") {
        throw "Failure threshold state was not persisted correctly."
    }
    if ([int]$State.RecoveryCount -ne 0) {
        throw "Dry-run failure simulation attempted remediation."
    }

    & $SupervisorPath -DataDirectory $TestDirectory -NoRemediation
    $State = Get-Content (Join-Path $TestDirectory "state.json") -Raw | ConvertFrom-Json
    if ([int]$State.ConsecutiveFailures -ne 0 -or $State.LastOutcome -ne "healthy") {
        throw "A healthy check did not reset the failure counter."
    }

    Write-Output "Hermes host supervisor tests passed."
}
finally {
    Remove-Item -LiteralPath $TestDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
