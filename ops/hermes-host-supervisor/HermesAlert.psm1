Set-StrictMode -Version Latest

function Send-HermesAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Condition,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)]$State,
        [string]$ConfigPath = (Join-Path $PSScriptRoot "alert.config.json"),
        [int]$RateLimitMinutes = 30,
        [datetime]$NowUtc = ([datetime]::UtcNow),
        [scriptblock]$WarningSink = { param($Text) },
        [scriptblock]$Transport
    )

    try {
        $AlertStateProperty = @($State.PSObject.Properties.Match("AlertLastSentUtc")) |
            Select-Object -First 1
        if ($null -eq $AlertStateProperty -or $null -eq $AlertStateProperty.Value) {
            $State | Add-Member -NotePropertyName AlertLastSentUtc -NotePropertyValue ([pscustomobject]@{}) -Force
        }

        $PreviousProperty = @($State.AlertLastSentUtc.PSObject.Properties.Match($Condition)) |
            Select-Object -First 1
        if ($null -ne $PreviousProperty -and
            -not [string]::IsNullOrWhiteSpace([string]$PreviousProperty.Value)) {
            $PreviousUtc = [datetime]::Parse([string]$PreviousProperty.Value).ToUniversalTime()
            if ($NowUtc.ToUniversalTime() -lt $PreviousUtc.AddMinutes($RateLimitMinutes)) {
                return [pscustomobject]@{ Sent = $false; RateLimited = $true }
            }
        }

        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            & $WarningSink "Hermes alert config is missing for condition '$Condition'." | Out-Null
            return [pscustomobject]@{ Sent = $false; RateLimited = $false }
        }

        $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        $Token = [string]$Config.bot_token
        $ChatId = [string]$Config.chat_id
        if ([string]::IsNullOrWhiteSpace($Token) -or [string]::IsNullOrWhiteSpace($ChatId)) {
            & $WarningSink "Hermes alert config is incomplete for condition '$Condition'." | Out-Null
            return [pscustomobject]@{ Sent = $false; RateLimited = $false }
        }

        $Uri = "https://api.telegram.org/bot$Token/sendMessage"
        $Body = @{ chat_id = $ChatId; text = $Message }
        if ($null -ne $Transport) {
            $Response = & $Transport $Uri $Body 10
        }
        else {
            $Response = Invoke-RestMethod -Uri $Uri -Method Post -Body $Body -TimeoutSec 10 -ErrorAction Stop
        }
        if ($null -eq $Response -or $Response.ok -ne $true) {
            throw "Telegram API did not acknowledge the alert."
        }

        $State.AlertLastSentUtc | Add-Member `
            -NotePropertyName $Condition `
            -NotePropertyValue $NowUtc.ToUniversalTime().ToString("o") `
            -Force
        return [pscustomobject]@{ Sent = $true; RateLimited = $false }
    }
    catch {
        # Do not log the exception: Invoke-RestMethod errors can include the URI,
        # and the Telegram token is embedded in that URI.
        try {
            $FailureType = $_.Exception.GetType().Name
            & $WarningSink "Hermes alert transport failed for condition '$Condition' ($FailureType)." | Out-Null
        }
        catch { }
        return [pscustomobject]@{ Sent = $false; RateLimited = $false }
    }
}

Export-ModuleMember -Function Send-HermesAlert
