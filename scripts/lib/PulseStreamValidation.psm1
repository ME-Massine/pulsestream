# Shared helpers for the PulseStream validation scripts.
# Imported by validate-prometheus-metrics.ps1 and validate-grafana-datasource.ps1
# so the common HTTP/assertion/retry logic lives in one place and cannot drift.

# Thrown for conditions that will not self-heal (e.g. a misconfigured
# datasource type). Invoke-WithRetry re-throws these immediately instead of
# retrying for the full timeout.
class PermanentValidationError : System.Exception {
    PermanentValidationError([string] $message) : base($message) {}
}

function Invoke-JsonGet {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [hashtable] $Headers = @{}
    )

    try {
        Invoke-RestMethod -Method Get -Uri $Uri -Headers $Headers -TimeoutSec 10
    } catch {
        throw "GET $Uri failed. $($_.Exception.Message)"
    }
}

function Invoke-TextGet {
    param([Parameter(Mandatory)] [string] $Uri)

    try {
        (Invoke-WebRequest -Method Get -Uri $Uri -UseBasicParsing -TimeoutSec 10).Content
    } catch {
        throw "GET $Uri failed. $($_.Exception.Message)"
    }
}

function Confirm-Condition {
    param(
        [bool] $Condition,
        [string] $SuccessMessage,
        [string] $FailureMessage,
        # Raise a PermanentValidationError so Invoke-WithRetry stops immediately
        # for checks that cannot recover on their own.
        [switch] $Permanent
    )

    if (-not $Condition) {
        if ($Permanent) {
            throw [PermanentValidationError]::new($FailureMessage)
        }
        throw $FailureMessage
    }

    Write-Host "[ok] $SuccessMessage"
}

function Invoke-WithRetry {
    param(
        [scriptblock] $Operation,
        [string] $FailureMessage,
        [int] $TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = $null

    do {
        try {
            return & $Operation
        } catch [PermanentValidationError] {
            # Won't self-heal - surface the specific error now.
            throw $_.Exception.Message
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    } while ((Get-Date) -lt $deadline)

    throw "$FailureMessage Last error: $lastError"
}

Export-ModuleMember -Function Invoke-JsonGet, Invoke-TextGet, Confirm-Condition, Invoke-WithRetry
