[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SupervisorPath = Join-Path $PSScriptRoot "HermesHostSupervisor.ps1"
$TestDirectory = Join-Path $env:TEMP ("HermesSupervisorTest-" + [guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Path $TestDirectory -Force | Out-Null

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

