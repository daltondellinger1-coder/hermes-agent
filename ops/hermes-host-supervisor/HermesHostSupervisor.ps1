[CmdletBinding()]
param(
    [string]$HealthUrl = "http://127.0.0.1:8646/health/detailed",
    [string[]]$RequiredPlatforms = @("telegram", "discord", "api_server", "webhook"),
    [string]$Distro = "Ubuntu",
    [string]$LinuxUser = "dalton",
    [int]$FailureThreshold = 3,
    [int]$RecoveryCooldownMinutes = 20,
    [int]$MaxConsecutiveRecoveryFailures = 3,
    [int]$WslStartAttempts = 6,
    [int]$WslStartRetrySeconds = 5,
    [string]$DataDirectory = "",
    [string]$AlertConfigPath = "",
    [switch]$AlwaysLog,
    [switch]$NoRemediation,
    [switch]$ResetRecoverySuspension,
    [scriptblock]$HealthProbe,
    [scriptblock]$ProcessInvoker,
    [scriptblock]$RecoveryInvoker,
    [scriptblock]$ServiceRestarter,
    [scriptblock]$AlertTransport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DataDirectory)) {
    $DataDirectory = Join-Path $PSScriptRoot "data"
}

if ($FailureThreshold -lt 1) {
    throw "FailureThreshold must be at least 1."
}
if ($WslStartAttempts -lt 1) {
    throw "WslStartAttempts must be at least 1."
}
if ($MaxConsecutiveRecoveryFailures -lt 1) {
    throw "MaxConsecutiveRecoveryFailures must be at least 1."
}
if ($WslStartRetrySeconds -lt 0) {
    throw "WslStartRetrySeconds cannot be negative."
}

$StatePath = Join-Path $DataDirectory "state.json"
$LogPath = Join-Path $DataDirectory "supervisor.log"
if ([string]::IsNullOrWhiteSpace($AlertConfigPath)) {
    $AlertConfigPath = Join-Path $PSScriptRoot "alert.config.json"
}
$AlertModuleAvailable = $false
try {
    Import-Module (Join-Path $PSScriptRoot "HermesAlert.psm1") -Force -ErrorAction Stop
    $AlertModuleAvailable = $true
}
catch { }

function Initialize-DataDirectory {
    if (-not (Test-Path -LiteralPath $DataDirectory)) {
        New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    }
}

function Write-SupervisorLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")][string]$Level = "INFO"
    )

    Initialize-DataDirectory
    if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 5MB) {
        $PreviousLog = "$LogPath.1"
        if (Test-Path -LiteralPath $PreviousLog) {
            Remove-Item -LiteralPath $PreviousLog -Force
        }
        Move-Item -LiteralPath $LogPath -Destination $PreviousLog -Force
    }

    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
    Add-Content -LiteralPath $LogPath -Value "$Timestamp [$Level] $Message" -Encoding UTF8
}

function New-DefaultState {
    [pscustomobject]@{
        ConsecutiveFailures = 0
        LastCheckUtc = $null
        LastHealthyUtc = $null
        LastRecoveryUtc = $null
        RecoveryCount = 0
        ConsecutiveRecoveryFailures = 0
        RecoverySuspended = $false
        LastRecoveryFailureOutcome = $null
        LastOutcome = "new"
    }
}

function Read-SupervisorState {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return New-DefaultState
    }

    try {
        $State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        $DefaultState = New-DefaultState
        foreach ($Property in $DefaultState.PSObject.Properties.Name) {
            if ($State.PSObject.Properties.Name -notcontains $Property) {
                $State | Add-Member -NotePropertyName $Property -NotePropertyValue $DefaultState.$Property
            }
        }
        return $State
    }
    catch {
        Write-SupervisorLog -Level WARN -Message "State file was unreadable; starting with a clean state: $($_.Exception.Message)"
        return New-DefaultState
    }
}

