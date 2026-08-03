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
        $content = (Invoke-WebRequest -Method Get -Uri $Uri -UseBasicParsing -TimeoutSec 10).Content
    } catch {
        throw "GET $Uri failed. $($_.Exception.Message)"
    }

    # Invoke-WebRequest decides between a string and a byte array by sniffing
    # the Content-Type, and it only treats a known text type as text. Spring
    # Boot Actuator answers /readyz with
    # `application/vnd.spring-boot.actuator.v3+json`, which is not on that list,
    # so .Content arrives as bytes: returning it unchanged would enumerate 15
    # integers into the caller's pipeline instead of `{"status":"UP"}`, and a
    # `-match` against that yields an array rather than a Boolean.
    if ($content -is [byte[]]) {
        return [System.Text.Encoding]::UTF8.GetString($content)
    }

    return $content
}

# Returns the HTTP status code of a request, including the codes that
# Invoke-WebRequest reports as errors instead of returning.
#
# A non-2xx response is a terminating error for Invoke-WebRequest, and the
# exception type depends on the edition: Windows PowerShell 5.1 throws
# System.Net.WebException, PowerShell 7 throws
# Microsoft.PowerShell.Commands.HttpResponseException, which is not a
# WebException and does not exist as a type in 5.1. Catching either concrete
# type therefore aborts the script on the other edition, and PowerShell 7's
# -SkipHttpErrorCheck cannot be used because 5.1 has no such parameter.
#
# So the catch is untyped and the response is read off the exception instead:
# both editions expose it as $_.Exception.Response, and its presence is what
# distinguishes "the server answered with a status worth asserting on" from
# "the request never got a response".
function Invoke-HttpStatus {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [string] $Method = "Get",
        [string] $Body,
        [string] $ContentType = "application/json",
        [int] $TimeoutSec = 10
    )

    $arguments = @{
        Uri             = $Uri
        Method          = $Method
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
        ErrorAction     = "Stop"
    }

    if ($PSBoundParameters.ContainsKey("Body")) {
        $arguments.Body = $Body
        $arguments.ContentType = $ContentType
    }

    try {
        return [int] (Invoke-WebRequest @arguments).StatusCode
    } catch {
        $response = $_.Exception.Response

        # Null only when no response was received at all - connection refused,
        # DNS failure, timeout. That is a failed request rather than a status
        # code, so it is surfaced instead of being reported as a status.
        if ($null -eq $response) {
            throw "$Method $Uri failed before a response was received. $($_.Exception.Message)"
        }

        # HttpWebResponse.StatusCode (5.1) and HttpResponseMessage.StatusCode
        # (7) are both System.Net.HttpStatusCode, so one cast covers each.
        return [int] $response.StatusCode
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

Export-ModuleMember -Function Invoke-JsonGet, Invoke-TextGet, Invoke-HttpStatus, Confirm-Condition, Invoke-WithRetry
