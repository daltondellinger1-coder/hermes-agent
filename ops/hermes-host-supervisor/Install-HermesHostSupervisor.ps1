[CmdletBinding()]
param(
    [string]$TaskName = "Hermes-Host-Supervisor"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$SupervisorPath = Join-Path $PSScriptRoot "HermesHostSupervisor.ps1"
if (-not (Test-Path -LiteralPath $SupervisorPath)) {
    throw "Supervisor script not found: $SupervisorPath"
}

$LauncherPath = Join-Path $PSScriptRoot "HermesHostSupervisorLauncher.exe"
if (-not (Test-Path -LiteralPath $LauncherPath)) {
    throw "No-console launcher not found: $LauncherPath"
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
    Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force | Out-Null
    Write-Output "Installed scheduled task with highest privileges: $TaskName"
}
catch {
    try {
        $Task = New-SupervisorTask -RunLevel Limited
        Register-ScheduledTask -TaskName $TaskName -InputObject $Task -Force | Out-Null
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