function Save-SupervisorState {
    param([Parameter(Mandatory = $true)]$State)

    Initialize-DataDirectory
    $TemporaryPath = "$StatePath.tmp"
    $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $TemporaryPath -Encoding UTF8
    Move-Item -LiteralPath $TemporaryPath -Destination $StatePath -Force
}

function Test-HermesHealth {
    $script:LastHealthDetail = "health probe did not complete"
    if ($null -ne $HealthProbe) {
        try {
            $Result = & $HealthProbe
            $script:LastHealthDetail = if ($Result) { "stubbed healthy" } else { "stubbed unhealthy" }
            return [bool]$Result
        }
        catch {
            $script:LastHealthDetail = "stubbed health probe failed"
            return $false
        }
    }
    try {
        $Response = Invoke-WebRequest -UseBasicParsing -Uri $HealthUrl -TimeoutSec 4
        if ($Response.StatusCode -ne 200) {
            $script:LastHealthDetail = "HTTP $($Response.StatusCode)"
            return $false
        }

        try {
            $Payload = $Response.Content | ConvertFrom-Json
            if ($Payload.status -ne "ok") {
                $script:LastHealthDetail = "status=$($Payload.status)"
                return $false
            }
            if ($Payload.gateway_state -ne "running") {
                $script:LastHealthDetail = "gateway_state=$($Payload.gateway_state)"
                return $false
            }
            if ($null -eq $Payload.platforms) {
                $script:LastHealthDetail = "platform status missing"
                return $false
            }

            $Unhealthy = @()
            foreach ($Platform in $RequiredPlatforms) {
                $Entry = $Payload.platforms.PSObject.Properties[$Platform]
                if ($null -eq $Entry -or $null -eq $Entry.Value) {
                    $Unhealthy += "$Platform=missing"
                    continue
                }
                $State = [string]$Entry.Value.state
                if ($State -ne "connected") {
                    $Unhealthy += "$Platform=$State"
                }
            }
            if ($Unhealthy.Count -gt 0) {
                $script:LastHealthDetail = ($Unhealthy -join ",")
                return $false
            }

            $script:LastHealthDetail = "gateway and required platforms connected"
            return $true
        }
        catch {
            $script:LastHealthDetail = "invalid detailed health payload"
            return $false
        }
    }
    catch {
        $script:LastHealthDetail = $_.Exception.GetType().Name
        return $false
    }
}

function Get-HostPressure {
    $Result = [ordered]@{
        CommitPercent = $null
        ChromePrivateGB = 0.0
        WslPrivateGB = 0.0
    }

    try {
        $Memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
        $Result.CommitPercent = [int]$Memory.PercentCommittedBytesInUse
    }
    catch {
        Write-SupervisorLog -Level WARN -Message "Could not read Windows commit pressure: $($_.Exception.Message)"
    }

    try {
        $ChromeProcesses = @(Get-Process -Name chrome -ErrorAction SilentlyContinue)
        $ChromeBytes = [long](($ChromeProcesses | ForEach-Object { $_.PrivateMemorySize64 }) | Measure-Object -Sum).Sum
        if ($ChromeProcesses.Count -gt 0) {
            $Result.ChromePrivateGB = [math]::Round($ChromeBytes / 1GB, 2)
        }
        $WslProcesses = @(Get-Process -Name vmmemWSL -ErrorAction SilentlyContinue)
        $WslBytes = [long](($WslProcesses | ForEach-Object { $_.PrivateMemorySize64 }) | Measure-Object -Sum).Sum
        if ($WslProcesses.Count -gt 0) {
            $Result.WslPrivateGB = [math]::Round($WslBytes / 1GB, 2)
        }
    }
    catch {
        Write-SupervisorLog -Level WARN -Message "Could not read process pressure: $($_.Exception.Message)"
    }

    [pscustomobject]$Result
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [int]$TimeoutSeconds = 20
    )

    if ($null -ne $ProcessInvoker) {
        return & $ProcessInvoker $FilePath $Arguments $TimeoutSeconds
    }

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $FilePath
    $StartInfo.Arguments = $Arguments
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo
    $null = $Process.Start()
    if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $Process.Kill() } catch { }
        return [pscustomobject]@{ ExitCode = $null; TimedOut = $true; Output = ""; Error = "timeout" }
    }

    [pscustomobject]@{
        ExitCode = $Process.ExitCode
        TimedOut = $false
        Output = $Process.StandardOutput.ReadToEnd().Trim()
        Error = $Process.StandardError.ReadToEnd().Trim()
    }
}

