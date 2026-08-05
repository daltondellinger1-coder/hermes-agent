Set-StrictMode -Version Latest

function Test-HermesHealthPayload {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Content,
        [string[]]$RequiredPlatforms = @("telegram", "discord", "api_server", "webhook")
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return [pscustomobject]@{ Healthy = $false; Detail = "empty detailed health payload" }
    }
    try {
        $Payload = $Content | ConvertFrom-Json
        if ($Payload.status -ne "ok") {
            return [pscustomobject]@{ Healthy = $false; Detail = "status=$($Payload.status)" }
        }
        if ($Payload.gateway_state -ne "running") {
            return [pscustomobject]@{ Healthy = $false; Detail = "gateway_state=$($Payload.gateway_state)" }
        }
        if ($null -eq $Payload.platforms) {
            return [pscustomobject]@{ Healthy = $false; Detail = "platform status missing" }
        }

        $Unhealthy = @()
        foreach ($Platform in $RequiredPlatforms) {
            $Entry = @($Payload.platforms.PSObject.Properties.Match($Platform)) | Select-Object -First 1
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
            return [pscustomobject]@{ Healthy = $false; Detail = ($Unhealthy -join ",") }
        }
        return [pscustomobject]@{ Healthy = $true; Detail = "gateway and required platforms connected" }
    }
    catch {
        return [pscustomobject]@{ Healthy = $false; Detail = "invalid detailed health payload" }
    }
}

Export-ModuleMember -Function Test-HermesHealthPayload
