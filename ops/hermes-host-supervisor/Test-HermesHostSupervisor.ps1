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
    $SupervisorTransport = { param($Uri, $Body, $TimeoutSec) [pscustomobject]@{ ok = $true } }

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

    $ProbeFaultDirectory = Join-Path $TestDirectory "probe-fault"
    $ProbeTracker = [pscustomobject]@{ ShutdownCalls = 0 }
    $AllGoodEvidence = {
        param($FilePath, $Arguments, $TimeoutSeconds)
        if ($Arguments -eq "--shutdown") {
            $ProbeTracker.ShutdownCalls++
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = ""; Error = "" }
        }
        if ($Arguments -match 'is-active') {
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = "active"; Error = "" }
        }
        if ($Arguments -match '/usr/bin/ss') {
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = "LISTEN 0 128 127.0.0.1:8646"; Error = "" }
        }
        [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = ""; Error = "" }
    }.GetNewClosure()
    & $SupervisorPath `
        -FailureThreshold 1 `
        -RecoveryCooldownMinutes 0 `
        -DataDirectory $ProbeFaultDirectory `
        -AlertConfigPath $AlertConfigPath `
        -HealthProbe { $false } `
        -ProcessInvoker $AllGoodEvidence `
        -AlertTransport $SupervisorTransport
    $State = Get-Content (Join-Path $ProbeFaultDirectory "state.json") -Raw | ConvertFrom-Json
    if ($State.LastOutcome -ne "probe-side-fault" -or $ProbeTracker.ShutdownCalls -ne 0) {
        throw "All-good evidence did not fail closed as a probe-side fault."
    }

    $GatewayFaultDirectory = Join-Path $TestDirectory "gateway-fault"
    $GatewayTracker = [pscustomobject]@{ Restarts = 0; Shutdowns = 0 }
    $GatewayFaultEvidence = {
        param($FilePath, $Arguments, $TimeoutSeconds)
        if ($Arguments -eq "--shutdown") {
            $GatewayTracker.Shutdowns++
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = ""; Error = "" }
        }
        if ($Arguments -match 'systemctl.*restart') {
            $GatewayTracker.Restarts++
            return [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Output = ""; Error = "failed" }
        }
        if ($Arguments -match 'is-active') {
            return [pscustomobject]@{ ExitCode = 3; TimedOut = $false; Output = "inactive"; Error = "" }
        }
        if ($Arguments -match '/usr/bin/ss') {
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = ""; Error = "" }
        }
        [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = ""; Error = "" }
    }.GetNewClosure()
    & $SupervisorPath `
        -FailureThreshold 1 `
        -RecoveryCooldownMinutes 0 `
        -DataDirectory $GatewayFaultDirectory `
        -AlertConfigPath $AlertConfigPath `
        -HealthProbe { $false } `
        -ProcessInvoker $GatewayFaultEvidence `
        -AlertTransport $SupervisorTransport
    if ($GatewayTracker.Restarts -ne 1 -or $GatewayTracker.Shutdowns -ne 0) {
        throw "Gateway fault did not stop after the gateway-only recovery attempt."
    }

    $AmbiguousDirectory = Join-Path $TestDirectory "ambiguous"
    $AmbiguousTracker = [pscustomobject]@{ Shutdowns = 0 }
    $AmbiguousEvidence = {
        param($FilePath, $Arguments, $TimeoutSeconds)
        if ($Arguments -eq "--shutdown") { $AmbiguousTracker.Shutdowns++ }
        if ($Arguments -match '/bin/true') {
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = ""; Error = "" }
        }
        [pscustomobject]@{ ExitCode = $null; TimedOut = $true; Output = ""; Error = "timeout" }
    }.GetNewClosure()
    & $SupervisorPath `
        -FailureThreshold 1 `
        -RecoveryCooldownMinutes 0 `
        -DataDirectory $AmbiguousDirectory `
        -AlertConfigPath $AlertConfigPath `
        -HealthProbe { $false } `
        -ProcessInvoker $AmbiguousEvidence `
        -AlertTransport $SupervisorTransport
    $State = Get-Content (Join-Path $AmbiguousDirectory "state.json") -Raw | ConvertFrom-Json
    if ($State.LastOutcome -ne "ambiguous" -or $AmbiguousTracker.Shutdowns -ne 0) {
        throw "Unavailable evidence did not fail closed as ambiguous."
    }

    $VmFaultDirectory = Join-Path $TestDirectory "vm-fault"
    $VmTracker = [pscustomobject]@{ ShutdownSeen = $false; HealthCalls = 0 }
    $VmFaultEvidence = {
        param($FilePath, $Arguments, $TimeoutSeconds)
        if ($Arguments -eq "--shutdown") {
            $VmTracker.ShutdownSeen = $true
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = ""; Error = "" }
        }
        if ($Arguments -match '/bin/true' -and -not $VmTracker.ShutdownSeen) {
            return [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Output = ""; Error = "unreachable" }
        }
        [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = ""; Error = "" }
    }.GetNewClosure()
    $VmHealthProbe = { $VmTracker.HealthCalls++; $VmTracker.HealthCalls -gt 1 }.GetNewClosure()
    & $SupervisorPath `
        -FailureThreshold 1 `
        -RecoveryCooldownMinutes 0 `
        -DataDirectory $VmFaultDirectory `
        -AlertConfigPath $AlertConfigPath `
        -HealthProbe $VmHealthProbe `
        -ProcessInvoker $VmFaultEvidence `
        -AlertTransport $SupervisorTransport
    $State = Get-Content (Join-Path $VmFaultDirectory "state.json") -Raw | ConvertFrom-Json
    if (-not $VmTracker.ShutdownSeen -or $State.LastOutcome -ne "wsl-restarted") {
        throw "A classified VM fault did not invoke the stubbed shutdown recovery path."
    }

    $CapDirectory = Join-Path $TestDirectory "cap"
    $CapTracker = [pscustomobject]@{ RecoveryCalls = 0 }
    $RecoveryFailure = { $CapTracker.RecoveryCalls++; "recovery-failed" }.GetNewClosure()
    1..4 | ForEach-Object {
        & $SupervisorPath `
            -FailureThreshold 1 `
            -RecoveryCooldownMinutes 0 `
            -MaxConsecutiveRecoveryFailures 3 `
            -DataDirectory $CapDirectory `
            -AlertConfigPath $AlertConfigPath `
            -HealthProbe { $false } `
            -RecoveryInvoker $RecoveryFailure `
            -AlertTransport $SupervisorTransport
    }
    $State = Get-Content (Join-Path $CapDirectory "state.json") -Raw | ConvertFrom-Json
    $CapAlert = @($State.AlertLastSentUtc.PSObject.Properties.Match("remediation-cap-reached"))
    if (-not $State.RecoverySuspended -or [int]$State.ConsecutiveRecoveryFailures -ne 3 -or
        $State.LastOutcome -ne "suspended" -or $CapTracker.RecoveryCalls -ne 3 -or $CapAlert.Count -ne 1) {
        throw "Recovery failure cap assertion failed: suspended=$($State.RecoverySuspended) failures=$($State.ConsecutiveRecoveryFailures) outcome=$($State.LastOutcome) calls=$($CapTracker.RecoveryCalls) capAlerts=$($CapAlert.Count)."
    }

    & $SupervisorPath -DataDirectory $CapDirectory -ResetRecoverySuspension
    $State = Get-Content (Join-Path $CapDirectory "state.json") -Raw | ConvertFrom-Json
    if ($State.RecoverySuspended -or [int]$State.ConsecutiveRecoveryFailures -ne 0 -or
        $State.LastOutcome -ne "suspension-reset") {
        throw "Explicit recovery-suspension reset did not clear the latch."
    }

    $PrivilegeDirectory = Join-Path $TestDirectory "privilege"
    $PrivilegeEvidence = {
        param($FilePath, $Arguments, $TimeoutSeconds)
        if ($Arguments -eq "--shutdown") {
            return [pscustomobject]@{ ExitCode = $null; TimedOut = $true; Output = ""; Error = "timeout" }
        }
        [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Output = ""; Error = "unreachable" }
    }
    & $SupervisorPath `
        -FailureThreshold 1 `
        -RecoveryCooldownMinutes 0 `
        -DataDirectory $PrivilegeDirectory `
        -AlertConfigPath $AlertConfigPath `
        -HealthProbe { $false } `
        -ProcessInvoker $PrivilegeEvidence `
        -ServiceRestarter { throw [System.UnauthorizedAccessException]::new("denied") } `
        -AlertTransport $SupervisorTransport
    $State = Get-Content (Join-Path $PrivilegeDirectory "state.json") -Raw | ConvertFrom-Json
    if ($State.LastOutcome -ne "recovery-blocked-privilege" -or
        $State.LastRecoveryFailureOutcome -ne "recovery-blocked-privilege") {
        throw "Privilege-blocked recovery was not classified distinctly."
    }

    Write-Output "Hermes host supervisor tests passed."
}
finally {
    Remove-Item -LiteralPath $TestDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