function Wait-ForHermesHealth {
    param([int]$TimeoutSeconds)

    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-HermesHealth) {
            return $true
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $Deadline)
    return $false
}

function Start-WslDistroWithRetry {
    param([Parameter(Mandatory = $true)][string]$Arguments)

    for ($Attempt = 1; $Attempt -le $WslStartAttempts; $Attempt++) {
        $Start = Invoke-ProcessWithTimeout `
            -FilePath "$env:SystemRoot\System32\wsl.exe" `
            -Arguments "$Arguments --exec /bin/true" `
            -TimeoutSeconds 30
        if (-not $Start.TimedOut -and $Start.ExitCode -eq 0) {
            return $true
        }

        $Failure = if ($Start.TimedOut) {
            "timed out"
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$Start.Error)) {
            "exit=$($Start.ExitCode), error=$($Start.Error)"
        }
        else {
            "exit=$($Start.ExitCode), no stderr"
        }
        Write-SupervisorLog -Level WARN -Message "Ubuntu start attempt $Attempt/$WslStartAttempts failed ($Failure)."

        if ($Attempt -lt $WslStartAttempts -and $WslStartRetrySeconds -gt 0) {
            Start-Sleep -Seconds $WslStartRetrySeconds
        }
    }

    return $false
}

function Send-RecoveryNotice {
    param([Parameter(Mandatory = $true)][string]$Message)

    try {
        & "$env:SystemRoot\System32\msg.exe" $env:USERNAME $Message 2>$null | Out-Null
    }
    catch {
        Write-SupervisorLog -Level WARN -Message "Could not display recovery notice: $($_.Exception.Message)"
    }
}

function Send-SupervisorAlert {
    param(
        [Parameter(Mandatory = $true)][string]$Condition,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)]$State
    )

    if (-not $AlertModuleAvailable) {
        Write-SupervisorLog -Level WARN -Message "Hermes alert module is unavailable for condition '$Condition'."
        return
    }

    try {
        $Text = @(
            "Hermes host supervisor: $Condition",
            "Health: $script:LastHealthDetail",
            "Consecutive failures: $($State.ConsecutiveFailures)",
            "Action: $Action"
        ) -join [Environment]::NewLine
        $Result = Send-HermesAlert `
            -Condition $Condition `
            -Message $Text `
            -State $State `
            -ConfigPath $AlertConfigPath `
            -WarningSink { param($Text) Write-SupervisorLog -Level WARN -Message $Text } `
            -Transport $AlertTransport
        if ($Result.Sent) {
            Save-SupervisorState -State $State
            Write-SupervisorLog -Message "Hermes alert sent for condition '$Condition' (Telegram API acknowledged)."
        }
    }
    catch {
        Write-SupervisorLog -Level WARN -Message "Hermes alert handling failed for condition '$Condition'."
    }
}

function Get-HermesRecoveryEvidence {
    param([Parameter(Mandatory = $true)][string]$WslArguments)

    $Vm = Invoke-ProcessWithTimeout `
        -FilePath "$env:SystemRoot\System32\wsl.exe" `
        -Arguments "$WslArguments --exec /bin/true" `
        -TimeoutSeconds 12
    if ($Vm.TimedOut -or $null -eq $Vm.ExitCode) {
        return [pscustomobject]@{ Classification = "ambiguous"; Vm = "unknown"; Gateway = "unknown"; Port = "unknown" }
    }
    if ($Vm.ExitCode -ne 0) {
        return [pscustomobject]@{ Classification = "vm-fault"; Vm = "unreachable"; Gateway = "unknown"; Port = "unknown" }
    }

    $Gateway = Invoke-ProcessWithTimeout `
        -FilePath "$env:SystemRoot\System32\wsl.exe" `
        -Arguments "$WslArguments --exec /usr/bin/systemctl --user is-active hermes-gateway.service" `
        -TimeoutSeconds 12
    $Port = Invoke-ProcessWithTimeout `
        -FilePath "$env:SystemRoot\System32\wsl.exe" `
        -Arguments "$WslArguments --exec /usr/bin/ss -ltn sport = :8646" `
        -TimeoutSeconds 12

    $GatewayState = if ($Gateway.TimedOut -or $null -eq $Gateway.ExitCode) {
        "unknown"
    }
    elseif ($Gateway.ExitCode -eq 0 -and $Gateway.Output -eq "active") {
        "active"
    }
    elseif ($Gateway.Output -match '^(inactive|failed|deactivating)$') {
        "inactive"
    }
    else {
        "unknown"
    }
    $PortState = if ($Port.TimedOut -or $null -eq $Port.ExitCode -or $Port.ExitCode -ne 0) {
        "unknown"
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$Port.Output)) {
        "listening"
    }
    else {
        "not-listening"
    }

    $Classification = if ($GatewayState -eq "active" -and $PortState -eq "listening") {
        "probe-side-fault"
    }
    elseif ($GatewayState -eq "inactive") {
        "gateway-fault"
    }
    else {
        "ambiguous"
    }
    [pscustomobject]@{ Classification = $Classification; Vm = "reachable"; Gateway = $GatewayState; Port = $PortState }
}

