[CmdletBinding()]
param(
    [int]$IntervalSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($IntervalSeconds -lt 30) {
    throw "IntervalSeconds must be at least 30."
}

$SupervisorPath = Join-Path $PSScriptRoot "HermesHostSupervisor.ps1"
$DataDirectory = Join-Path $PSScriptRoot "data"
$LoopLog = Join-Path $DataDirectory "loop.log"
$PidPath = Join-Path $DataDirectory "loop.pid"
$Mutex = New-Object System.Threading.Mutex($false, "Local\HermesHostSupervisorLoop-$env:USERNAME")
$OwnsMutex = $false

try {
    $OwnsMutex = $Mutex.WaitOne(0)
    if (-not $OwnsMutex) {
        exit 0
    }

    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    Set-Content -LiteralPath $PidPath -Value $PID -Encoding ASCII

    while ($true) {
        try {
            & $SupervisorPath
        }
        catch {
            $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
            Add-Content -LiteralPath $LoopLog -Value "$Timestamp [ERROR] Supervisor iteration failed: $($_.Exception.Message)" -Encoding UTF8
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    if ($OwnsMutex) {
        $Mutex.ReleaseMutex()
    }
    $Mutex.Dispose()
}
