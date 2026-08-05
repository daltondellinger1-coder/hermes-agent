# Hermes Host Supervisor

This Windows-side supervisor protects Hermes when the Ubuntu WSL VM or the
Hermes gateway becomes unhealthy. It runs outside WSL so it can still act when
Hermes's internal watchdog cannot.

## Installed behavior

- Scheduled Task: `Hermes-Host-Supervisor`
- Frequency: every two minutes and at Windows logon
- Health endpoint: `http://127.0.0.1:8646/health/detailed`
- Launcher: `HermesHostSupervisorLauncher.exe` (Windows subsystem; no console)
- Recovery threshold: three consecutive failed checks
- Recovery cooldown: twenty minutes
- State and logs: `C:\Users\Dalton\.hermes-supervisor\data`

Recovery is graded:

1. If WSL responds, restart only `hermes-gateway.service`.
2. If that fails, run `wsl --shutdown`, retry starting Ubuntu across the WSL
   shutdown/start race, and wait for Hermes.
3. If `wsl --shutdown` hangs, restart `WslService` only when the Scheduled Task
   was installed from an elevated PowerShell session.

High Windows commit, Chrome memory, and WSL memory are logged, but healthy
Chrome processes are never terminated automatically.

The Scheduled Task launches the supervisor through the bundled no-console
launcher. This avoids creating a Windows Terminal/OpenConsole host for every
two-minute health check.

## WSL containment

`C:\Users\Dalton\.wslconfig` now sets:

- WSL memory ceiling: 8 GB
- WSL swap: 3 GB
- Gradual automatic memory reclamation

These settings take effect after the next intentional `wsl --shutdown`. Do not
run that command while WSL work is active.

## Validation

Run the non-destructive test suite:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.hermes-supervisor\Test-HermesHostSupervisor.ps1"
```

Run a live health-only pass without remediation:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  "$env:USERPROFILE\.hermes-supervisor\HermesHostSupervisor.ps1" `
  -NoRemediation -AlwaysLog
```

## Optional elevated reinstall

The current normal-user task can restart Hermes and issue `wsl --shutdown`.
For the final `WslService` fallback, open PowerShell as Administrator once and
run:

```powershell
& "$env:USERPROFILE\.hermes-supervisor\Install-HermesHostSupervisor.ps1"
```