function Invoke-HermesRecovery {
    $WslArguments = "--distribution `"$Distro`" --user `"$LinuxUser`""
    $Evidence = Get-HermesRecoveryEvidence -WslArguments $WslArguments
    Write-SupervisorLog -Level WARN -Message "Recovery evidence: classification=$($Evidence.Classification) vm=$($Evidence.Vm) gateway=$($Evidence.Gateway) port=$($Evidence.Port)."

    if ($Evidence.Classification -eq "probe-side-fault" -or $Evidence.Classification -eq "ambiguous") {
        return $Evidence.Classification
    }

    if ($Evidence.Classification -eq "gateway-fault") {
        Write-SupervisorLog -Level WARN -Message "Gateway fault classified; restarting only hermes-gateway.service."
        $Restart = Invoke-ProcessWithTimeout -FilePath "$env:SystemRoot\System32\wsl.exe" -Arguments "$WslArguments --exec /usr/bin/systemctl --user restart hermes-gateway.service" -TimeoutSeconds 30
        if (-not $Restart.TimedOut -and $Restart.ExitCode -eq 0 -and (Wait-ForHermesHealth -TimeoutSeconds 60)) {
            return "gateway-restarted"
        }
        Write-SupervisorLog -Level ERROR -Message "Gateway-only recovery did not restore health; refusing to escalate past the classified gateway fault."
        return "recovery-failed"
    }

    Write-SupervisorLog -Level WARN -Message "VM fault classified; escalating to a WSL restart."
    $Shutdown = Invoke-ProcessWithTimeout -FilePath "$env:SystemRoot\System32\wsl.exe" -Arguments "--shutdown" -TimeoutSeconds 30
    if ($Shutdown.TimedOut) {
        Write-SupervisorLog -Level WARN -Message "wsl --shutdown timed out; restarting the Windows WslService as the final recovery step."
        try {
            if ($null -ne $ServiceRestarter) {
                & $ServiceRestarter
            }
            else {
                Restart-Service -Name WslService -Force -ErrorAction Stop
            }
            Start-Sleep -Seconds 5
        }
        catch {
            $PrivilegeBlocked = $_.Exception -is [System.UnauthorizedAccessException] -or
                $_.Exception.Message -match 'access.*denied|privilege|elevation'
            if ($PrivilegeBlocked) {
                Write-SupervisorLog -Level ERROR -Message "WslService restart was blocked by the Scheduled Task privilege level."
                return "recovery-blocked-privilege"
            }
            Write-SupervisorLog -Level ERROR -Message "WslService restart failed."
            return "recovery-failed"
        }
    }
    elseif ($Shutdown.ExitCode -ne 0) {
        Write-SupervisorLog -Level ERROR -Message "wsl --shutdown failed: $($Shutdown.Error)"
        return "recovery-failed"
    }

    if (-not (Start-WslDistroWithRetry -Arguments $WslArguments)) {
        Write-SupervisorLog -Level ERROR -Message "Ubuntu restart did not succeed after $WslStartAttempts attempts."
        # A failed wsl.exe caller can still have triggered an asynchronous VM
        # start. Give Hermes one final bounded health window before declaring
        # recovery failed and entering the normal cooldown.
        if (Wait-ForHermesHealth -TimeoutSeconds 60) {
            return "wsl-restarted"
        }
        return "recovery-failed"
    }

    if (Wait-ForHermesHealth -TimeoutSeconds 120) {
        return "wsl-restarted"
    }
    return "recovery-failed"
}

