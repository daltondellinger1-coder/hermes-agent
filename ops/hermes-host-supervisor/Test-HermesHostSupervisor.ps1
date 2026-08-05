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

    $LegacyDirectory = Join-Path $TestDirectory "legacy-state"
    New-Item -ItemType Directory -Path $LegacyDirectory -Force | Out-Null
    [pscustomobject]@{
        ConsecutiveFailures = 0
        LastCheckUtc = $null
        LastHealthyUtc = $null
        LastRecoveryUtc = $null
        RecoveryCount = 67
        ConsecutiveRecoveryFailures = $null
        RecoverySuspended = $null
        LastOutcome = "healthy"
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LegacyDirectory "state.json") -Encoding UTF8
    & $SupervisorPath -DataDirectory $LegacyDirectory -NoRemediation -HealthProbe { $true }
    $State = Get-Content (Join-Path $LegacyDirectory "state.json") -Raw | ConvertFrom-Json
    if ($null -eq $State.ConsecutiveRecoveryFailures -or
        [int]$State.ConsecutiveRecoveryFailures -ne 0 -or $State.RecoverySuspended) {
        throw "Legacy state did not migrate recovery-cap fields to safe defaults."
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
        if ($Arguments -match 'systemctl.*\srestart\s') {
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
        if ($Arguments -match 'is-active') {
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = "active"; Error = "" }
        }
        if ($Arguments -match '/usr/bin/ss') {
            # Real zero-match output from `ss -ltn` before -H was added. A
            # header row must never count as a listening socket.
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process"; Error = "" }
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

    $TailscaleSuccessDirectory = Join-Path $TestDirectory "tailscale-success"
    $TailscaleSuccessTracker = [pscustomobject]@{ Running = $false; StartCalls = 0 }
    $TailscaleSuccessProbe = { $TailscaleSuccessTracker.Running }.GetNewClosure()
    $TailscaleSuccessStarter = {
        $TailscaleSuccessTracker.StartCalls++
        $TailscaleSuccessTracker.Running = $true
    }.GetNewClosure()
    & $SupervisorPath `
        -DataDirectory $TailscaleSuccessDirectory `
        -AlertConfigPath $AlertConfigPath `
        -HealthProbe { $true } `
        -TailscaleProcessProbe $TailscaleSuccessProbe `
        -TailscaleStarter $TailscaleSuccessStarter `
        -TailscaleStartWaitSeconds 0 `
        -AlertTransport $SupervisorTransport
    $State = Get-Content (Join-Path $TailscaleSuccessDirectory "state.json") -Raw | ConvertFrom-Json
    $RestartAlert = @($State.AlertLastSentUtc.PSObject.Properties.Match("tailscale-client-restarted"))
    if ($TailscaleSuccessTracker.StartCalls -ne 1 -or
        [int]$State.TailscaleConsecutiveRestartFailures -ne 0 -or
        $State.TailscaleRecoverySuspended -or $RestartAlert.Count -ne 1) {
        throw "Tailscale successful restart assertion failed."
    }

    $TailscaleCapDirectory = Join-Path $TestDirectory "tailscale-cap"
    $TailscaleCapTracker = [pscustomobject]@{ StartCalls = 0 }
    $TailscaleFailureStarter = { $TailscaleCapTracker.StartCalls++ }.GetNewClosure()
    1..4 | ForEach-Object {
        & $SupervisorPath `
            -DataDirectory $TailscaleCapDirectory `
            -AlertConfigPath $AlertConfigPath `
            -HealthProbe { $true } `
            -TailscaleProcessProbe { $false } `
            -TailscaleStarter $TailscaleFailureStarter `
            -TailscaleStartWaitSeconds 0 `
            -MaxTailscaleRestartFailures 3 `
            -AlertTransport $SupervisorTransport
    }
    $State = Get-Content (Join-Path $TailscaleCapDirectory "state.json") -Raw | ConvertFrom-Json
    $TailscaleCapAlert = @($State.AlertLastSentUtc.PSObject.Properties.Match("tailscale-remediation-cap-reached"))
    if ($TailscaleCapTracker.StartCalls -ne 3 -or
        [int]$State.TailscaleConsecutiveRestartFailures -ne 3 -or
        -not $State.TailscaleRecoverySuspended -or $TailscaleCapAlert.Count -ne 1) {
        throw "Tailscale restart cap assertion failed."
    }

    & $SupervisorPath `
        -DataDirectory $TailscaleCapDirectory `
        -ResetTailscaleSuspension `
        -TailscaleProcessProbe { $false }
    $State = Get-Content (Join-Path $TailscaleCapDirectory "state.json") -Raw | ConvertFrom-Json
    if ($State.TailscaleRecoverySuspended -or [int]$State.TailscaleConsecutiveRestartFailures -ne 0) {
        throw "Explicit Tailscale-suspension reset did not clear the latch."
    }

    $TailscaleNoRemediationDirectory = Join-Path $TestDirectory "tailscale-no-remediation"
    $TailscaleNoRemediationTracker = [pscustomobject]@{ StartCalls = 0 }
    & $SupervisorPath `
        -DataDirectory $TailscaleNoRemediationDirectory `
        -HealthProbe { $true } `
        -TailscaleProcessProbe { $false } `
        -TailscaleStarter { $TailscaleNoRemediationTracker.StartCalls++ }.GetNewClosure() `
        -NoRemediation
    $State = Get-Content (Join-Path $TailscaleNoRemediationDirectory "state.json") -Raw | ConvertFrom-Json
    if ($TailscaleNoRemediationTracker.StartCalls -ne 0 -or
        [int]$State.TailscaleConsecutiveRestartFailures -ne 0 -or $State.TailscaleRecoverySuspended) {
        throw "No-remediation Tailscale check attempted or counted a restart."
    }

    $BootFixture = Get-Content (Join-Path $PSScriptRoot "fixtures\journalctl-list-boots-storm.txt") -Raw
    $BootAlarmDirectory = Join-Path $TestDirectory "boot-alarm"
    $BootAlertTracker = [pscustomobject]@{ Calls = 0 }
    $BootTransport = { param($Uri, $Body, $TimeoutSec) $BootAlertTracker.Calls++; [pscustomobject]@{ ok = $true } }.GetNewClosure()
    $BootInvoker = {
        param($FilePath, $Arguments, $TimeoutSeconds)
        if ($Arguments -match 'journalctl --list-boots') {
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = $BootFixture; Error = "" }
        }
        [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = ""; Error = "" }
    }.GetNewClosure()
    1..2 | ForEach-Object {
        & $SupervisorPath -DataDirectory $BootAlarmDirectory -HealthProbe { $true } `
            -TailscaleProcessProbe { $true } -ProcessInvoker $BootInvoker `
            -ReliabilityNowUtc ([datetime]"2026-08-04T16:20:05Z") `
            -AlertConfigPath $AlertConfigPath -AlertTransport $BootTransport
    }
    $State = Get-Content (Join-Path $BootAlarmDirectory "state.json") -Raw | ConvertFrom-Json
    if (-not $State.BootStormActive -or $BootAlertTracker.Calls -ne 1) {
        throw "Real boot-storm fixture did not emit exactly one alert."
    }

    $RestartAlarmDirectory = Join-Path $TestDirectory "restart-alarm"
    $RestartAlertTracker = [pscustomobject]@{ Calls = 0; Count = 0 }
    $RestartTransport = { param($Uri, $Body, $TimeoutSec) $RestartAlertTracker.Calls++; [pscustomobject]@{ ok = $true } }.GetNewClosure()
    0, 5, 10 | ForEach-Object {
        $RestartAlertTracker.Count = $_
        $RestartProbe = {
            [pscustomobject]@{
                BootCountLastHour = 1
                RestartCounts = [pscustomobject]@{ 'dalton-goals-dashboard.service' = $RestartAlertTracker.Count }
            }
        }.GetNewClosure()
        & $SupervisorPath -DataDirectory $RestartAlarmDirectory -HealthProbe { $true } `
            -TailscaleProcessProbe { $true } -ReliabilitySignalProbe $RestartProbe `
            -AlertConfigPath $AlertConfigPath -AlertTransport $RestartTransport
    }
    $State = Get-Content (Join-Path $RestartAlarmDirectory "state.json") -Raw | ConvertFrom-Json
    if ($RestartAlertTracker.Calls -ne 1 -or
        -not $State.RestartStormActiveUnits.'dalton-goals-dashboard.service') {
        throw "Restart storm emitted $($RestartAlertTracker.Calls) transports instead of one."
    }

    $PressureAlarmDirectory = Join-Path $TestDirectory "pressure-alarm"
    $PressureAlertTracker = [pscustomobject]@{ Calls = 0 }
    $PressureTransport = { param($Uri, $Body, $TimeoutSec) $PressureAlertTracker.Calls++; [pscustomobject]@{ ok = $true } }.GetNewClosure()
    1..4 | ForEach-Object {
        & $SupervisorPath -DataDirectory $PressureAlarmDirectory -HealthProbe { $true } `
            -TailscaleProcessProbe { $true } `
            -ReliabilitySignalProbe { [pscustomobject]@{ BootCountLastHour = 1; RestartCounts = [pscustomobject]@{} } } `
            -HostPressureProbe { [pscustomobject]@{ CommitPercent = 90; ChromePrivateGB = 1; WslPrivateGB = 2 } } `
            -PressureSustainedSamples 3 -AlertConfigPath $AlertConfigPath -AlertTransport $PressureTransport
    }
    $State = Get-Content (Join-Path $PressureAlarmDirectory "state.json") -Raw | ConvertFrom-Json
    $PressureLines = @(Get-Content (Join-Path $PressureAlarmDirectory "host-pressure.jsonl"))
    if ($PressureAlertTracker.Calls -ne 1 -or -not $State.PressureAlertActive -or
        [int]$State.PressureHighConsecutive -ne 4 -or $PressureLines.Count -ne 4) {
        throw "Sustained pressure did not emit one alert and four structured samples."
    }

    $PressureRotationDirectory = Join-Path $TestDirectory "pressure-rotation"
    New-Item -ItemType Directory -Path $PressureRotationDirectory -Force | Out-Null
    Set-Content (Join-Path $PressureRotationDirectory "host-pressure.jsonl") -Value "current-old-sample" -Encoding UTF8
    Set-Content (Join-Path $PressureRotationDirectory "host-pressure.jsonl.1") -Value "older-sample" -Encoding UTF8
    & $SupervisorPath -DataDirectory $PressureRotationDirectory -HealthProbe { $true } `
        -TailscaleProcessProbe { $true } `
        -ReliabilitySignalProbe { [pscustomobject]@{ BootCountLastHour = 1; RestartCounts = [pscustomobject]@{} } } `
        -HostPressureProbe { [pscustomobject]@{ CommitPercent = 30; ChromePrivateGB = 0; WslPrivateGB = 3 } } `
        -PressureLogMaxBytes 5 -PressureLogRetention 2
    if ((Get-Content (Join-Path $PressureRotationDirectory "host-pressure.jsonl.1") -Raw) -notmatch "current-old-sample" -or
        (Get-Content (Join-Path $PressureRotationDirectory "host-pressure.jsonl.2") -Raw) -notmatch "older-sample" -or
        @(Get-Content (Join-Path $PressureRotationDirectory "host-pressure.jsonl")).Count -ne 1) {
        throw "Pressure JSONL rotation did not retain the configured generations."
    }

    $FixturePath = Join-Path $PSScriptRoot "fixtures\health-detailed.json"
    $FixtureText = Get-Content -LiteralPath $FixturePath -Raw
    $FixturePayload = $FixtureText | ConvertFrom-Json

    function Invoke-ContractCase {
        param(
            [AllowEmptyString()][string]$Content,
            [int]$StatusCode = 200
        )
        $CaseDirectory = Join-Path $TestDirectory ("contract-" + [guid]::NewGuid().ToString("N"))
        $CaseContent = $Content
        $CaseStatus = $StatusCode
        $Request = {
            param($Uri, $TimeoutSeconds)
            [pscustomobject]@{ StatusCode = $CaseStatus; Content = $CaseContent }
        }.GetNewClosure()
        & $SupervisorPath `
            -FailureThreshold 1 `
            -DataDirectory $CaseDirectory `
            -AlertConfigPath $AlertConfigPath `
            -WebRequestInvoker $Request `
            -NoRemediation `
            -AlertTransport $SupervisorTransport
        [pscustomobject]@{
            State = Get-Content (Join-Path $CaseDirectory "state.json") -Raw | ConvertFrom-Json
            Log = (Get-Content (Join-Path $CaseDirectory "supervisor.log") -Raw -ErrorAction SilentlyContinue)
        }
    }

    $Case = Invoke-ContractCase -Content $FixtureText
    if ($Case.State.LastOutcome -ne "healthy") {
        throw "Captured real health fixture did not validate as healthy."
    }

    foreach ($InvalidContent in @("{not-json", "")) {
        $Case = Invoke-ContractCase -Content $InvalidContent
        if ($Case.State.LastOutcome -ne "no-remediation") {
            throw "Malformed or empty payload escaped the unhealthy contract."
        }
    }
    $Case = Invoke-ContractCase -Content "server error" -StatusCode 500
    if ($Case.State.LastOutcome -ne "no-remediation" -or $Case.Log -notmatch "HTTP 500") {
        throw "HTTP 500 escaped the unhealthy contract."
    }

    $LivePayload = (Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:8646/health/detailed" -TimeoutSec 4).Content | ConvertFrom-Json
    foreach ($Property in $FixturePayload.PSObject.Properties.Name) {
        if (@($LivePayload.PSObject.Properties.Match($Property)).Count -ne 1) {
            throw "Live health payload drifted: missing top-level property $Property."
        }
    }
    foreach ($Platform in $FixturePayload.platforms.PSObject.Properties.Name) {
        $LivePlatform = @($LivePayload.platforms.PSObject.Properties.Match($Platform)) | Select-Object -First 1
        if ($null -eq $LivePlatform) { throw "Live health payload drifted: missing platform $Platform." }
        foreach ($Property in $FixturePayload.platforms.$Platform.PSObject.Properties.Name) {
            if (@($LivePlatform.Value.PSObject.Properties.Match($Property)).Count -ne 1) {
                throw "Live health payload drifted: $Platform missing property $Property."
            }
        }
    }

    Write-Output "Hermes host supervisor tests passed."
}
finally {
    Remove-Item -LiteralPath $TestDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
