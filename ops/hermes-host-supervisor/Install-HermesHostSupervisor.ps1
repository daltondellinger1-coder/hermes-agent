[CmdletBinding()]
param(
    [string]$TaskName = "Hermes-Host-Supervisor",
    [string]$InstallDirectory = (Join-Path $env:USERPROFILE ".hermes-supervisor"),
    [string]$HermesEnvPath = "\\wsl.localhost\Ubuntu\home\dalton\.hermes\.env",
    [string]$HermesConfigPath = "\\wsl.localhost\Ubuntu\home\dalton\.hermes\config.yaml",
    [switch]$SkipTaskRegistration
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SourceDirectory = [System.IO.Path]::GetFullPath($PSScriptRoot)
$InstallDirectory = [System.IO.Path]::GetFullPath($InstallDirectory)
if ($SourceDirectory.TrimEnd('\') -eq $InstallDirectory.TrimEnd('\')) {
    throw "Run this installer from the repository, not from the live install directory: $InstallDirectory"
}

$SourceFiles = @(
    "HermesHostSupervisor.ps1",
    "HermesHostSupervisorLoop.ps1",
    "HermesAlert.psm1",
    "HermesHostSupervisorLauncher.cs",
    "Install-HermesHostSupervisor.ps1",
    "Test-HermesHostSupervisor.ps1",
    "README.md"
)

foreach ($FileName in $SourceFiles) {
    $SourcePath = Join-Path $SourceDirectory $FileName
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Required repository source file not found: $SourcePath"
    }
}

$BackupStamp = (Get-Date).ToString("yyyyMMdd-HHmmss-fff")
New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null

foreach ($FileName in $SourceFiles) {
    $SourcePath = Join-Path $SourceDirectory $FileName
    $DestinationPath = Join-Path $InstallDirectory $FileName
    if (Test-Path -LiteralPath $DestinationPath) {
        Copy-Item -LiteralPath $DestinationPath -Destination "$DestinationPath.bak-$BackupStamp" -Force
    }
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
}

if (-not (Test-Path -LiteralPath $HermesEnvPath -PathType Leaf)) {
    throw "Hermes environment file not found: $HermesEnvPath"
}
if (-not (Test-Path -LiteralPath $HermesConfigPath -PathType Leaf)) {
    throw "Hermes config file not found: $HermesConfigPath"
}

$TokenLine = Get-Content -LiteralPath $HermesEnvPath |
    Where-Object { $_ -match '^TELEGRAM_BOT_TOKEN=' } |
    Select-Object -First 1
$BotToken = if ($null -ne $TokenLine) { [string]$TokenLine.Substring($TokenLine.IndexOf('=') + 1) } else { "" }

$InGateway = $false
$InGatewayTelegram = $false
$ChatId = ""
foreach ($Line in (Get-Content -LiteralPath $HermesConfigPath)) {
    if ($Line -match '^gateway:\s*$') {
        $InGateway = $true
        continue
    }
    if ($InGateway -and $Line -match '^\S') {
        break
    }
    if ($InGateway -and $Line -match '^  telegram:\s*$') {
        $InGatewayTelegram = $true
        continue
    }
    if ($InGatewayTelegram -and $Line -match '^  \S') {
        break
    }
    if ($InGatewayTelegram -and $Line -match '^    allowed_ids:\s*(.+?)\s*$') {
        $AllowedIdMatches = [regex]::Matches([string]$Matches[1], '-?\d+')
        if ($AllowedIdMatches.Count -eq 1) {
            $ChatId = [string]$AllowedIdMatches[0].Value
        }
        break
    }
}
if ([string]::IsNullOrWhiteSpace($BotToken) -or $ChatId -notmatch '^-?\d+$') {
    throw "Existing Telegram bot token or Dalton chat id could not be read cleanly."
}

$AlertConfigPath = Join-Path $InstallDirectory "alert.config.json"
$TemporaryAlertConfigPath = "$AlertConfigPath.tmp"
[pscustomobject]@{ bot_token = $BotToken; chat_id = $ChatId } |
    ConvertTo-Json |
    Set-Content -LiteralPath $TemporaryAlertConfigPath -Encoding UTF8
& "$env:SystemRoot\System32\icacls.exe" $TemporaryAlertConfigPath `
    /inheritance:r /grant:r "${env:USERNAME}:(R,W)" | Out-Null
if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $TemporaryAlertConfigPath -Force -ErrorAction SilentlyContinue
    throw "Could not restrict the Hermes alert config ACL."
}
Move-Item -LiteralPath $TemporaryAlertConfigPath -Destination $AlertConfigPath -Force

$LauncherPath = Join-Path $InstallDirectory "HermesHostSupervisorLauncher.exe"
if (Test-Path -LiteralPath $LauncherPath) {
    Copy-Item -LiteralPath $LauncherPath -Destination "$LauncherPath.bak-$BackupStamp" -Force
    Remove-Item -LiteralPath $LauncherPath -Force
}
Add-Type `
    -Path (Join-Path $InstallDirectory "HermesHostSupervisorLauncher.cs") `
    -OutputAssembly $LauncherPath `
    -OutputType WindowsApplication

if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
    throw "No-console launcher compilation failed: $LauncherPath"
}

if ($SkipTaskRegistration) {
    Write-Output "Deployed Hermes host supervisor without changing the Scheduled Task: $InstallDirectory"
    exit 0
}

$Action = New-ScheduledTaskAction -Execute $LauncherPath

$RepeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 2) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$LogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3) `
    -RestartCount 2 `
    -RestartInterval (New-TimeSpan -Minutes 1)

function New-SupervisorTask {
    param([ValidateSet("Highest", "Limited")][string]$RunLevel)

    $Principal = New-ScheduledTaskPrincipal `
        -UserId "$env:USERDOMAIN\$env:USERNAME" `
        -LogonType Interactive `
        -RunLevel $RunLevel

    New-ScheduledTask `
        -Action $Action `
        -Trigger @($RepeatTrigger, $LogonTrigger) `
        -Settings $Settings `
        -Principal $Principal `
        -Description "Supervises Hermes from Windows and performs graded recovery only after repeated local health failures."
}

try {
    $Task = New-SupervisorTask -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force -ErrorAction Stop | Out-Null
    Write-Output "Installed scheduled task with highest privileges: $TaskName"
}
catch {
    $ExistingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $ExistingAction = @($ExistingTask.Actions | Where-Object { $_.Execute -eq $LauncherPath })
    if ($null -ne $ExistingTask -and $ExistingAction.Count -gt 0) {
        Write-Warning "Could not replace the existing task, but it already targets the deployed launcher: $LauncherPath"
        exit 0
    }

    try {
        $Task = New-SupervisorTask -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force -ErrorAction Stop | Out-Null
        Write-Warning "Installed $TaskName at normal user privilege. WSL and gateway recovery are enabled; restarting WslService after a hung wsl --shutdown still requires a one-time elevated reinstall."
    }
    catch {
        $StartupPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\HermesHostSupervisor.cmd"
        $StartupCommand = '@echo off' + [Environment]::NewLine +
            'start "Hermes Host Supervisor" /min "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "%USERPROFILE%\.hermes-supervisor\HermesHostSupervisorLoop.ps1"' + [Environment]::NewLine
        Set-Content -LiteralPath $StartupPath -Value $StartupCommand -Encoding ASCII
        Write-Warning "Scheduled Task installation was denied. The installed per-user Startup supervisor will be used instead; WslService restart remains unavailable without elevation."
    }
}