Initialize-DataDirectory
$State = Read-SupervisorState
$State.RecoverySuspended = [bool]$State.RecoverySuspended
if ($ResetRecoverySuspension) {
    $State.ConsecutiveRecoveryFailures = 0
    $State.RecoverySuspended = $false
    $State.LastRecoveryFailureOutcome = $null
    $State.LastOutcome = "suspension-reset"
    Save-SupervisorState -State $State
    Write-SupervisorLog -Message "Recovery suspension was explicitly cleared by an operator."
    exit 0
}
$Now = (Get-Date).ToUniversalTime()
$State.LastCheckUtc = $Now.ToString("o")
$Pressure = Get-HostPressure

if (($null -ne $Pressure.CommitPercent -and $Pressure.CommitPercent -ge 85) -or
    $Pressure.ChromePrivateGB -ge 12 -or $Pressure.WslPrivateGB -ge 9) {
    Write-SupervisorLog -Level WARN -Message "Host pressure high: commit=$($Pressure.CommitPercent)% chrome=$($Pressure.ChromePrivateGB)GB wsl=$($Pressure.WslPrivateGB)GB. Healthy processes will not be terminated."
}

if (Test-HermesHealth) {
    $WasFailing = [int]$State.ConsecutiveFailures -gt 0
    $State.ConsecutiveFailures = 0
    $State.LastHealthyUtc = $Now.ToString("o")
    $State.LastOutcome = if ($State.RecoverySuspended) { "suspended" } else { "healthy" }
    Save-SupervisorState -State $State
    if ($WasFailing) {
        Write-SupervisorLog -Message "Hermes recovered before remediation was required."
    }
    elseif ($AlwaysLog) {
        Write-SupervisorLog -Message "Hermes healthy: commit=$($Pressure.CommitPercent)% chrome=$($Pressure.ChromePrivateGB)GB wsl=$($Pressure.WslPrivateGB)GB."
    }
    exit 0
}

$State.ConsecutiveFailures = [int]$State.ConsecutiveFailures + 1
$State.LastOutcome = "health-failed"
Save-SupervisorState -State $State
Write-SupervisorLog -Level WARN -Message "Hermes health check failed ($($State.ConsecutiveFailures)/$FailureThreshold): $script:LastHealthDetail."

if ([int]$State.ConsecutiveFailures -lt $FailureThreshold) {
    exit 0
}

if ($State.RecoverySuspended) {
    $State.LastOutcome = "suspended"
    Save-SupervisorState -State $State
    Write-SupervisorLog -Level ERROR -Message "Recovery remains suspended after $($State.ConsecutiveRecoveryFailures) consecutive recovery failures."
    Send-SupervisorAlert `
        -Condition "remediation-cap-reached" `
        -Action "Remediation is latched off; clear it explicitly after inspection." `
        -State $State
    exit 0
}

if ($NoRemediation) {
    $State.LastOutcome = "no-remediation"
    Save-SupervisorState -State $State
    Write-SupervisorLog -Level WARN -Message "Failure threshold reached, but remediation is disabled for this run."
    Send-SupervisorAlert `
        -Condition "health-failure-no-remediation" `
        -Action "Remediation is disabled; inspect Hermes manually." `
        -State $State
    exit 0
}

if ($null -ne $State.LastRecoveryUtc -and -not [string]::IsNullOrWhiteSpace([string]$State.LastRecoveryUtc)) {
    try {
        $LastRecovery = [datetime]::Parse([string]$State.LastRecoveryUtc).ToUniversalTime()
        if ($Now -lt $LastRecovery.AddMinutes($RecoveryCooldownMinutes)) {
            Write-SupervisorLog -Level WARN -Message "Recovery is in its $RecoveryCooldownMinutes-minute cooldown; not creating a restart loop."
            exit 0
        }
    }
    catch {
        Write-SupervisorLog -Level WARN -Message "Ignoring malformed recovery timestamp in state."
    }
}

$State.LastRecoveryUtc = $Now.ToString("o")
$State.RecoveryCount = [int]$State.RecoveryCount + 1
$State.LastOutcome = "recovering"
Save-SupervisorState -State $State
Write-SupervisorLog -Level WARN -Message "Failure threshold reached; beginning graded Hermes recovery."
Send-SupervisorAlert `
    -Condition "recovery-started" `
    -Action "Beginning graded recovery." `
    -State $State

$Outcome = if ($null -ne $RecoveryInvoker) { & $RecoveryInvoker } else { Invoke-HermesRecovery }
$State.LastOutcome = $Outcome
if ($Outcome -eq "gateway-restarted" -or $Outcome -eq "wsl-restarted") {
    $State.ConsecutiveFailures = 0
    $State.ConsecutiveRecoveryFailures = 0
    $State.LastRecoveryFailureOutcome = $null
    $State.LastHealthyUtc = (Get-Date).ToUniversalTime().ToString("o")
    Write-SupervisorLog -Message "Hermes recovery succeeded: $Outcome."
    Send-RecoveryNotice -Message "Hermes recovered automatically ($Outcome)."
    Send-SupervisorAlert `
        -Condition "recovery-succeeded" `
        -Action "Recovery completed: $Outcome." `
        -State $State
}
elseif ($Outcome -eq "probe-side-fault" -or $Outcome -eq "ambiguous") {
    Write-SupervisorLog -Level ERROR -Message "Recovery declined: $Outcome. Independent evidence does not justify destructive remediation."
    Send-SupervisorAlert `
        -Condition $Outcome `
        -Action "Independent evidence is $Outcome; no remediation was performed." `
        -State $State
}
else {
    $State.ConsecutiveRecoveryFailures = [int]$State.ConsecutiveRecoveryFailures + 1
    $State.LastRecoveryFailureOutcome = $Outcome
    $FailureAction = if ($Outcome -eq "recovery-blocked-privilege") {
        "Recovery was blocked by task privileges; re-register elevated only after operator approval."
    }
    else {
        "Automatic recovery failed; manual inspection is required."
    }
    Write-SupervisorLog -Level ERROR -Message "$FailureAction Failure count: $($State.ConsecutiveRecoveryFailures)/$MaxConsecutiveRecoveryFailures."
    Send-RecoveryNotice -Message $FailureAction
    Send-SupervisorAlert `
        -Condition $Outcome `
        -Action $FailureAction `
        -State $State
    if ([int]$State.ConsecutiveRecoveryFailures -ge $MaxConsecutiveRecoveryFailures) {
        $State.RecoverySuspended = $true
        $State.LastOutcome = "suspended"
        Save-SupervisorState -State $State
        Write-SupervisorLog -Level ERROR -Message "Remediation cap reached; destructive recovery is now latched off."
        Send-SupervisorAlert `
            -Condition "remediation-cap-reached" `
            -Action "Remediation is latched off after $($State.ConsecutiveRecoveryFailures) failures; inspect and reset explicitly." `
            -State $State
    }
}
Save-SupervisorState -State $State
